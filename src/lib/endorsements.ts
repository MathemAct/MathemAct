/**
 * Endorsing a contribution, which is not voting for it.
 *
 * Two actions, mutually exclusive, both reversible: "this also captures my view", and "I agree
 * with the position, but not this reason". The second exists because without it the first has to
 * carry both meanings and a reader cannot tell a widely-held reason from a widely-shared
 * conclusion.
 *
 * **This module can read your own endorsements and nobody else's, and that is a property of the
 * database rather than a choice made here.** `comment_endorsements_select_own` returns one
 * person's rows: their own. Endorsing requires holding a rating, ratings are readable only by
 * their author, so a list of endorsers would publish the private position of everybody on it by
 * inference — "this captures my view" on a contribution written from 8 places its endorser near
 * 8. There is deliberately no function here that takes a comment id and returns people, and
 * adding one would not work if it were written.
 *
 * **Counts are not here either.** They come from the export, like every other number on this
 * site, because a browser cannot count rows it cannot read. A reader's own action shows
 * immediately and optimistically; the total settles at the next export, minutes later.
 */
import { getSupabase } from './supabase';

export type EndorsementKind = 'captures_my_view' | 'agree_position_not_reason';

/**
 * The two actions, in the order they are offered.
 *
 * The label is the whole distinction between this and a vote, so it is spelled out in words
 * every time and never compressed to a glyph. A vote count and a shared-reason count render
 * identically as a number and do opposite things: one ranks contributions against each other
 * and rewards whoever phrased it most sharply, the other measures how many people hold a reason.
 */
export const ENDORSEMENT_ACTIONS: readonly {
  readonly kind: EndorsementKind;
  /** What the button says when the reader has not taken this action. */
  readonly label: string;
  /** What it says once they have, so the control reads as a state and not only as an offer. */
  readonly chosen: string;
  /** Whether this is the prominent one. Exactly one is. */
  readonly primary: boolean;
}[] = [
  {
    kind: 'captures_my_view',
    label: 'This also captures my view',
    chosen: 'This captures your view',
    primary: true,
  },
  {
    kind: 'agree_position_not_reason',
    label: 'I agree with the position, but not this reason',
    chosen: 'You agree with the position, not this reason',
    primary: false,
  },
];

/** How a count is said. Always in words, never as a bare number beside a glyph. */
export function endorsementSentence(kind: EndorsementKind, count: number): string {
  if (kind === 'captures_my_view') {
    return count === 1
      ? '1 person says this captures their view'
      : `${count} people say this captures their view`;
  }

  return count === 1
    ? '1 person agrees with the position but not this reason'
    : `${count} people agree with the position but not this reason`;
}

export type Result<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly message: string };

const UNAVAILABLE =
  'The database cannot be reached right now, so that was not recorded. Try again in a few minutes.';

interface Row {
  comment_id: string;
  kind: EndorsementKind;
  created_at: string;
}

/** One of the reader's own endorsements. */
export interface MyEndorsement {
  readonly kind: EndorsementKind;
  /**
   * When it was first made. Compared with the export time a page was built from, it says
   * whether the count on that page already includes it — which is what lets the reader's own
   * endorsement survive a reload instead of dropping out of the number until the next build.
   */
  readonly createdAt: string;
}

/**
 * Which of these contributions the reader has endorsed, and how.
 *
 * One query for the whole page rather than one per contribution. The `in` list is the
 * contributions actually on the page, which is bounded by what the build rendered.
 *
 * Returns an empty map rather than an error when the reader has endorsed nothing, because that
 * is the ordinary case and not a failure.
 */
