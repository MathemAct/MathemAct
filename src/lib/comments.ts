/**
 * Discussion: reading a thread at build time, and the four things a browser does to one.
 *
 * Same shape as src/lib/reports.ts — `readComments()` is the single swap point, reads
 * happen during the build, writes happen in a browser.
 *
 * **This module returns source text and never HTML.** Source becomes markup in
 * src/lib/markdown.ts: at build time for everything in the corpus, and since 2026-10-11 in
 * the browser too, through src/lib/render-live.ts, for a comment somebody has just written or
 * edited and for anything the overlay finds changed since the build. That reverses what this
 * header used to say — that live comments are shown as plain text because rendering in the
 * browser means shipping a parser and doing the sanitising "in the place an attacker
 * controls". The parser is fetched only by a page that has something to set, and the
 * sanitiser runs in each reader's own browser on text the database returned, with the same
 * schema the build uses; no HTML is ever stored. Text shown as source turned out to read as
 * a broken site to the person who had just posted it.
 */
import { getSupabase } from './supabase';

export type ParentType = 'report' | 'claim';

export interface CommentAuthor {
  readonly id: string;
  readonly displayName: string;
  readonly isPseudonym: boolean;
  readonly institution: {
    readonly name: string;
    readonly country: string;
    readonly verifiedAt: string;
  } | null;
}

export interface Comment {
  readonly id: string;
  readonly parentType: ParentType;
  readonly parentId: string;
  readonly inReplyTo: string | null;
  /** Markdown source. Empty exactly when the comment has been deleted. */
  readonly body: string;
  readonly createdAt: string;
  readonly updatedAt: string;
  /** Set means the body is gone and so is the name. The node stays. */
  readonly deletedAt: string | null;
  /** Null for a deleted comment and for one whose author erased their account. */
  readonly author: CommentAuthor | null;

  /**
   * The position its author held when they wrote it. **Two different facts share the null.**
   *
   * On a report comment it is always null: a report comment argues from no position. On a
   * claim contribution null means the author answered "no opinion, or outside my expertise" —
   * the off-scale option, which is a real answer on a real rating row. It never means "unset",
   * because the database refuses a contribution from somebody holding no rating at all.
   *
   * `parentType` is what tells the two apart, and every consumer that renders this has to
   * consult it. See `groupKeyFor()` in src/lib/positions.ts, which is the one place that
   * decides which group a contribution belongs in.
   */
  readonly agreementScore: number | null;
  /**
   * Whether `agreementScore` is a recorded answer at all.
   *
   * False on exactly one kind of row: a claim contribution from an export written before
   * 2026-08-22, when the column did not exist. Without this, that row's absent score would be
   * indistinguishable from a null one and would be filed under "no opinion, or outside my
   * expertise" — **publishing a position its author never took.** A stale file is not a reason
   * to put words in somebody's mouth, so those contributions are grouped as unrecorded until
   * the next export gives them their real score.
   *
   * Always true for a report comment, whose null means "this argues from no position" and is
   * correct rather than missing.
   */
  readonly positionKnown: boolean;
  /** A later contribution by the same author on the same claim, if there is one. */
  readonly supersededBy: string | null;
  /** The same relation from the other end: this one replaced an earlier contribution. */
  readonly supersedesEarlier: boolean;
  /**
   * When the edit window closed early, or null while it is still open on that count.
   *
   * Stamped by the first endorsement and **never cleared**, so it stays set after every
   * endorsement has been withdrawn. That is why the interface reads this rather than inferring
   * from the counts: both counts can be zero on a contribution whose text is fixed, and an Edit
   * button offered there is one the guard refuses.
   */
  readonly endorsedAt: string | null;
  /** Counts, never endorsers. Naming them would publish their positions by inference. */
  readonly endorsements: {
    readonly capturesMyView: number;
    readonly agreePositionNotReason: number;
  };
}

/** A comment and the replies under it. There is no third level; the database refuses one. */
export interface CommentNode {
  readonly comment: Comment;
  readonly replies: readonly Comment[];
}

// ── The swap point ────────────────────────────────────────────────────────────────────

const EXPORTED = import.meta.glob<{ default: Comment[] }>('/data/comments.json', {
  eager: true,
});

let cached: Comment[] | null = null;

