/**
 * The moderation queue: what has been flagged, what is hidden, and the one function that
 * acts on either.
 *
 * **There is no approval queue.** Since the move to post-moderation nothing waits to be
 * published — a report, a claim and a network entry are all live the moment they are
 * written — so what a moderator opens this screen for is a flag somebody raised. The two
 * lists below are that queue and its consequences: open flags, and everything currently
 * hidden so that a decision can be reversed.
 *
 * Everything here runs in a browser. That is unlike the rest of src/lib/, where reads happen
 * at build time and only writes reach the database — and it is forced rather than chosen. A
 * queue is made of exactly the rows the static export does not contain: open flags, hidden
 * content, standing erasure requests. None of them may be built into a public file, and none
 * of them is visible to the anonymous key the build uses. So the moderation screen is the one
 * page on this site that genuinely needs a live session, and it is the only reading page that
 * loads the Supabase client.
 *
 * Two rules shape every query below.
 *
 * **No address, ever.** There is no email column in the exposed schema and there is no
 * function that returns one, so this is not a matter of discipline here — but the rule is
 * worth restating where a moderator's screen is being designed, because "who is this person"
 * is exactly the question that invites somebody to add one. A moderator sees a display name
 * and a badge, the same as any reader.
 *
 * **Nothing changes state except through `act()`.** It calls public.moderate(), which is the
 * only route the database now offers: the moderator UPDATE policies were dropped in
 * 20260815200300, so a direct write from here would silently do nothing. That is deliberate.
 * The effect and its audit row are one transaction, so there is no ordering of events in
 * which something is hidden and no row says who hid it.
 */
import { getSupabase } from './supabase';
import type { Area, TaskType } from './report-schema';
import type { Outcome } from './status';
import type { FlagReason, FlagSubject } from './comments';

export type Result<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly message: string };

const UNAVAILABLE =
  'The database cannot be reached right now. Nothing was changed. Try again in a few minutes.';

// ── Who is looking ────────────────────────────────────────────────────────────────────

export type Role = 'member' | 'moderator' | 'admin';

export function moderates(role: Role): boolean {
  return role === 'moderator' || role === 'admin';
}

/**
 * The signed-in person's role, read from their own profile row.
 *
 * A failure returns 'member'. The gate this feeds is "show the moderation screen or show a
 * page not found", and the safe answer to "we could not tell" is the 404 — an interface that
 * revealed itself whenever the network hiccuped would be worse than useless, because the one
 * thing it must not do is confirm that the address exists to someone who is guessing.
 */
export async function loadRole(userId: string): Promise<Role> {
  const supabase = getSupabase();
  if (!supabase) return 'member';

  try {
    const { data, error } = await supabase
      .from('profiles')
      .select('role, is_banned')
      .eq('id', userId)
      .maybeSingle<{ role: string; is_banned: boolean }>();

    if (error || !data || data.is_banned) return 'member';
    return data.role === 'admin' || data.role === 'moderator' ? data.role : 'member';
  } catch {
    return 'member';
  }
}

// ── What a queue item carries ─────────────────────────────────────────────────────────
// Enough to decide without opening anything else. A moderator who has to click through to
// read the verification section will stop reading it, and that section is the whole reason
// this corpus is worth having.

export interface QueueAuthor {
  readonly id: string;
  readonly displayName: string;
  readonly isPseudonym: boolean;
  readonly institution: { readonly name: string; readonly country: string } | null;
  /**
   * Whether this account is banned already.
   *
   * On the moderation screen only, and it decides two things: the row says so beside the name,
   * and the "Ban that account" button is removed rather than offered and refused. Without it a
   * moderator answering a flag cannot tell that the author is already banned — which is
   * precisely the context where it matters — and every flag row offered a control that
   * `public.moderate()` would turn down.
   *
   * It is **not** in the export and must not be: `scripts/export.mjs` refuses
   * `profiles.is_banned` alongside `profiles.role`, because a public list of banned accounts is
   * a punishment nobody agreed to. Nothing built from `data/` knows this, and no page a reader
   * sees renders it.
   */
  readonly isBanned: boolean;
}

export interface QueueTool {
  readonly name: string;
  readonly version: string;
  readonly usedOn: string;
}

export interface QueueReport {
  readonly id: string;
  readonly status: 'published' | 'hidden';
  readonly title: string;
  readonly area: Area;
  readonly taskType: TaskType;
  readonly aim: string;
  readonly method: string;
  readonly outcome: Outcome;
  readonly outcomeNotes: string;
  readonly verification: string;
  readonly transcriptExcerpt: string | null;
  readonly transcriptUrl: string | null;
  readonly caveats: string | null;
  /** Free text, so it is a moderation surface; the yes/no beside it is not shown here. */
  readonly learnedNotes: string | null;
  readonly thirdPartyMaterialConfirmed: boolean;
  readonly timeSpentMinutes: number | null;
  readonly wasPublished: string | null;
  readonly wasDisclosed: boolean | null;
  readonly authorConfidence: number | null;
  readonly createdAt: string;
  /** Later than createdAt exactly when the author has revised it, which they may do only
   *  while it is hidden. That is the signal to look at it again. */
  readonly updatedAt: string;
  readonly author: QueueAuthor | null;
  readonly tools: readonly QueueTool[];
  readonly tags: readonly string[];
}

export interface QueueClaim {
  readonly id: string;
  readonly status: 'active' | 'hidden';
  readonly statement: string;
  readonly rationale: string | null;
  readonly area: Area;
  readonly createdAt: string;
  readonly author: QueueAuthor | null;
  readonly ratingCount: number;
}

export interface QueueComment {
  readonly id: string;
  readonly body: string;
  readonly createdAt: string;
  readonly status: 'published' | 'hidden';
  readonly author: QueueAuthor | null;
  readonly parentType: 'report' | 'claim';
  readonly parentId: string;
}

export interface QueueEntry {
  readonly id: string;
  readonly status: 'published' | 'hidden';
  readonly title: string;
  readonly url: string;
  readonly category: string;
  readonly description: string;
  /** Retired on 2026-08-21; the description absorbed it. Null on anything submitted since. */
  readonly relevance: string | null;
  readonly createdAt: string;
  readonly updatedAt: string;
  readonly author: QueueAuthor | null;
}

