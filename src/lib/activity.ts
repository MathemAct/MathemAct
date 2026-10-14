/**
 * The activity feed: reading somebody's own events, and turning them into sentences.
 *
 * This is a browser-only module, like src/lib/moderation.ts and for the same kind of reason.
 * A feed is made of exactly the rows the static export must never contain — one person's
 * private view of what they did and what happened to them — so it cannot be built at build
 * time, and the page that shows it is under /account/, which already loads the Supabase
 * client. Nothing here is imported from Astro frontmatter and nothing here may be.
 *
 * The database stores events, not messages: a kind, a target, a timestamp, sometimes an
 * actor. Every word a person reads is composed here, in `describe()`. That is the whole
 * reason this feature is not the "message table" rejected on 2026-08-16 — there is no prose
 * sitting in a row going stale, and rewording a notification is a change to this file rather
 * than a migration over history.
 *
 * Three things `describe()` is careful about, all inherited from the schema:
 *
 *   * **A moderation outcome never names the moderator.** The row carries no actor for one,
 *     so the sentence cannot accidentally acquire a name later.
 *   * **A moderation outcome never carries the reason either.** This table holds events; the
 *     sentence a moderator wrote is in public.moderation_notices, addressed to the person it
 *     is about, and src/lib/notices.ts reads it. A feed row says that something was decided
 *     and where to read why, which is why several of them now link to /account/#decisions.
 *   * **A rating never names the rater.** public.ratings is readable only by its author,
 *     which is what keeps a claim's aggregate hidden until you have taken a position;
 *     "Somebody rated" is the most that may ever be said.
 */
import { getSupabase } from './supabase';
import { path } from './paths';

export type Result<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly message: string };

const UNAVAILABLE =
  'Your activity cannot be loaded right now. Nothing has been lost — try again in a few minutes.';

/** Matches public.activity_kind. */
export type ActivityKind =
  | 'posted_report'
  | 'edited_report'
  | 'posted_claim'
  | 'posted_entry'
  | 'commented'
  | 'rated_claim'
  | 'confirmed_report'
  | 'flagged'
  | 'cited'
  | 'content_kept'
  | 'report_published'
  | 'report_changes_requested'
  | 'entry_published'
  | 'entry_changes_requested'
  | 'claim_promoted'
  | 'content_hidden'
  | 'content_unhidden'
  | 'account_banned'
  | 'account_unbanned'
  | 'flag_resolved'
  | 'flag_dismissed'
  | 'content_commented'
  | 'comment_reply'
  | 'claim_rated'
  | 'report_confirmed'
  | 'content_cited';

/** Matches public.moderation_target, which public.activity reuses. */
export type ActivityTarget = 'report' | 'claim' | 'comment' | 'flag' | 'entry' | 'account';

export interface ActivityItem {
  readonly id: string;
  readonly kind: ActivityKind;
  /** True when somebody else caused it. Only these count as new. */
  readonly isInbound: boolean;
  readonly actorName: string | null;
  readonly actorIsPseudonym: boolean;
  readonly targetType: ActivityTarget;
  readonly targetId: string;
  readonly commentId: string | null;
  readonly label: string | null;
  readonly createdAt: string;
  /**
   * How many events this row stands for. Always 1 except where `collapse()` below has
   * folded a run of ratings on one claim into a single line.
   */
  readonly count: number;
}

/**
 * The row as it comes back, named rather than inferred.
 *
 * supabase-js types `data` from the *literal type* of the select string, so this exists to
 * be handed to `.overrideTypes<>()`. Getting that wrong types every field below as an error
 * object and produces a screen of complaints that read like renamed columns — see the note
 * in CLAUDE.md. `merge: false` because this replaces the inferred row rather than adding to
 * it: the embedded `actor` comes back as an object here and supabase-js cannot tell that
 * from a one-element array without the schema types generated.
 */
