/**
 * Reading and writing the signed-in person's profile, and their standing request to be
 * erased.
 *
 * Page components never call Supabase directly — every query in the project goes through a
 * function in src/lib/ so that the static export step can later swap the source behind
 * these signatures without a refactor. Writes will always come from here; reads of *other*
 * people's profiles will eventually come from the nightly JSON instead.
 *
 * The column list in `SELECT` is written out rather than `*`, and that is a security
 * decision as much as a bandwidth one. `institution_source` records which of the three
 * domain layers issued a badge; CLAUDE.md says it is never displayed, and the surest way
 * to keep that true is for it never to arrive in the browser. `*` would ship it, and would
 * ship every column added later without anyone deciding to.
 */
import { getSupabase } from './supabase';

export interface Institution {
  readonly rorId: string;
  readonly name: string;
  readonly country: string;
  /** ISO timestamp. Always rendered as a month; see format.ts. */
  readonly verifiedAt: string;
}

export interface Profile {
  readonly id: string;
  readonly displayName: string;
  readonly isPseudonym: boolean;
  readonly bio: string;
  /** Null when the confirmed address did not match a registry record. */
  readonly institution: Institution | null;
  /**
   * Whether this account has confirmed its email address, and whether it is banned. Both
   * are system-owned and read-only here; they exist on this table so that row level
   * security can require a confirmed, unbanned account without any policy needing to read
   * auth.users. The interface reads them for the same reason the policies do — so it can
   * explain the refusal before somebody spends ten minutes on a form that will be
   * rejected.
   *
   * `confirmedAt` is a timestamp about the account, not about the address. There is no
   * email address anywhere in this type and there never will be.
   */
  readonly confirmedAt: string | null;
  readonly isBanned: boolean;
}

/** Whether this account may post. The same three conditions as the insert policy on
 *  public.reports, in the same order, so the interface and the database agree about who
 *  is turned away and why. */
export function mayPost(profile: Profile): boolean {
  return profile.confirmedAt !== null && !profile.isBanned;
}

export interface DeletionRequest {
  readonly id: string;
  readonly requestedAt: string;
  readonly note: string;
}

export type Loaded<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly message: string };

export type Saved = { readonly ok: true } | { readonly ok: false; readonly message: string };

const UNAVAILABLE =
  'Accounts are unavailable right now. Reading the site is unaffected. Try again in a few minutes.';

/**
 * The two verification signals, in the order they stack. Registered is every confirmed
 * account; Institutional sits on top of it and never replaces it.
 */
export type Tier = 'registered' | 'institutional';

export function tiersFor(profile: Pick<Profile, 'institution'>): Tier[] {
  return profile.institution ? ['registered', 'institutional'] : ['registered'];
}

// ── Profile ───────────────────────────────────────────────────────────────────────────

interface ProfileRow {
  id: string;
  display_name: string;
  is_pseudonym: boolean;
  bio: string | null;
  institution_ror_id: string | null;
  institution_name: string | null;
  institution_country: string | null;
  institution_verified_at: string | null;
  confirmed_at: string | null;
  is_banned: boolean;
}

const PROFILE_COLUMNS =
  'id, display_name, is_pseudonym, bio, institution_ror_id, institution_name, ' +
  'institution_country, institution_verified_at, confirmed_at, is_banned';

function toProfile(row: ProfileRow): Profile {
  // The institution columns are all-or-nothing in the database, enforced by a CHECK. This
  // reads all four anyway rather than trusting one of them, so a half-written badge would
  // render as no badge instead of as an institution with no verification date — which is
  // the one claim this project must never make.
  const complete =
    row.institution_ror_id !== null &&
    row.institution_name !== null &&
    row.institution_country !== null &&
    row.institution_verified_at !== null;

  return {
    id: row.id,
    displayName: row.display_name,
    isPseudonym: row.is_pseudonym,
    bio: row.bio ?? '',
    institution: complete
      ? {
          rorId: row.institution_ror_id as string,
          name: row.institution_name as string,
          country: row.institution_country as string,
          verifiedAt: row.institution_verified_at as string,
        }
      : null,
    confirmedAt: row.confirmed_at,
    isBanned: row.is_banned,
  };
}