/**
 * The committed export, and nothing else. Threads are built from it; the live query below
 * is the overlay that adds anything posted since, and it never renders the page.
 *
 * Deleted comments are in the file, already empty — the node has to survive or the replies
 * under it stop making sense, and the marker a reader sees is rendered from `deletedAt`
 * rather than stored, so it can never end up in the export as though somebody wrote it.
 */
async function readComments(): Promise<Comment[]> {
  if (cached) return cached;

  const exported = Object.values(EXPORTED)[0]?.default;

  if (!exported) {
    console.warn(
      '[comments] data/comments.json is missing, so no discussion is built into any page. ' +
        'Run scripts/export.mjs, or let .github/workflows/export.yml commit one.',
    );
    cached = [];
    return cached;
  }

  // Normalised rather than trusted. An export written before 2026-08-22 has no
  // `agreementScore`, no `supersededBy` and no `endorsements`, and the type here says they are
  // present — so without this every consumer reads `undefined` through a field TypeScript has
  // promised is a number or a null. The same shape of defaulting as `listClaimStats()`, and
  // for the same reason: `data/` is a historical document and older files are still valid.
  cached = exported.map((comment) => ({
    ...comment,
    agreementScore: comment.agreementScore ?? null,
    // `in`, not `?? `: an explicit null is the off-scale answer and an absent key is an older
    // file. Collapsing the two would label a contribution "no opinion" on no evidence.
    positionKnown: comment.parentType !== 'claim' || 'agreementScore' in comment,
    supersededBy: comment.supersededBy ?? null,
    supersedesEarlier: comment.supersedesEarlier ?? false,
    endorsedAt: comment.endorsedAt ?? null,
    endorsements: {
      capturesMyView: comment.endorsements?.capturesMyView ?? 0,
      agreePositionNotReason: comment.endorsements?.agreePositionNotReason ?? 0,
    },
  }));

  return cached;
}

/**
 * `agreement_score` and `superseded_by` are readable by anybody who can read the comment —
 * neither has a write grant, both are set server-side. The endorsement **counts** are not
 * available here: public.comment_endorsements is readable only by its own author, so a
 * browser cannot count them and must not appear to. Anything showing a count reads it from
 * the export, which runs as service role.
 *
 * `supersedes_earlier` is likewise absent: it is an `exists` the export computes, and the
 * overlay has no cheap way to ask it. A contribution fetched live carries `false` and gains
 * the flag at the next build, which is the same shape of staleness the overlay has everywhere.
 */
const SELECT = [
  'id,parent_type,parent_id,in_reply_to,body,created_at,updated_at,deleted_at',
  'agreement_score,superseded_by,endorsed_at',
  'author:profiles!comments_author_id_fkey(id,display_name,is_pseudonym,institution_name,institution_country,institution_verified_at)',
].join(',');

interface RawComment {
  id: string;
  parent_type: ParentType;
  parent_id: string;
  in_reply_to: string | null;
  body: string;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
  agreement_score: number | null;
  superseded_by: string | null;
  endorsed_at: string | null;
  author: {
    id: string;
    display_name: string;
    is_pseudonym: boolean;
    institution_name: string | null;
    institution_country: string | null;
    institution_verified_at: string | null;
  } | null;
}

function toComment(row: RawComment): Comment {
  return {
    id: row.id,
    parentType: row.parent_type,
    parentId: row.parent_id,
    inReplyTo: row.in_reply_to,
    body: row.body,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    deletedAt: row.deleted_at,
    agreementScore: row.agreement_score ?? null,
    // The column is always in the SELECT, so a live row's score is always recorded — a null
    // here is the off-scale answer and nothing else.
    positionKnown: true,
    supersededBy: row.superseded_by ?? null,
    endorsedAt: row.endorsed_at ?? null,
    // Both unavailable over PostgREST — see the note on SELECT. A live-fetched contribution
    // renders with no endorsement count and no movement flag, and picks both up at the next
    // build.
    supersedesEarlier: false,
    endorsements: { capturesMyView: 0, agreePositionNotReason: 0 },
    author: row.author
      ? {
          id: row.author.id,
          displayName: row.author.display_name,
          isPseudonym: row.author.is_pseudonym,
          institution:
            row.author.institution_name &&
            row.author.institution_country &&
            row.author.institution_verified_at
              ? {
                  name: row.author.institution_name,
                  country: row.author.institution_country,
                  verifiedAt: row.author.institution_verified_at,
                }
              : null,
        }
      : null,
  };
}