interface ActivityRow {
  id: string;
  kind: ActivityKind;
  is_inbound: boolean;
  target_type: ActivityTarget;
  target_id: string;
  comment_id: string | null;
  label: string | null;
  created_at: string;
  actor: { display_name: string; is_pseudonym: boolean } | null;
}

/** How many events a page of the feed holds. */
export const PAGE_SIZE = 50;

/**
 * Where the next page starts: the last row of the one before it.
 *
 * Both halves are needed, and the second is not a nicety. `created_at` is nowhere near
 * unique in this table — a trigger writes every row it produces in one transaction, so a
 * single comment lands two rows sharing a timestamp to the microsecond, and the backfill
 * reproduced whole histories that way. An order with ties in it is not a total order, and a
 * page boundary falling inside one is where rows get shown twice or skipped entirely. `id`
 * breaks every tie, so the sort is deterministic and so is the boundary.
 */
export interface ActivityCursor {
  readonly createdAt: string;
  readonly id: string;
}

export interface ActivityPage {
  readonly items: ActivityItem[];
  /** Where to resume, or null when this was the last page. */
  readonly cursor: ActivityCursor | null;
}

// ── Reading ───────────────────────────────────────────────────────────────────────────

/**
 * One page of somebody's feed, newest first.
 *
 * Keyset rather than offset, for two reasons in that order of importance. `.range()` is only
 * stable if the sort is total, and this one is full of ties — see ActivityCursor. And an
 * offset walks every row it skips, which a feed people page to the bottom of will notice
 * before anything else here does.
 *
 * Ratings are *not* collapsed here. Folding a run of them into "5 people rated your claim"
 * has to happen across everything loaded so far, or the same claim collapses separately on
 * each page and reads as two events. The caller accumulates raw rows and runs
 * collapseRatings() over the whole list; see the note on that function.
 */
export async function loadActivity(
  userId: string,
  after: ActivityCursor | null = null,
): Promise<Result<ActivityPage>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    // One string literal, never assembled with `+`. The `actor:actor_id(...)` hint names
    // the foreign key column because this table has two references to profiles and
    // PostgREST cannot pick between them on its own.
    let query = supabase
      .from('activity')
      .select(
        'id, kind, is_inbound, target_type, target_id, comment_id, label, created_at, actor:actor_id(display_name, is_pseudonym)',
      )
      .eq('subject_id', userId);

    if (after) {
      // "Strictly after this row in the sort order", written out because that is what a
      // composite keyset is.
      //
      // The timestamp goes back exactly as PostgREST returned it and must never be
      // round-tripped through Date: timestamptz carries microseconds and a JS Date carries
      // milliseconds, so reformatting moves the boundary by up to 999µs and quietly drops
      // or repeats whatever sits in that gap. postgrest-js appends this through
      // URLSearchParams, which encodes the `+` of the zone offset, so it arrives intact.
      query = query.or(
        `created_at.lt.${after.createdAt},` +
          `and(created_at.eq.${after.createdAt},id.lt.${after.id})`,
      );
    }

    // One more row than a page, purely to learn whether there is another one. Cheaper and
    // more honest than a count, which would answer a question nobody asked — nobody needs to
    // be told there are 412 events, only whether they have reached the end.
    const { data, error } = await query
      .order('created_at', { ascending: false })
      .order('id', { ascending: false })
      .limit(PAGE_SIZE + 1)
      .overrideTypes<ActivityRow[], { merge: false }>();

    if (error) return { ok: false, message: describeError(error) };

    const rows = data ?? [];
    const more = rows.length > PAGE_SIZE;
    const page = more ? rows.slice(0, PAGE_SIZE) : rows;
    const last = page.at(-1);

    return {
      ok: true,
      value: {
        items: page.map(toItem),
        cursor: more && last ? { createdAt: last.created_at, id: last.id } : null,
      },
    };
  } catch (error) {
    return { ok: false, message: describeError(error) };
  }
}