export interface QueueFlag {
  readonly id: string;
  readonly subjectType: FlagSubject;
  readonly subjectId: string;
  readonly reason: FlagReason;
  readonly detail: string | null;
  readonly createdAt: string;
  readonly flagger: QueueAuthor | null;
  /** The flagged thing itself, so the decision can be made on this screen. Null when it
   *  has since been deleted outright — a soft-deleted comment keeps no text. */
  readonly subject: {
    readonly kind: FlagSubject;
    readonly heading: string;
    readonly body: string;
    readonly status: string;
    readonly author: QueueAuthor | null;
  } | null;
  /** The whole submission, when a report was flagged. A moderator deciding from a title is
   *  not deciding, and the verification section — the field that makes this corpus worth
   *  having — is the one most often at issue. Null for every other kind, whose subject
   *  block above already carries the whole of it. */
  readonly report: QueueReport | null;
}

export interface QueueErasure {
  readonly id: string;
  readonly requestedAt: string;
  readonly note: string | null;
  readonly member: QueueAuthor | null;
  /** What erasure will detach. Shown because "this will unname 14 reports" is the fact an
   *  admin needs before pressing the button, and it is not recoverable afterwards. */
  readonly reportCount: number;
  readonly commentCount: number;
}

/**
 * An account, as the accounts section shows it.
 *
 * A ban is the one decision on this screen that is not about a post, so it is the one place a
 * moderator needs a person rather than a row. What is here is what decides a ban: the name and
 * badge, whether they already hold moderation standing — the function refuses to ban those, so
 * the screen offers no button rather than a refusal — and whether they are banned now.
 *
 * `bannedAt` comes from public.moderation_actions rather than from a column on the profile.
 * There is no `banned_at`, and inventing one would put a second copy of a fact the log already
 * holds next to the flag it describes. The log is the record; this is a read of it.
 */
export interface QueueAccount {
  readonly id: string;
  readonly displayName: string;
  readonly isPseudonym: boolean;
  readonly institution: { readonly name: string; readonly country: string } | null;
  readonly role: Role;
  readonly isBanned: boolean;
  readonly joinedAt: string;
  /** When the current ban was imposed, from the audit log. Null when the account is not
   *  banned, and also when it was banned before this screen existed. */
  readonly bannedAt: string | null;
}

/** How many items each queue section loads at a time. */
export const QUEUE_PAGE_SIZE = 20;

export interface QueuePage {
  readonly flags: readonly QueueFlag[];
  readonly flagsHasMore: boolean;
  readonly hiddenReports: readonly QueueReport[];
  readonly hiddenReportsHasMore: boolean;
  readonly hiddenClaims: readonly QueueClaim[];
  readonly hiddenClaimsHasMore: boolean;
  readonly hiddenComments: readonly QueueComment[];
  readonly hiddenCommentsHasMore: boolean;
  readonly hiddenEntries: readonly QueueEntry[];
  readonly hiddenEntriesHasMore: boolean;
  /** Everybody currently banned, so that a ban can be lifted by somebody who did not impose
   *  it. Not paginated: if this list is ever long enough to need it, something has gone wrong
   *  that pagination is not the answer to. */
  readonly bannedAccounts: readonly QueueAccount[];
  /** Empty for a moderator: erasure is an account action and only admins see it. */
  readonly erasures: readonly QueueErasure[];
  readonly erasuresHasMore: boolean;
}

// ── Reading the queues ────────────────────────────────────────────────────────────────

const AUTHOR_COLUMNS =
  'id,display_name,is_pseudonym,institution_name,institution_country,is_banned';

const REPORT_COLUMNS = [
  'id,status,title,area,task_type,aim,method,outcome,outcome_notes,verification',
  'transcript_excerpt,transcript_url,caveats,learned_notes,third_party_material_confirmed',
  'time_spent_minutes,was_published,was_disclosed,author_confidence,created_at,updated_at',
  `author:profiles!reports_author_id_fkey(${AUTHOR_COLUMNS})`,
  'report_tools(tool_name,tool_version,used_on)',
  'report_tags(tags(code))',
].join(',');

const CLAIM_COLUMNS = [
  'id,status,statement,rationale,area,created_at',
  `author:profiles!claims_author_id_fkey(${AUTHOR_COLUMNS})`,
].join(',');

const COMMENT_COLUMNS = [
  'id,body,created_at,status,parent_type,parent_id',
  `author:profiles!comments_author_id_fkey(${AUTHOR_COLUMNS})`,
].join(',');

const NETWORK_COLUMNS = [
  'id,status,title,url,category,description,relevance,created_at,updated_at',
  `author:profiles!network_entries_submitter_id_fkey(${AUTHOR_COLUMNS})`,
].join(',');

interface RawAuthor {
  id: string;
  display_name: string;
  is_pseudonym: boolean;
  institution_name: string | null;
  institution_country: string | null;
  is_banned: boolean;
}

function toAuthor(row: RawAuthor | null | undefined): QueueAuthor | null {
  if (!row) return null;

  return {
    id: row.id,
    displayName: row.display_name,
    isPseudonym: row.is_pseudonym,
    institution:
      row.institution_name && row.institution_country
        ? { name: row.institution_name, country: row.institution_country }
        : null,
    isBanned: row.is_banned,
  };
}

/* eslint-disable @typescript-eslint/no-explicit-any */
function toReport(row: any): QueueReport {
  return {
    id: row.id,
    status: row.status,
    title: row.title,
    area: row.area,
    taskType: row.task_type,
    aim: row.aim,
    method: row.method,
    outcome: row.outcome,
    outcomeNotes: row.outcome_notes,
    verification: row.verification,
    transcriptExcerpt: row.transcript_excerpt,
    transcriptUrl: row.transcript_url,
    caveats: row.caveats,
    learnedNotes: row.learned_notes ?? null,
    thirdPartyMaterialConfirmed: row.third_party_material_confirmed,
    timeSpentMinutes: row.time_spent_minutes,
    wasPublished: row.was_published,
    wasDisclosed: row.was_disclosed,
    authorConfidence: row.author_confidence,
    createdAt: row.created_at,
    updatedAt: row.updated_at ?? row.created_at,
    author: toAuthor(row.author),
    tools: (row.report_tools ?? []).map((tool: any) => ({
      name: tool.tool_name,
      version: tool.tool_version,
      usedOn: tool.used_on,
    })),
    tags: (row.report_tags ?? []).flatMap((link: any) =>
      link.tags ? [link.tags.code] : [],
    ),
  };
}