// ── What pages call ───────────────────────────────────────────────────────────────────

/**
 * One thread, as a list of top-level comments each carrying its replies.
 *
 * A reply whose parent is missing from the corpus — which the database makes impossible but
 * a hand-edited export does not — is promoted to top level rather than dropped. Losing a
 * remark is worse than showing it at the wrong indent.
 */
export async function threadFor(
  parentType: ParentType,
  parentId: string,
): Promise<CommentNode[]> {
  const all = (await readComments()).filter(
    (comment) => comment.parentType === parentType && comment.parentId === parentId,
  );

  const ids = new Set(all.map((comment) => comment.id));
  const roots = all.filter(
    (comment) => comment.inReplyTo === null || !ids.has(comment.inReplyTo),
  );

  return roots.map((comment) => ({
    comment,
    replies: all.filter((reply) => reply.inReplyTo === comment.id),
  }));
}

/** How many comments a thread has, deleted nodes included: the node is still a turn in the
 *  conversation, and a count that dropped it would not match what is on the page. */
export async function commentCount(
  parentType: ParentType,
  parentId: string,
): Promise<number> {
  return (await readComments()).filter(
    (comment) => comment.parentType === parentType && comment.parentId === parentId,
  ).length;
}

// ══ Writes ════════════════════════════════════════════════════════════════════════════

export type Result<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly message: string };

const UNAVAILABLE =
  'The database cannot be reached right now. Your text is still in the box — try again in a few minutes.';

/** The overlay gives up after this. The built thread is already on screen and correct. */
const OVERLAY_TIMEOUT_MS = 4000;

/** And never asks for more than this. With the site rebuilding within minutes of a write, the
 *  rows changed since the export are a handful; this bounds the case where that has stalled. */
const OVERLAY_LIMIT = 100;

/**
 * The thread on this parent as it is now — all of it, or only what changed after `since`.
 *
 * The freshness overlay from CLAUDE.md, for item pages. A built page passes the export time it
 * was built from, and gets back every comment written, edited, deleted, superseded or stamped as
 * endorsed since — the guard bumps `updated_at` on each of those — which is usually nothing. A
 * view page has no build to compare against and passes nothing.
 *
 * Abandoned after a few seconds, and every failure is a `Result` the caller ignores: the built
 * thread stands. Hidden comments are not returned, because row level security does not return
 * them; those leave the page at the next build, minutes later.
 */
export async function loadThread(
  parentType: ParentType,
  parentId: string,
  since?: string | null,
): Promise<Result<Comment[]>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  // A timer rather than `AbortSignal.timeout`, which browsers this audience still uses lack.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), OVERLAY_TIMEOUT_MS);

  try {
    let request = supabase
      .from('comments')
      .select(SELECT)
      .eq('parent_type', parentType)
      .eq('parent_id', parentId);

    if (since) request = request.gt('updated_at', since);

    const { data, error } = await request
      .order('created_at', { ascending: true })
      .limit(OVERLAY_LIMIT)
      .abortSignal(controller.signal);

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: (data ?? []).map((row) => toComment(row as unknown as RawComment)) };
  } catch (error) {
    return { ok: false, message: describe(error) };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * One comment as it is now, source included.
 *
 * For the edit box, which has to start from the markdown somebody wrote rather than from the
 * rendered text on the page — that loses every formula and every bit of formatting. And for a
 * contribution posted through `public.answer_claim()`, which returns only the new id.
 */
export async function loadComment(id: string): Promise<Result<Comment>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('comments')
      .select(SELECT)
      .eq('id', id)
      .single();

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: toComment(data as unknown as RawComment) };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/** Returns the new comment's id, which the caller needs in order to attach a citation to
 *  it — the quote affordance posts the comment first and links it second. */
export async function postComment(
  parentType: ParentType,
  parentId: string,
  authorId: string,
  body: string,
  inReplyTo: string | null,
): Promise<Result<Comment>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('comments')
      .insert({
        parent_type: parentType,
        parent_id: parentId,
        author_id: authorId,
        in_reply_to: inReplyTo,
        body: body.trim(),
      })
      .select(SELECT)
      .single();

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: toComment(data as unknown as RawComment) };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/** Within 24 hours, and only while nobody has replied. Both limits are enforced by the
 *  guard trigger, which raises prose that `describe()` passes through unchanged. */