export async function loadMyEndorsements(
  commentIds: readonly string[],
  userId: string,
): Promise<Result<Map<string, MyEndorsement>>> {
  if (commentIds.length === 0) return { ok: true, value: new Map() };

  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('comment_endorsements')
      .select('comment_id,kind,created_at')
      .eq('user_id', userId)
      .in('comment_id', [...commentIds]);

    if (error) return { ok: false, message: describe(error) };

    // Cast at the row, the way src/lib/comments.ts does for a multi-row select. `.returns<T>()`
    // is deprecated in supabase-js 2.58, and a select string this short keeps its literal type
    // anyway — the cast is here for the shape, not to rescue an inference that was lost.
    return {
      ok: true,
      value: new Map(
        (data ?? []).map((row) => {
          const typed = row as unknown as Row;
          return [typed.comment_id, { kind: typed.kind, createdAt: typed.created_at }] as const;
        }),
      ),
    };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/**
 * Take one of the two actions, replacing the other if it was taken.
 *
 * INSERT then UPDATE rather than `upsert()`, for the same reason ratings were written that way
 * before `public.answer_claim()` took over:
 * upsert generates `ON CONFLICT DO UPDATE SET comment_id, user_id, kind`, PostgreSQL checks
 * column-level UPDATE privileges at parse time for every column in the SET clause even when no
 * conflict occurs, and `kind` is the only one granted. An upsert therefore fails with 42501
 * every time, conflict or not.
 */
export async function setEndorsement(
  commentId: string,
  userId: string,
  kind: EndorsementKind,
): Promise<Result<null>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { error: insertError } = await supabase
      .from('comment_endorsements')
      .insert({ comment_id: commentId, user_id: userId, kind });

    if (!insertError) return { ok: true, value: null };

    // 23505 is the one-per-person constraint, which means they have already taken one of the
    // two actions and this is a change of mind rather than a new row.
    if (insertError.code !== '23505') {
      return { ok: false, message: describe(insertError) };
    }

    const { error: updateError } = await supabase
      .from('comment_endorsements')
      .update({ kind })
      .eq('comment_id', commentId)
      .eq('user_id', userId);

    if (updateError) return { ok: false, message: describe(updateError) };
    return { ok: true, value: null };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/** Withdraw entirely. A hard delete — see 20260822100000 for why a count may go down. */
export async function withdrawEndorsement(
  commentId: string,
  userId: string,
): Promise<Result<null>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { error } = await supabase
      .from('comment_endorsements')
      .delete()
      .eq('comment_id', commentId)
      .eq('user_id', userId);

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: null };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Turning a failure into a sentence ─────────────────────────────────────────────────

function describe(error: unknown): string {
  const code =
    typeof error === 'object' && error !== null && 'code' in error
      ? String((error as { code?: unknown }).code ?? '')
      : '';

  const message =
    error instanceof Error
      ? error.message
      : String((error as { message?: unknown })?.message ?? error ?? '');
  const lower = message.toLowerCase();

  switch (code) {
    // Every clause of the insert policy that a signed-in reader can fail arrives as this: they
    // have not answered the claim, it is their own contribution, or the account is suspended.
    // The interface asks about the first two before offering the control, so the honest fallback
    // names the one it could not have known about.
    case '42501':
      return 'That did not go through. Answer the claim first — and if you already have, the account may not be confirmed yet.';
    case '23505':
      return 'You had already said something about this one. Reload the page to see which.';
    /**
     * The site is newer than the database it is talking to.
     *
     * `42703` is an unknown column and `42P01` an unknown table or view. Either means the
     * deployed pages are asking for something a migration has not created yet — which is a real
     * state on this project rather than a theoretical one: `migrate.yml` runs only on `main`, and
     * on `main` it runs on the *same push* as the deploy rather than before it. So a branch
     * preview, and a short window after every merge, both look like this.
     *
     * Named rather than left to the generic fallback, because the fallback says "nothing was
     * saved" — and for a read that is beside the point, while for a write it is often false.
     */
    case '42703':
    case '42P01':
      return 'This part of the site is newer than the database it reads from, so that is not available yet. Nothing you did is lost; try again shortly.';
    case 'PGRST301':
      return 'Your session has ended. Sign in again.';
  }

  if (
    lower.includes('failed to fetch') ||
    lower.includes('fetch failed') ||
    lower.includes('networkerror') ||
    lower.includes('load failed')
  ) {
    return UNAVAILABLE;
  }

  return 'That did not go through, and nothing was recorded. If it keeps failing, the details are worth reporting.';
}