export async function loadProfile(userId: string): Promise<Loaded<Profile>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('profiles')
      .select(PROFILE_COLUMNS)
      .eq('id', userId)
      .maybeSingle<ProfileRow>();

    if (error) return { ok: false, message: describe(error) };

    if (!data) {
      // The profile row is created by a trigger on auth.users, so this is the narrow
      // window right after signup, or a genuinely broken account. Say what to do, not
      // what went wrong internally.
      return {
        ok: false,
        message: 'This account has no profile yet. Reload in a moment, and get in touch if it persists.',
      };
    }

    return { ok: true, value: toProfile(data) };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

export interface ProfileEdits {
  displayName: string;
  isPseudonym: boolean;
  bio: string;
}

export async function saveProfile(userId: string, edits: ProfileEdits): Promise<Saved> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    // Exactly the three columns the `authenticated` role holds an UPDATE grant on. Sending
    // anything else fails with a permission error rather than being silently dropped, and
    // that is the intended behaviour — the guard trigger would revert it in any case.
    const { error } = await supabase
      .from('profiles')
      .update({
        display_name: edits.displayName.trim(),
        is_pseudonym: edits.isPseudonym,
        bio: edits.bio.trim() || null,
      })
      .eq('id', userId);

    return error ? { ok: false, message: describe(error) } : { ok: true };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Erasure ───────────────────────────────────────────────────────────────────────────

interface DeletionRow {
  id: string;
  requested_at: string;
  note: string | null;
}

export async function loadDeletionRequest(
  userId: string,
): Promise<Loaded<DeletionRequest | null>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('deletion_requests')
      .select('id, requested_at, note')
      .eq('user_id', userId)
      .eq('status', 'pending')
      .maybeSingle<DeletionRow>();

    if (error) return { ok: false, message: describe(error) };

    return {
      ok: true,
      value: data
        ? { id: data.id, requestedAt: data.requested_at, note: data.note ?? '' }
        : null,
    };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

export async function requestDeletion(userId: string, note: string): Promise<Saved> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    // `status` is not sent and cannot be: the `authenticated` role has no INSERT grant on
    // that column. It takes its default of 'pending'.
    const { error } = await supabase
      .from('deletion_requests')
      .insert({ user_id: userId, note: note.trim() || null });

    return error ? { ok: false, message: describe(error) } : { ok: true };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

export async function withdrawDeletion(userId: string): Promise<Saved> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    // A withdrawal deletes the row outright rather than marking it cancelled, so changing
    // your mind leaves nothing behind. The status filter is redundant with the policy and
    // is written anyway, because a filter that agrees with the policy documents it.
    const { error } = await supabase
      .from('deletion_requests')
      .delete()
      .eq('user_id', userId)
      .eq('status', 'pending');

    return error ? { ok: false, message: describe(error) } : { ok: true };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Turning a failure into a sentence ─────────────────────────────────────────────────

/**
 * PostgREST reports the SQLSTATE, which is the useful part: these are the constraints and
 * grants in supabase/migrations/ speaking. Each is mapped to what the person should do
 * about it, because "new row violates row-level security policy for table" is a true
 * sentence that helps nobody.
 */
function describe(error: unknown): string {
  const code = typeof error === 'object' && error !== null && 'code' in error
    ? String((error as { code?: unknown }).code ?? '')
    : '';

  switch (code) {
    case '23505':
      return 'A request is already on file for this account. There is nothing more to do.';

    case '23514':
      return 'One of the fields is longer than the limit. Shorten it and try again.';

    case '42501':
      return 'That change is not one this account may make.';

    case 'PGRST301':
      return 'This session has ended. Sign in again to continue.';
  }

  const message = error instanceof Error ? error.message : String(error ?? '');
  const lower = message.toLowerCase();

  if (
    lower.includes('failed to fetch') ||
    lower.includes('fetch failed') ||
    lower.includes('networkerror') ||
    lower.includes('load failed')
  ) {
    return 'Could not reach the server. Check your connection and try again — nothing was changed.';
  }

  return 'That did not work. Try again, and if it keeps failing the details are worth reporting.';
}