export async function editComment(id: string, body: string): Promise<Result<null>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { error } = await supabase
      .from('comments')
      .update({ body: body.trim() })
      .eq('id', id);

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: null };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/**
 * Soft delete: the trigger empties the body and strips the name in the same statement.
 * There is nothing kept to restore, and the interface has to say so before it is done.
 */
export async function deleteComment(id: string): Promise<Result<null>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { error } = await supabase
      .from('comments')
      .update({ deleted_at: new Date().toISOString() })
      .eq('id', id);

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: null };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Flagging ──────────────────────────────────────────────────────────────────────────

export type FlagSubject = 'report' | 'claim' | 'comment';

export type FlagReason =
  | 'off_topic'
  | 'abusive'
  | 'third_party_material'
  | 'inaccurate'
  | 'spam'
  | 'other';

/** The wording shown in the control. `third_party_material` is first among the specific
 *  reasons because it is the hazard this site creates: the submission form asks people to
 *  paste real conversations, and those contain other people's unpublished work. */
export const FLAG_REASONS: readonly { value: FlagReason; label: string }[] = [
  { value: 'third_party_material', label: "Contains someone else's unpublished work" },
  { value: 'inaccurate', label: 'Says something about a tool that is not true' },
  { value: 'abusive', label: 'Abusive, or breaches the code of conduct' },
  { value: 'off_topic', label: 'Not about AI use in mathematical work' },
  { value: 'spam', label: 'Spam' },
  { value: 'other', label: 'Something else' },
];

export async function fileFlag(
  subjectType: FlagSubject,
  subjectId: string,
  flaggerId: string,
  reason: FlagReason,
  detail: string,
): Promise<Result<null>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { error } = await supabase.from('flags').insert({
      subject_type: subjectType,
      subject_id: subjectId,
      flagger_id: flaggerId,
      reason,
      detail: detail.trim() || null,
    });

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: null };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Turning a failure into a sentence ─────────────────────────────────────────────────

/**
 * **When a write fails unexpectedly, check the grants before the policies.** A table with
 * no grant and a table whose policy matches no row are indistinguishable from a browser.
 * Grants decide whether the endpoint exists; policies decide which rows it returns.
 *
 * Several of the rules on public.comments raise finished sentences on purpose — the edit
 * window, the reply-freeze, the nesting limit — so 23514 passes the database's own wording
 * through when it reads like prose. That is the whole reason those messages are written the
 * way they are: the person who needs to read them is not the person who wrote the trigger.
 */
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
    case '23514':
      return looksLikeProse(message)
        ? message
        : 'A comment has to say something, and has to fit in 5,000 characters.';

    case '23503':
      return 'That comment is no longer available to reply to. Reload the page.';

    case '23505':
      return 'You have already flagged this. One flag per person — sending it twice is not a stronger signal.';

    case '42501':
      return 'This account cannot do that. It usually means the email address has not been confirmed yet — check the confirmation email.';

    case '53400':
      return looksLikeProse(message)
        ? message
        : 'You have reached what one account can post in a day. Try again tomorrow.';

    // The site is newer than the database it reads from: 42703 is an unknown column, 42P01 an
    // unknown table. Real on this project rather than theoretical — `migrate.yml` runs only on
    // `main`, and there on the same push as the deploy rather than before it, so a branch
    // preview and a short window after every merge both look like this.
    case '42703':
    case '42P01':
      return 'This part of the site is newer than the database it reads from, so that is not available yet. Nothing you wrote is lost; try again shortly.';
    case 'PGRST301':
      return 'Your session has ended. Sign in again — your text is still in the box.';
  }

  if (
    lower.includes('failed to fetch') ||
    lower.includes('fetch failed') ||
    lower.includes('networkerror') ||
    lower.includes('load failed')
  ) {
    return UNAVAILABLE;
  }

  return 'That did not go through, and nothing was posted. If it keeps failing, the details are worth reporting.';
}

function looksLikeProse(message: string): boolean {
  return /^[A-Z].*[.!?]$/.test(message.trim()) && !message.includes('_');
}