/**
 * The rating count comes from public.claim_ratings rather than from the ratings table,
 * and it has to. A rating row is readable only by the person who wrote it — that is the rule
 * that keeps individual answers unattributable — so counting through an embed would report
 * how many times the moderator had rated it, which is a plausible-looking zero.
 */
function toClaim(row: any, raters: Map<string, number>): QueueClaim {
  return {
    id: row.id,
    status: row.status,
    statement: row.statement,
    rationale: row.rationale,
    area: row.area,
    createdAt: row.created_at,
    author: toAuthor(row.author),
    ratingCount: raters.get(row.id) ?? 0,
  };
}

function toComment(row: any): QueueComment {
  return {
    id: row.id,
    body: row.body,
    createdAt: row.created_at,
    status: row.status,
    author: toAuthor(row.author),
    parentType: row.parent_type,
    parentId: row.parent_id,
  };
}

function toEntry(row: any): QueueEntry {
  return {
    id: row.id,
    status: row.status,
    title: row.title,
    url: row.url,
    category: row.category,
    description: row.description,
    relevance: row.relevance ?? null,
    createdAt: row.created_at,
    updatedAt: row.updated_at ?? row.created_at,
    author: toAuthor(row.author),
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

/**
 * First page of every queue section, loaded in parallel.
 *
 * Each section is capped at QUEUE_PAGE_SIZE items; the *HasMore flags signal when there
 * is more to fetch. Use loadMoreFlags / loadMoreHidden / loadMoreErasures for subsequent
 * pages — those functions make only the queries they need, whereas this one makes all of
 * them, which is the right trade on the initial load (the page is blank until they settle).
 */
export async function loadQueues(role: Role): Promise<Result<QueuePage>> {
  if (import.meta.env.DEV && usingFixtures()) return { ok: true, value: FIXTURES };

  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const [flags, hiddenReports, hiddenClaims, hiddenComments, hiddenEntries] =
      await Promise.all([
        supabase
          .from('flags')
          .select(
            `id,subject_type,subject_id,reason,detail,created_at,flagger:profiles!flags_flagger_id_fkey(${AUTHOR_COLUMNS})`,
          )
          .eq('status', 'open')
          // Oldest first: the flag that has waited longest is the one to answer next.
          .order('created_at', { ascending: true })
          .range(0, QUEUE_PAGE_SIZE),
        supabase
          .from('reports')
          .select(REPORT_COLUMNS)
          .eq('status', 'hidden')
          .is('deleted_at', null)
          .order('created_at', { ascending: false })
          .range(0, QUEUE_PAGE_SIZE),
        supabase
          .from('claims')
          .select(CLAIM_COLUMNS)
          .eq('status', 'hidden')
          .order('created_at', { ascending: false })
          .range(0, QUEUE_PAGE_SIZE),
        supabase
          .from('comments')
          .select(COMMENT_COLUMNS)
          .eq('status', 'hidden')
          .order('created_at', { ascending: false })
          .range(0, QUEUE_PAGE_SIZE),
        supabase
          .from('network_entries')
          .select(NETWORK_COLUMNS)
          .eq('status', 'hidden')
          .is('deleted_at', null)
          .order('created_at', { ascending: false })
          .range(0, QUEUE_PAGE_SIZE),
      ]);

    const failed = [
      flags,
      hiddenReports,
      hiddenClaims,
      hiddenComments,
      hiddenEntries,
    ].find((response) => response.error);

    if (failed?.error) return { ok: false, message: describe(failed.error) };

    // .range(0, N) fetches N+1 rows. If we got N+1, there are more.
    const flagsData = flags.data ?? [];
    const reportsData = hiddenReports.data ?? [];
    const claimsData = hiddenClaims.data ?? [];
    const commentsData = hiddenComments.data ?? [];
    const entriesData = hiddenEntries.data ?? [];

    const flagsHasMore = flagsData.length > QUEUE_PAGE_SIZE;
    const reportsHasMore = reportsData.length > QUEUE_PAGE_SIZE;
    const claimsHasMore = claimsData.length > QUEUE_PAGE_SIZE;
    const commentsHasMore = commentsData.length > QUEUE_PAGE_SIZE;
    const entriesHasMore = entriesData.length > QUEUE_PAGE_SIZE;

    const flagsPage = flagsHasMore ? flagsData.slice(0, QUEUE_PAGE_SIZE) : flagsData;
    const reportsPage = reportsHasMore ? reportsData.slice(0, QUEUE_PAGE_SIZE) : reportsData;
    const claimsPage = claimsHasMore ? claimsData.slice(0, QUEUE_PAGE_SIZE) : claimsData;
    const commentsPage = commentsHasMore ? commentsData.slice(0, QUEUE_PAGE_SIZE) : commentsData;
    const entriesPage = entriesHasMore ? entriesData.slice(0, QUEUE_PAGE_SIZE) : entriesData;

    const raters = await countRaters(claimsPage);
    const { erasures, hasMore: erasuresHasMore } =
      role === 'admin' ? await loadErasures(0) : { erasures: [], hasMore: false };

    // A failure here fails the page, like every query above it. Tempting to let it through so
    // that a moderator keeps the flag queue — but the empty state for this list reads "Nobody
    // is banned", and a query that could not run must not be rendered as an answer. In
    // practice the failure is the database being unreachable, in which case nothing above
    // succeeded either.
    const banned = await loadBannedAccounts();
    if (!banned.ok) return { ok: false, message: banned.message };

    const value: QueuePage = {
      flags: await withSubjects(flagsPage),
      flagsHasMore,
      hiddenReports: reportsPage.map(toReport),
      hiddenReportsHasMore: reportsHasMore,
      hiddenClaims: claimsPage.map((row) => toClaim(row, raters)),
      hiddenClaimsHasMore: claimsHasMore,
      hiddenComments: commentsPage.map(toComment),
      hiddenCommentsHasMore: commentsHasMore,
      hiddenEntries: entriesPage.map(toEntry),
      hiddenEntriesHasMore: entriesHasMore,
      bannedAccounts: banned.value,
      erasures,
      erasuresHasMore,
    };

    return { ok: true, value };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/**
 * Next page of open flags, starting at `offset`.
 *
 * Called by the "load more" button in the flags section after the first page is already
 * shown. Does not touch hidden items or erasures.
 */
export async function loadMoreFlags(
  offset: number,
): Promise<Result<{ flags: readonly QueueFlag[]; flagsHasMore: boolean }>> {
  if (import.meta.env.DEV && usingFixtures())
    return { ok: true, value: { flags: [], flagsHasMore: false } };

  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('flags')
      .select(
        `id,subject_type,subject_id,reason,detail,created_at,flagger:profiles!flags_flagger_id_fkey(${AUTHOR_COLUMNS})`,
      )
      .eq('status', 'open')
      .order('created_at', { ascending: true })
      .range(offset, offset + QUEUE_PAGE_SIZE);

    if (error) return { ok: false, message: describe(error) };

    const flagsData = data ?? [];
    const flagsHasMore = flagsData.length > QUEUE_PAGE_SIZE;
    return {
      ok: true,
      value: {
        flags: await withSubjects(flagsHasMore ? flagsData.slice(0, QUEUE_PAGE_SIZE) : flagsData),
        flagsHasMore,
      },
    };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/**
 * Next page of hidden content across all four content types, starting at `offset`.
 *
 * All four types advance together with one shared offset. In practice most sites will
 * overflow only one type at a time, so the other three queries return empty quickly.
 */
export async function loadMoreHidden(offset: number): Promise<
  Result<{
    hiddenReports: readonly QueueReport[];
    hiddenReportsHasMore: boolean;
    hiddenClaims: readonly QueueClaim[];
    hiddenClaimsHasMore: boolean;
    hiddenComments: readonly QueueComment[];
    hiddenCommentsHasMore: boolean;
    hiddenEntries: readonly QueueEntry[];
    hiddenEntriesHasMore: boolean;
  }>
> {
  if (import.meta.env.DEV && usingFixtures())
    return {
      ok: true,
      value: {
        hiddenReports: [],
        hiddenReportsHasMore: false,
        hiddenClaims: [],
        hiddenClaimsHasMore: false,
        hiddenComments: [],
        hiddenCommentsHasMore: false,
        hiddenEntries: [],
        hiddenEntriesHasMore: false,
      },
    };

  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const [reportsRes, claimsRes, commentsRes, entriesRes] = await Promise.all([
      supabase
        .from('reports')
        .select(REPORT_COLUMNS)
        .eq('status', 'hidden')
        .is('deleted_at', null)
        .order('created_at', { ascending: false })
        .range(offset, offset + QUEUE_PAGE_SIZE),
      supabase
        .from('claims')
        .select(CLAIM_COLUMNS)
        .eq('status', 'hidden')
        .order('created_at', { ascending: false })
        .range(offset, offset + QUEUE_PAGE_SIZE),
      supabase
        .from('comments')
        .select(COMMENT_COLUMNS)
        .eq('status', 'hidden')
        .order('created_at', { ascending: false })
        .range(offset, offset + QUEUE_PAGE_SIZE),
      supabase
        .from('network_entries')
        .select(NETWORK_COLUMNS)
        .eq('status', 'hidden')
        .is('deleted_at', null)
        .order('created_at', { ascending: false })
        .range(offset, offset + QUEUE_PAGE_SIZE),
    ]);

    const failed = [reportsRes, claimsRes, commentsRes, entriesRes].find((r) => r.error);
    if (failed?.error) return { ok: false, message: describe(failed.error) };

    const reportsData = reportsRes.data ?? [];
    const claimsData = claimsRes.data ?? [];
    const commentsData = commentsRes.data ?? [];
    const entriesData = entriesRes.data ?? [];

    const reportsHasMore = reportsData.length > QUEUE_PAGE_SIZE;
    const claimsHasMore = claimsData.length > QUEUE_PAGE_SIZE;
    const commentsHasMore = commentsData.length > QUEUE_PAGE_SIZE;
    const entriesHasMore = entriesData.length > QUEUE_PAGE_SIZE;

    const claimsPage = claimsHasMore ? claimsData.slice(0, QUEUE_PAGE_SIZE) : claimsData;
    const raters = await countRaters(claimsPage);

    return {
      ok: true,
      value: {
        hiddenReports: (reportsHasMore ? reportsData.slice(0, QUEUE_PAGE_SIZE) : reportsData).map(
          toReport,
        ),
        hiddenReportsHasMore: reportsHasMore,
        hiddenClaims: claimsPage.map((row) => toClaim(row, raters)),
        hiddenClaimsHasMore: claimsHasMore,
        hiddenComments: (commentsHasMore ? commentsData.slice(0, QUEUE_PAGE_SIZE) : commentsData).map(
          toComment,
        ),
        hiddenCommentsHasMore: commentsHasMore,
        hiddenEntries: (entriesHasMore ? entriesData.slice(0, QUEUE_PAGE_SIZE) : entriesData).map(
          toEntry,
        ),
        hiddenEntriesHasMore: entriesHasMore,
      },
    };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/**
 * Next page of pending erasure requests, starting at `offset`. Admins only — the RLS
 * policy on deletion_requests returns nothing to a moderator, so the gate is the same one.
 */
export async function loadMoreErasures(
  offset: number,
): Promise<Result<{ erasures: readonly QueueErasure[]; erasuresHasMore: boolean }>> {
  if (import.meta.env.DEV && usingFixtures())
    return { ok: true, value: { erasures: [], erasuresHasMore: false } };

  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { erasures, hasMore } = await loadErasures(offset);
    return { ok: true, value: { erasures, erasuresHasMore: hasMore } };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/** How many people have answered each of these claims, from the aggregate view. On a hidden
 *  claim it is the size of what unhiding puts back: a claim twelve people have answered is a
 *  different decision from one nobody read. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function countRaters(rows: any[]): Promise<Map<string, number>> {
  const counts = new Map<string, number>();

  const supabase = getSupabase();
  if (!supabase || !rows.length) return counts;

  const { data } = await supabase
    .from('claim_ratings')
    .select('claim_id,total_raters')
    .in(
      'claim_id',
      rows.map((row) => row.id),
    );

  for (const row of data ?? []) {
    counts.set(row.claim_id as string, Number(row.total_raters ?? 0));
  }

  return counts;
}

/**
 * Attach the flagged content to each flag.
 *
 * A flag names a row by kind and id, which no join can follow — the subject is
 * polymorphic. So this is three queries by id, and it is worth them: a queue that showed
 * "comment flagged as abusive" without the comment would send a volunteer to another page
 * to find out, and the decision would get made on the flagger's summary instead of on the
 * thing itself.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function withSubjects(rows: any[]): Promise<QueueFlag[]> {
  const supabase = getSupabase();
  if (!supabase) return [];

  const idsOf = (kind: FlagSubject) =>
    rows.filter((row) => row.subject_type === kind).map((row) => row.subject_id);

  const [reports, claims, comments] = await Promise.all([
    // The whole report, not a heading and an aim. This is the one subject kind whose
    // interesting part is buried — a flag saying "the verification is not verification" is
    // undecidable from a title — and it is why REPORT_COLUMNS still exists now that the
    // approval queue does not.
    idsOf('report').length
      ? supabase.from('reports').select(REPORT_COLUMNS).in('id', idsOf('report'))
      : Promise.resolve({ data: [], error: null }),
    idsOf('claim').length
      ? supabase
          .from('claims')
          .select(
            `id,statement,rationale,status,author:profiles!claims_author_id_fkey(${AUTHOR_COLUMNS})`,
          )
          .in('id', idsOf('claim'))
      : Promise.resolve({ data: [], error: null }),
    idsOf('comment').length
      ? supabase.from('comments').select(COMMENT_COLUMNS).in('id', idsOf('comment'))
      : Promise.resolve({ data: [], error: null }),
  ]);

  /* eslint-disable @typescript-eslint/no-explicit-any */
  // supabase-js types a `select()` by parsing the column string at the type level, which it
  // can only do for a literal. Ours are assembled from constants so that the author embed is
  // written once, so the rows arrive untyped and are shaped by hand below.
  const index = new Map<string, any>();
  for (const row of (reports.data ?? []) as any[]) index.set(`report:${row.id}`, row);
  for (const row of (claims.data ?? []) as any[]) index.set(`claim:${row.id}`, row);
  for (const row of (comments.data ?? []) as any[]) index.set(`comment:${row.id}`, row);
  /* eslint-enable @typescript-eslint/no-explicit-any */

  return rows.map((row) => {
    const found = index.get(`${row.subject_type}:${row.subject_id}`);

    return {
      id: row.id,
      subjectType: row.subject_type,
      subjectId: row.subject_id,
      reason: row.reason,
      detail: row.detail,
      createdAt: row.created_at,
      flagger: toAuthor(row.flagger),
      subject: found
        ? {
            kind: row.subject_type,
            heading:
              row.subject_type === 'report'
                ? found.title
                : row.subject_type === 'claim'
                  ? found.statement
                  : 'Comment',
            body:
              row.subject_type === 'report'
                ? found.aim
                : row.subject_type === 'claim'
                  ? (found.rationale ?? '')
                  : found.body,
            status: found.status,
            author: toAuthor(found.author),
          }
        : null,
      report: found && row.subject_type === 'report' ? toReport(found) : null,
    };
  });
}

/** Standing erasure requests, with the size of what erasing will detach. Admins only: the
 *  policy on public.deletion_requests returns nothing to a moderator, so this is not a
 *  second gate but the same one, stated where a reader of this file will see it. */
async function loadErasures(
  offset: number,
): Promise<{ erasures: QueueErasure[]; hasMore: boolean }> {
  const supabase = getSupabase();
  if (!supabase) return { erasures: [], hasMore: false };

  const { data, error } = await supabase
    .from('deletion_requests')
    .select('id,user_id,note,requested_at')
    .eq('status', 'pending')
    .order('requested_at', { ascending: true })
    .range(offset, offset + QUEUE_PAGE_SIZE);

  if (error || !data?.length) return { erasures: [], hasMore: false };

  const hasMore = data.length > QUEUE_PAGE_SIZE;
  const page = hasMore ? data.slice(0, QUEUE_PAGE_SIZE) : data;

  // deletion_requests references auth.users, not profiles, so there is no embed to follow.
  const ids = page.map((row) => row.user_id as string);
  const { data: people } = await supabase.from('profiles').select(AUTHOR_COLUMNS).in('id', ids);

  const byId = new Map<string, QueueAuthor>();
  for (const person of people ?? []) {
    const author = toAuthor(person as unknown as RawAuthor);
    if (author) byId.set(author.id, author);
  }

  const erasures = await Promise.all(
    page.map(async (row) => {
      const userId = row.user_id as string;

      const [reports, comments] = await Promise.all([
        supabase
          .from('reports')
          .select('id', { count: 'exact', head: true })
          .eq('author_id', userId),
        supabase
          .from('comments')
          .select('id', { count: 'exact', head: true })
          .eq('author_id', userId),
      ]);

      return {
        id: row.id as string,
        requestedAt: row.requested_at as string,
        note: (row.note as string | null) ?? null,
        member: byId.get(userId) ?? null,
        reportCount: reports.count ?? 0,
        commentCount: comments.count ?? 0,
      };
    }),
  );

  return { erasures, hasMore };
}

// ── Accounts ──────────────────────────────────────────────────────────────────────────
//
// The only part of this screen that is not driven by a queue. A flag arrives; a spammer does
// not. Somebody posting eleven advertisements in an afternoon may never be flagged at all —
// and a network entry cannot be flagged, because public.flags.subject_type is
// public.content_kind, which has no `entry` — so a ban reachable only from a flag is a ban
// unreachable in the case it exists for.
//
// Two ways in, and they are the two ways a moderator actually arrives: by name, having read
// the name on the thing that made them open this screen, and from the list of everybody
// currently banned, which is what makes a ban reversible by somebody who did not impose it.

const ACCOUNT_COLUMNS =
  'id,display_name,is_pseudonym,institution_name,institution_country,role,is_banned,created_at';

interface RawAccount extends RawAuthor {
  role: string;
  created_at: string;
}

function toAccount(row: RawAccount, bannedAt: string | null): QueueAccount {
  return {
    id: row.id,
    displayName: row.display_name,
    isPseudonym: row.is_pseudonym,
    institution:
      row.institution_name && row.institution_country
        ? { name: row.institution_name, country: row.institution_country }
        : null,
    role: row.role === 'admin' || row.role === 'moderator' ? row.role : 'member',
    isBanned: row.is_banned,
    joinedAt: row.created_at,
    bannedAt,
  };
}

/**
 * When each of these accounts was last banned, out of the audit log.
 *
 * One query for the whole page rather than one per row, and a miss is not a failure: an
 * account banned before 20260819120000 has an audit row like any other, but one banned by
 * direct database access has none, and the row then reads "banned" with no date. That is the
 * honest rendering — the date is a fact from the log, and where the log is silent the screen
 * should be too.
 */
async function banDates(ids: readonly string[]): Promise<Map<string, string>> {
  const dates = new Map<string, string>();

  const supabase = getSupabase();
  if (!supabase || !ids.length) return dates;

  const { data } = await supabase
    .from('moderation_actions')
    .select('target_id,created_at')
    .eq('action', 'ban')
    .in('target_id', ids)
    .order('created_at', { ascending: false });

  // Newest first, so the first row for an account is the ban that still applies. An earlier
  // one is a ban that was lifted and is history.
  for (const row of data ?? []) {
    const id = row.target_id as string;
    if (!dates.has(id)) dates.set(id, row.created_at as string);
  }

  return dates;
}

/** Everybody currently banned, alphabetically. Served by profiles_banned_idx, whose
 *  predicate is this query. */
export async function loadBannedAccounts(): Promise<Result<readonly QueueAccount[]>> {
  if (import.meta.env.DEV && usingFixtures())
    return { ok: true, value: FIXTURES.bannedAccounts };

  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('profiles')
      .select(ACCOUNT_COLUMNS)
      .eq('is_banned', true)
      .order('display_name', { ascending: true });

    if (error) return { ok: false, message: describe(error) };

    const rows = (data ?? []) as unknown as RawAccount[];
    const dates = await banDates(rows.map((row) => row.id));

    return { ok: true, value: rows.map((row) => toAccount(row, dates.get(row.id) ?? null)) };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/**
 * Accounts whose display name contains `term`, capped.
 *
 * Substring rather than prefix, because the name a moderator has in front of them is whatever
 * appeared under a post, and a pseudonym is as likely to be remembered from the middle. It is
 * a sequential scan and deliberately unindexed; see the migration for why a trigram index
 * would be a cost paid on every profile write for a query run twice a month.
 *
 * The term is passed through as typed. A `%` in it widens the match rather than matching a
 * literal per cent sign — which is a search that returns too much on a screen two people use,
 * not a hazard, and escaping it would mean explaining the escape.
 */
export async function searchAccounts(term: string): Promise<Result<readonly QueueAccount[]>> {
  const wanted = term.trim();

  if (wanted.length < 2) {
    return {
      ok: false,
      message: 'Type at least two characters of the display name.',
    };
  }

  if (import.meta.env.DEV && usingFixtures()) {
    const lower = wanted.toLowerCase();
    return {
      ok: true,
      value: FIXTURES_ACCOUNTS.filter((account) =>
        account.displayName.toLowerCase().includes(lower),
      ),
    };
  }

  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('profiles')
      .select(ACCOUNT_COLUMNS)
      .ilike('display_name', `%${wanted}%`)
      .order('display_name', { ascending: true })
      .limit(QUEUE_PAGE_SIZE);

    if (error) return { ok: false, message: describe(error) };

    const rows = (data ?? []) as unknown as RawAccount[];
    const banned = rows.filter((row) => row.is_banned).map((row) => row.id);
    const dates = await banDates(banned);

    return { ok: true, value: rows.map((row) => toAccount(row, dates.get(row.id) ?? null)) };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Acting ────────────────────────────────────────────────────────────────────────────

export type Target = 'report' | 'claim' | 'comment' | 'flag' | 'entry' | 'account';

/**
 * What is left to do.
 *
 * `publish`, `request_changes` and `promote` are gone from this list and refused by
 * public.moderate() by name. They were the approval gate, and there is nothing to approve:
 * posts are live when they are written. Their enum labels survive in the database because
 * the audit log is full of them.
 */
export type Action =
  | 'hide'
  | 'unhide'
  | 'resolve_flag'
  | 'dismiss_flag'
  | 'ban'
  | 'unban'
  | 'erase_account';

/**
 * Everything except carrying out an erasure request needs an explanation, and the person it
 * is about will read it. Mirrored from the CHECK on public.moderation_actions and the
 * refusal inside public.moderate(), so the screen can say so before the round trip rather
 * than after it.
 *
 * The exception is not a softening: an erasure is a standing request being executed, not a
 * judgement, and a mandatory field there produces "as requested" a hundred times, which
 * teaches people that the box is a formality. It is the box that everything else depends on.
 */
export const NEEDS_REASON: readonly Action[] = [
  'hide',
  'unhide',
  'resolve_flag',
  'dismiss_flag',
  'ban',
  'unban',
];

/**
 * The single call. Everything the screen does goes through here, because everything the
 * database will accept goes through public.moderate().
 *
 * For an erasure, `targetId` is the id of the *request* rather than of the person. That is
 * not an abstraction leak to tidy away: it is what makes an admin unable to erase somebody
 * who has not asked, and the screen should be written the way the database behaves.
 */
export async function act(
  targetType: Target,
  targetId: string,
  action: Action,
  reason: string,
): Promise<Result<null>> {
  if (import.meta.env.DEV && usingFixtures()) return { ok: true, value: null };

  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { error } = await supabase.rpc('moderate', {
      p_target_type: targetType,
      p_target_id: targetId,
      p_action: action,
      p_reason: reason.trim() || null,
    });

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: null };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Turning a failure into a sentence ─────────────────────────────────────────────────

/**
 * public.moderate() raises finished sentences on purpose — "This is your own post. Another
 * moderator has to decide it" is written for the person who will read it, not for a log. So
 * prose is passed through and only the codes Postgres raises on its own behalf are
 * translated.
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

  if (looksLikeProse(message)) return message;

  switch (code) {
    case '42501':
      return 'That is not an action this account may take.';

    case '23503':
      return 'That row is no longer there. Reload the queue.';

    case '23514':
      return 'That action does not apply in this state. Reload the queue.';

    case 'PGRST202':
      return 'Moderation is not available on this deployment: the database has no moderate() function.';

    case 'PGRST301':
      return 'This session has ended. Sign in again.';
  }

  if (
    lower.includes('failed to fetch') ||
    lower.includes('fetch failed') ||
    lower.includes('networkerror') ||
    lower.includes('load failed')
  ) {
    return UNAVAILABLE;
  }

  return 'That did not go through, and nothing was changed.';
}

function looksLikeProse(message: string): boolean {
  return /^[A-Z].*[.!?]$/.test(message.trim()) && !message.includes('_');
}

// ── Fixtures, for development only ────────────────────────────────────────────────────
//
// `?fixtures` fills the queues with invented rows and skips the role check, so the screen
// can be worked on — and screenshotted — without a moderator account and without seeding the
// production database with rubbish. Every entry point is guarded by `import.meta.env.DEV`,
// which Vite replaces with the literal `false` in a production build, so the branches and
// everything they reference are removed by dead-code elimination. Nothing below reaches the
// deployed site; grep the built bundle for "Kolmogorov" if you want to check, and it is
// worth checking rather than believing.
//
// This is not a way around the gate. The gate that matters is row level security, which no
// browser can talk its way past: with fixtures on, the page renders invented rows and every
// action is a no-op.

function usingFixtures(): boolean {
  return (
    typeof window !== 'undefined' &&
    new URLSearchParams(window.location.search).has('fixtures')
  );
}

export function fixturesActive(): boolean {
  return import.meta.env.DEV && usingFixtures();
}

const HANNA: QueueAuthor = {
  id: '00000000-0000-4000-8000-000000000001',
  displayName: 'Hanna Lindqvist',
  isPseudonym: false,
  institution: { name: 'Uppsala universitet', country: 'SE' },
  isBanned: false,
};

const CATEGORY_OF_ONE: QueueAuthor = {
  id: '00000000-0000-4000-8000-000000000002',
  displayName: 'category_of_one',
  isPseudonym: true,
  institution: null,
  isBanned: false,
};

const TOMAS: QueueAuthor = {
  id: '00000000-0000-4000-8000-000000000003',
  displayName: 'Tomáš Brázda',
  isPseudonym: false,
  institution: { name: 'Univerzita Karlova', country: 'CZ' },
  isBanned: false,
};

const NOOR: QueueAuthor = {
  id: '00000000-0000-4000-8000-000000000004',
  displayName: 'Noor Haddad',
  isPseudonym: false,
  institution: { name: 'Weizmann Institute of Science', country: 'IL' },
  isBanned: false,
};

/** The flagged report, in full. The flag queue carries the whole submission for exactly this
 *  reason: the flag below says the verification section is not verification, and there is no
 *  way to agree or disagree with that from a title. */
const FLAGGED_REPORT: QueueReport = {
  id: '00000000-0000-4000-9000-000000000001',
  status: 'published',
  title: 'Check a lemma on sumsets with a proof assistant',
  area: 'research',
  taskType: 'proof_checking',
  aim: 'I had a lemma about doubling constants that I believed but could not prove cleanly, and wanted to know whether it was true before spending a week on it.',
  method:
    '1. Stated the lemma in Lean 4 with Mathlib.\n2. Asked the model for a proof sketch, twice, from a clean context each time.\n3. Both sketches used induction on the size of the sumset.\n4. Translated the first into tactics; three of five goals closed.\n5. Did the remaining two by hand, which took an afternoon.',
  outcome: 'partial',
  outcomeNotes:
    'The induction was the right idea and the base case was for the wrong statement — it had silently strengthened the hypothesis to a set of positive density. Two goals closed directly. The other three needed the hypothesis I actually had.',
  verification:
    'Lean accepted the final proof, so the formal statement is verified. I checked separately that the formal statement says what I meant, by rederiving the informal version by hand from the Lean one.',
  transcriptExcerpt:
    '> Prove: if |A + A| ≤ K|A| then A is covered by K^C translates of a set of size ≤ |A|.\n\nBy induction on |A|. Assume A has positive density in its ambient group…\n\n> A has no ambient group here. A is a finite subset of the integers.\n\nYou are right. Let me restate without that assumption…',
  transcriptUrl: null,
  caveats:
    'I would state all the hypotheses in full before asking. Most of the wasted time came from it filling in an assumption I had left implicit, and then being confident about it.',
  learnedNotes: null,
  thirdPartyMaterialConfirmed: true,
  timeSpentMinutes: 260,
  wasPublished: 'no',
  wasDisclosed: null,
  authorConfidence: 8,
  createdAt: '2026-08-11T09:14:00Z',
  updatedAt: '2026-08-11T09:14:00Z',
  author: HANNA,
  tools: [
    { name: 'Lean', version: '4.9.0', usedOn: '2026-08-09' },
    { name: 'Claude', version: 'Opus 4.1', usedOn: '2026-08-09' },
  ],
  tags: ['math.NT', 'math.CO'],
};

/** The account the accounts section is for: one that posted the same advertisement eleven
 *  times and was never flagged, because nobody flags an advertisement, they just leave. */
const PROOFPILOT: QueueAccount = {
  id: '00000000-0000-4000-8000-000000000007',
  displayName: 'ProofPilot Team',
  isPseudonym: false,
  institution: null,
  role: 'member',
  isBanned: true,
  joinedAt: '2026-08-15T09:00:00Z',
  bannedAt: '2026-08-15T18:20:00Z',
};

/** What a search runs against in development. A moderator and an admin are in it on purpose:
 *  the screen has to show that those accounts are not bannable from here rather than offer a
 *  button the database will refuse. */
const FIXTURES_ACCOUNTS: readonly QueueAccount[] = [
  PROOFPILOT,
  {
    id: HANNA.id,
    displayName: HANNA.displayName,
    isPseudonym: HANNA.isPseudonym,
    institution: HANNA.institution,
    role: 'member',
    isBanned: false,
    joinedAt: '2026-07-02T11:30:00Z',
    bannedAt: null,
  },
  {
    id: CATEGORY_OF_ONE.id,
    displayName: CATEGORY_OF_ONE.displayName,
    isPseudonym: CATEGORY_OF_ONE.isPseudonym,
    institution: CATEGORY_OF_ONE.institution,
    role: 'member',
    isBanned: false,
    joinedAt: '2026-07-19T08:05:00Z',
    bannedAt: null,
  },
  {
    id: TOMAS.id,
    displayName: TOMAS.displayName,
    isPseudonym: TOMAS.isPseudonym,
    institution: TOMAS.institution,
    role: 'moderator',
    isBanned: false,
    joinedAt: '2026-06-11T14:45:00Z',
    bannedAt: null,
  },
];

const FIXTURES: QueuePage = {
  flags: [
    {
      id: '00000000-0000-4000-b000-000000000001',
      subjectType: 'comment',
      subjectId: '00000000-0000-4000-c000-000000000001',
      reason: 'third_party_material',
      detail:
        'This quotes a referee report I wrote. It was not published and I did not agree to it being posted.',
      createdAt: '2026-08-15T06:12:00Z',
      flagger: NOOR,
      subject: {
        kind: 'comment',
        heading: 'Comment',
        body: 'The report on that paper said the argument in §3 “collapses under any uniformity assumption”, which is exactly what happened here.',
        status: 'published',
        author: CATEGORY_OF_ONE,
      },
      report: null,
    },
    {
      id: '00000000-0000-4000-b000-000000000002',
      subjectType: 'report',
      subjectId: FLAGGED_REPORT.id,
      reason: 'inaccurate',
      detail:
        'The verification section says Lean accepted the proof. That is a check of the formalisation, not of the informal lemma, and the report reads as though it settles the lemma.',
      createdAt: '2026-08-15T10:48:00Z',
      flagger: TOMAS,
      subject: {
        kind: 'report',
        heading: FLAGGED_REPORT.title,
        body: FLAGGED_REPORT.aim,
        status: 'published',
        author: HANNA,
      },
      report: FLAGGED_REPORT,
    },
  ],

  flagsHasMore: false,

  hiddenReports: [
    {
      id: '00000000-0000-4000-9000-000000000002',
      status: 'hidden',
      title: 'Ask for a literature search on a Diophantine equation',
      area: 'research',
      taskType: 'literature_search',
      aim: 'Find out whether the specific family of equations I had reduced my problem to was already in the literature.',
      method:
        '1. Described the family precisely.\n2. Asked for references, with the instruction that it should say so if it did not know.\n3. Received six references.\n4. Looked up all six.',
      outcome: 'failed',
      outcomeNotes:
        'Two of the six do not exist. One is a real paper by a real author with an invented title. The remaining three exist and are about something else.',
      verification:
        'Checked every reference against MathSciNet and arXiv by hand. Emailed one author to ask whether the attributed result was theirs; it was not.',
      transcriptExcerpt:
        'The referee report on the earlier version said: “the argument of Lemma 4 is circular and the author appears not to have noticed”…',
      transcriptUrl: null,
      caveats:
        'A failure worth recording rather than a complaint. I would not use a model for this again without a retrieval tool attached.',
      learnedNotes: null,
      thirdPartyMaterialConfirmed: true,
      timeSpentMinutes: 95,
      wasPublished: null,
      wasDisclosed: null,
      authorConfidence: 9,
      createdAt: '2026-08-12T16:02:00Z',
      updatedAt: '2026-08-16T08:30:00Z',
      author: CATEGORY_OF_ONE,
      tools: [{ name: 'GPT-5', version: '2026-06', usedOn: '2026-08-12' }],
      tags: ['math.NT'],
    },
  ],

  hiddenReportsHasMore: false,

  hiddenClaims: [
    {
      id: '00000000-0000-4000-a000-000000000001',
      status: 'hidden',
      statement: 'Anyone who uses a model for proof drafting should say so or leave the field.',
      rationale: null,
      area: 'writing',
      createdAt: '2026-08-13T19:30:00Z',
      author: CATEGORY_OF_ONE,
      ratingCount: 4,
    },
  ],

  hiddenClaimsHasMore: false,

  hiddenComments: [
    {
      id: '00000000-0000-4000-c000-000000000002',
      body: 'Anyone who trusts a chatbot with a proof is not a serious mathematician, and the people posting here know it.',
      createdAt: '2026-08-10T21:07:00Z',
      status: 'hidden',
      // Hiding keeps the name. Only deleting strips it, and a deleted comment keeps no text
      // to show here either — which is why a moderator answering a flag about one is told to
      // hide rather than wait.
      author: {
        id: '00000000-0000-4000-8000-000000000006',
        displayName: 'Wolfgang Amsel',
        isPseudonym: false,
        institution: { name: 'Universität Bonn', country: 'DE' },
        isBanned: false,
      },
      parentType: 'report',
      parentId: FLAGGED_REPORT.id,
    },
  ],

  hiddenCommentsHasMore: false,

  hiddenEntries: [
    {
      id: '00000000-0000-4000-e000-000000000001',
      status: 'hidden',
      title: 'ProofPilot Pro — AI for working mathematicians',
      url: 'https://example.com/proofpilot',
      category: 'tool',
      description: 'A commercial assistant for proof drafting, with a free trial.',
      relevance: 'Every serious mathematician will need this. Sign up before the price rises.',
      createdAt: '2026-08-15T14:32:00Z',
      updatedAt: '2026-08-15T14:32:00Z',
      // The account in the banned list below, which is the coherent version of this fixture:
      // the advertisement and the ban are the same story. It also exercises the row that says
      // "account banned" and offers no ban button, which is otherwise only visible by banning
      // somebody.
      author: PROOFPILOT,
    },
  ],

  hiddenEntriesHasMore: false,

  bannedAccounts: [PROOFPILOT],

  erasures: [
    {
      id: '00000000-0000-4000-d000-000000000001',
      requestedAt: '2026-08-14T13:26:00Z',
      note: 'Please detach my reports rather than removing them — I would rather they stayed in the corpus without my name.',
      member: {
        id: '00000000-0000-4000-8000-000000000005',
        displayName: 'Kolmogorov Complexity Enjoyer',
        isPseudonym: true,
        institution: null,
        isBanned: false,
      },
      reportCount: 3,
      commentCount: 11,
    },
  ],
  erasuresHasMore: false,
};