/** When this person last looked, or null if they never have. */
export async function loadSeenAt(userId: string): Promise<string | null> {
  const supabase = getSupabase();
  if (!supabase) return null;

  try {
    const { data, error } = await supabase
      .from('activity_seen')
      .select('seen_at')
      .eq('user_id', userId)
      .maybeSingle<{ seen_at: string }>();

    if (error || !data) return null;
    return data.seen_at;
  } catch {
    return null;
  }
}

/**
 * Move the watermark to now. Called once the feed has rendered, never before — the "new"
 * markers are computed against the previous value, so writing first would mean nothing was
 * ever new.
 *
 * A failure is swallowed. The consequence is that the same items are marked new next time,
 * which is the harmless direction; an error panel over a feed the person is already reading
 * would be worse than a badge that lingers.
 */
export async function markSeen(userId: string): Promise<void> {
  const supabase = getSupabase();
  if (!supabase) return;

  try {
    await supabase
      .from('activity_seen')
      .upsert({ user_id: userId, seen_at: new Date().toISOString() });
  } catch {
    // See above.
  }
}

/**
 * How many inbound events have arrived since the watermark.
 *
 * A head count rather than a fetch, because this runs on report and claim pages — anywhere
 * the Supabase client is already loaded — purely to keep the header's badge roughly honest.
 * It must never be the reason a page is slow, so it asks for no rows at all.
 */
export async function countUnread(userId: string): Promise<number> {
  const supabase = getSupabase();
  if (!supabase) return 0;

  try {
    const seenAt = await loadSeenAt(userId);

    let query = supabase
      .from('activity')
      .select('id', { count: 'exact', head: true })
      .eq('subject_id', userId)
      .eq('is_inbound', true);

    if (seenAt) query = query.gt('created_at', seenAt);

    const { count, error } = await query;
    if (error) return 0;

    return count ?? 0;
  } catch {
    return 0;
  }
}

function toItem(row: ActivityRow): ActivityItem {
  return {
    id: row.id,
    kind: row.kind,
    isInbound: row.is_inbound,
    actorName: row.actor?.display_name ?? null,
    actorIsPseudonym: row.actor?.is_pseudonym ?? false,
    targetType: row.target_type,
    targetId: row.target_id,
    commentId: row.comment_id,
    label: row.label,
    createdAt: row.created_at,
    count: 1,
  };
}

/**
 * Fold every rating on one claim into a single line.
 *
 * A claim that lands well collects ratings in bursts, and twenty consecutive rows saying
 * "Somebody rated your claim" is not twenty pieces of information — it is one, badly told,
 * burying everything else in the feed. The surviving row is the most recent of the run and
 * carries the count, so the line reads "20 people rated your claim" and sits where the
 * latest of them did.
 *
 * Only ratings. Comments, confirmations and citations each name a person and each say
 * something different, so folding those would lose the part worth reading.
 *
 * **Run over every page loaded so far, never over one page.** Ratings on one claim do not
 * respect a page boundary, so collapsing per page would show that claim as two separate
 * events with two separate counts — worse than not collapsing at all, because it reads as
 * two things having happened. Folding across the whole list means a count further up the
 * page can grow as somebody reads downward. That is the correct number arriving late rather
 * than a wrong one, and it is the cheaper of the two surprises.
 */
export function collapseRatings(items: readonly ActivityItem[]): ActivityItem[] {
  const out: ActivityItem[] = [];
  const seen = new Map<string, number>();

  for (const item of items) {
    if (item.kind !== 'claim_rated') {
      out.push(item);
      continue;
    }

    const at = seen.get(item.targetId);

    if (at === undefined) {
      seen.set(item.targetId, out.length);
      out.push(item);
      continue;
    }

    out[at] = { ...out[at], count: out[at].count + 1 };
  }

  return out;
}

// ── Saying it ─────────────────────────────────────────────────────────────────────────

export interface ActivityLine {
  /** A complete sentence. The label, if there is one, is shown beneath it as the link. */
  readonly text: string;
  readonly label: string | null;
  readonly href: string | null;
}

/**
 * What a remark on this thing is called.
 *
 * A remark on a report is a **comment**; a remark on a claim is a **contribution**. That is the
 * opinions vocabulary and it reaches the feed, because the feed is where somebody is told about
 * one — a notice saying "somebody commented on your claim" teaches the word the section spent
 * a redesign avoiding.
 */
function remark(target: ActivityTarget): string {
  return target === 'claim' ? 'contribution' : 'comment';
}

/** "a report" / "a claim" / "an entry", for sentences that need the noun. */
function noun(target: ActivityTarget): string {
  switch (target) {
    case 'report':
      return 'report';
    case 'claim':
      return 'claim';
    case 'entry':
      return 'network entry';
    default:
      return 'post';
  }
}

/**
 * Who did it, in a form safe to print.
 *
 * "Somebody" is not a fallback for a missing join — it is the correct answer whenever the
 * row carries no actor, which is every moderation outcome and every rating. It is also what
 * an erased account reads as, which is the same sentence for the same reason.
 */
function who(item: ActivityItem): string {
  return item.actorName ?? 'Somebody';
}

/**
 * Where the row points.
 *
 * Reports and claims go to the client-rendered view pages rather than to /reports/<id>/,
 * and that is the same rule the freshness overlay follows. A feed is a list of things that
 * just happened, so it is precisely the place where the last nightly export cannot be
 * trusted to contain the row — and a link to a static page that has not been built yet is a
 * 404 dressed up as a result.
 *
 * Anything a moderator decided goes to the account page rather than to the thing itself.
 * That is where the explanation is — a feed row says *that* something was decided and the
 * sentence is in public.moderation_notices — and for a hide it is also the only page that
 * still works, since the post is off the site.
 *
 * Null for the rows where a link would be a lie: a flag, which has no page, and an account
 * action, which is about you rather than about a thing.
 */
function href(item: ActivityItem): string | null {
  switch (item.kind) {
    case 'edited_report':
    case 'report_changes_requested':
    case 'entry_changes_requested':
      return path('/account/#your-submissions');

    case 'content_hidden':
    case 'content_unhidden':
    case 'content_kept':
      return path('/account/#decisions');

    case 'flagged':
    case 'flag_resolved':
    case 'flag_dismissed':
      return path('/account/#decisions');

    // Since 20260819120000 a ban writes public.moderation_notices like every other decision,
    // so there is somewhere for this row to go. It used to return null because there was
    // genuinely nothing to link to: the sentence a moderator was required to write reached the
    // audit log and stopped, and this was the only thing the account was ever told.
    case 'account_banned':
    case 'account_unbanned':
      return path('/account/#decisions');

    default:
      break;
  }

  const fragment = item.commentId ? `#comment-${item.commentId}` : '';

  switch (item.targetType) {
    case 'report':
      return `${path('/reports/view/')}?id=${item.targetId}${fragment}`;
    case 'claim':
      return `${path('/opinions/view/')}?id=${item.targetId}${fragment}`;
    case 'entry':
      return path('/network/');
    default:
      return null;
  }
}

/** One event as a sentence, a label, and somewhere to go. */
export function describe(item: ActivityItem): ActivityLine {
  return { text: sentence(item), label: item.label, href: href(item) };
}

function sentence(item: ActivityItem): string {
  switch (item.kind) {
    // ── Things you did ───────────────────────────────────────────────────────────────
    case 'posted_report':
      return 'You posted a report. It is in the corpus.';
    case 'edited_report':
      return 'You revised a hidden report and asked for it to be looked at again.';
    case 'posted_claim':
      return 'You suggested a claim.';
    case 'posted_entry':
      return 'You submitted an entry to the network.';
    case 'commented':
      return item.targetType === 'claim'
        ? 'You wrote a contribution on a claim.'
        : `You commented on a ${noun(item.targetType)}.`;
    case 'rated_claim':
      // "Answered" rather than "rated", which is the section's vocabulary — and it is also the
      // only word that covers an explicit "no opinion": that is a real answer, and calling it a
      // rating would file a declared non-opinion as a score.
      return 'You answered a claim.';
    case 'confirmed_report':
      // "Reproduces" rather than "still works", because a feed row does not carry the
      // report's outcome and half of them are answering "does this still not work?". A
      // reproduced failure is the same act as a reproduced success and gets the same
      // sentence; the report page is where the two questions are told apart.
      return 'You said whether a report still reproduces.';
    case 'flagged':
      return 'You flagged something for the moderators.';
    case 'cited':
      return `You referenced a ${noun(item.targetType)}.`;

    // ── Moderation ───────────────────────────────────────────────────────────────────
    // The five that follow are pre-moderation history. Nothing has written them since
    // 2026-08-18 — there is no approval step to be published by and no change request to
    // answer — but rows carrying them are in feeds, so the sentences stay.
    case 'report_published':
      return 'A moderator published your report. It is part of the corpus now.';
    case 'report_changes_requested':
      return 'A moderator asked for changes to your report. What to change is under "Your submissions".';
    case 'entry_published':
      return 'A moderator published your network entry.';
    case 'entry_changes_requested':
      return 'A moderator asked for changes to your network entry.';
    case 'claim_promoted':
      return 'A moderator opened your claim for answers.';

    case 'content_hidden':
      return item.commentId
        ? `A moderator hid your ${remark(item.targetType)}. The reason is with your moderation decisions.`
        : `A moderator hid your ${noun(item.targetType)}. The reason is with your moderation decisions.`;
    case 'content_unhidden':
      return item.commentId
        ? `A moderator restored your ${remark(item.targetType)}.`
        : `A moderator restored your ${noun(item.targetType)}.`;
    case 'content_kept':
      // The one row that tells an author a flag existed. It says what was decided and never
      // who raised it; see the migration for why that trade was made deliberately.
      return item.commentId
        ? `Somebody flagged your ${remark(item.targetType)}. A moderator looked and left it where it was.`
        : `Somebody flagged your ${noun(item.targetType)}. A moderator looked and left it where it was.`;
    case 'account_banned':
      return 'Your account has been suspended. You can still read the site, but not post. The reason is with your moderation decisions.';
    case 'account_unbanned':
      return 'Your account has been restored. You can post again. The reason is with your moderation decisions.';
    case 'flag_resolved':
      return 'Something you flagged was taken off the site. The reason is with your moderation decisions.';
    case 'flag_dismissed':
      return 'A moderator looked at something you flagged and left it where it was. The reason is with your moderation decisions.';

    // ── Other people ─────────────────────────────────────────────────────────────────
    case 'content_commented':
      return item.targetType === 'claim'
        ? `${who(item)} wrote a contribution on your claim.`
        : `${who(item)} commented on your ${noun(item.targetType)}.`;
    case 'comment_reply':
      // Replies exist on reports only since 2026-08-22, so in practice this is always a comment
      // — but rows predating that may name a claim, and the word follows the subject either way.
      return `${who(item)} replied to your ${remark(item.targetType)}.`;
    case 'claim_rated':
      // Never a name: see the header. The count is what this line is for.
      return item.count === 1
        ? 'Somebody answered your claim.'
        : `${item.count} people answered your claim.`;
    case 'report_confirmed':
      return `${who(item)} said whether your report still reproduces.`;
    case 'content_cited':
      return `${who(item)} referenced your ${noun(item.targetType)}.`;
  }
}

function describeError(error: unknown): string {
  const code =
    typeof error === 'object' && error !== null && 'code' in error
      ? String((error as { code?: unknown }).code ?? '')
      : '';

  if (code === '42501') {
    return 'This session is no longer signed in. Sign in again to see your activity.';
  }

  return UNAVAILABLE;
}
