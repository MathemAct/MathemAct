/**
 * Everything the site knows about reports: reading the corpus at build time, and the two
 * things a browser does to it.
 *
 * The swap point
 * --------------
 * `readCorpus()` below is the only function that knows where the corpus comes from. **It is
 * now the committed export in data/ and nothing else** — the PostgREST fallback that stood
 * here until the nightly job existed has gone, and its absence is the feature. While it was
 * there, a build with credentials silently produced a different site from a build without
 * them, and a paused database would have gone unnoticed until somebody wondered why the
 * corpus had stopped growing. Now a build reads files or reads nothing.
 *
 * Reads happen at build time, not in the browser. That is the read/write split in CLAUDE.md
 * doing its job: a traffic spike never touches the egress quota, and the site keeps serving
 * if the database is paused — which on the free tier it will be, after about a week of
 * quiet. It also means every report is a real page with a real URL, which matters for a
 * corpus meant to be cited.
 *
 * Writes stay in the browser, because they are the only thing that genuinely cannot be
 * static: submitting a report, and reporting whether one still works. The one read a
 * browser makes is the freshness overlay in src/lib/fresh.ts, which never renders a page,
 * only adds to one.
 */
import { getSupabase } from './supabase';
import { RATING_SCALES, scaleApplies } from './report-schema';
import type {
  Area,
  CareerStage,
  Generalises,
  RatingKey,
  ReferenceKind,
  TaskType,
} from './report-schema';
import type { Outcome, TombstoneStatus, Verdict } from './status';

// ── What a page gets ──────────────────────────────────────────────────────────────────

export interface CorpusAuthor {
  readonly id: string;
  readonly displayName: string;
  readonly isPseudonym: boolean;
  readonly institution: {
    readonly name: string;
    readonly country: string;
    readonly verifiedAt: string;
  } | null;
}

export interface CorpusTool {
  readonly name: string;
  readonly version: string;
  readonly usedOn: string;
  /** What this one did. Null on every row written before schema version 2, and on any row
   *  whose author did not say — which is most of them, and fine. */
  readonly role: string | null;
}

/** One supporting link. Stored as jsonb on the report rather than in a child table: unlike a
 *  tool, a reference has no date to go stale and nothing joins to it. */
export interface CorpusReference {
  readonly kind: ReferenceKind;
  readonly url: string;
  readonly label: string | null;
}

/**
 * The five scales plus the confidence question, as they come out of the corpus.
 *
 * Null means unanswered, and for the two conditional ones it means the question was never
 * asked. Never 0 for either — a 0 would put "no help at all" into an analysis for a report
 * whose author was never shown the row.
 */
export type Ratings = Readonly<Record<RatingKey, number | null>>;

export interface CorpusTag {
  readonly code: string;
  readonly label: string;
}

/** The derived tombstone, computed in SQL by public.report_staleness. Never recomputed
 *  here: the same answer has to appear in a listing, on a page, and in the export. */
export interface Staleness {
  readonly latestToolUse: string | null;
  /** Which of the four answers the most recent confirmation gave. Which two were on offer
   *  was decided by `outcome`; `VERDICT[v].holds` is the way to read it without caring. */
  readonly latestVerdict: Verdict | null;
  readonly latestConfirmationAt: string | null;
  readonly confirmationCount: number;
  readonly tombstoneStatus: TombstoneStatus;
  readonly isVerified: boolean;
}

export interface Report {
  readonly id: string;
  /** Which version of the reporting standard this row answers. 1 for anything written
   *  before 2026-08-20; nothing in the corpus is version 1 today, because the three example
   *  reports that were went with the migration that introduced version 2. */
  readonly schemaVersion: number;
  readonly title: string;
  readonly area: Area;
  /** Set only when `area` is `other`, and always set when it is. */
  readonly areaOther: string | null;
  readonly taskType: TaskType;
  /** Anything else the tool was asked to do in the same session. Never contains
   *  `taskType`, never contains a duplicate: the database sees to both. */
  readonly taskSecondary: readonly TaskType[];
  readonly careerStage: CareerStage | null;
  readonly aim: string;
  readonly method: string;
  readonly outcome: Outcome;
  readonly outcomeNotes: string;
  readonly verification: string;
  readonly prompts: string | null;
  readonly transcriptExcerpt: string | null;
  readonly transcriptUrl: string | null;
  readonly caveats: string | null;
  readonly references: readonly CorpusReference[];
  readonly timeSpentMinutes: number | null;
  readonly wasPublished: string | null;
  readonly wasDisclosed: boolean | null;
  readonly authorConfidence: number | null;
  readonly ratings: Ratings;
  readonly timeSaved: string | null;
  readonly generalises: Generalises | null;
  /** Absent from an export written before schema version 3, hence optional: a missing key
   *  and a null are both "never answered". */
  readonly learnedSomething?: boolean | null;
  readonly learnedNotes?: string | null;
  readonly createdAt: string;
  /** Null when the account was erased. The contribution stays; the name goes. */
  readonly author: CorpusAuthor | null;
  readonly tools: readonly CorpusTool[];
  readonly tags: readonly CorpusTag[];
  readonly staleness: Staleness;
}

// ── The swap point ────────────────────────────────────────────────────────────────────

/**
 * A committed export, if there is one.
 *
 * `import.meta.glob` rather than `node:fs` on purpose: it resolves at build time, returns
 * an empty object when the file is absent instead of throwing, and involves no Node
 * builtins — so this module stays importable from a browser script, which is what lets the
 * write functions at the bottom live in the same file as the read functions.
 */
const EXPORTED = import.meta.glob<{ default: Report[] }>('/data/reports.json', {
  eager: true,
});

const COMMENTS = import.meta.glob<{
  default: readonly { parentType: string; parentId: string }[];
}>('/data/comments.json', { eager: true });

const CITATIONS = import.meta.glob<{
  default: readonly {
    sourceType: string;
    sourceId: string;
    targetType: string;
    targetId: string;
  }[];
}>('/data/citations.json', { eager: true });

let cached: Report[] | null = null;

async function readCorpus(): Promise<Report[]> {
  if (cached) return cached;

  const exported = Object.values(EXPORTED)[0]?.default;

  if (!exported) {
    // A checkout that has never run scripts/export.mjs. The site builds, every page renders
    // its empty state, and nothing pretends otherwise. Said out loud because the symptom —
    // a complete site with no corpus in it — otherwise reads as a bug in the listing.
    console.warn(
      '[reports] data/reports.json is missing, so the corpus is empty. ' +
        'Run scripts/export.mjs, or let .github/workflows/export.yml commit one.',
    );
    cached = [];
    return cached;
  }

  cached = exported;
  return cached;
}

// ── What pages call ───────────────────────────────────────────────────────────────────

/** Every published report, newest first. */
export async function listReports(): Promise<Report[]> {
  return readCorpus();
}

export async function getReport(id: string): Promise<Report | undefined> {
  return (await readCorpus()).find((report) => report.id === id);
}

export async function reportsByAuthor(authorId: string): Promise<Report[]> {
  return (await readCorpus()).filter((report) => report.author?.id === authorId);
}

/* `listAuthors()` used to live here and returned everyone with a published report. It was
 * what getStaticPaths built author pages from, which meant a person whose only contribution
 * was an entry had no page and every link to them was a permanent 404. `listContributors()`
 * in src/lib/authors.ts is the union that replaced it. Deliberately not left behind as an
 * unused export: the next person to need "the list of author pages" would find this one
 * first, and it is the wrong answer to that question. */

/** The distinct tool names in the corpus, for the listing filter. Case-folded so that
 *  "Lean" and "lean" are one filter rather than two. */
export async function listToolNames(): Promise<string[]> {
  const names = new Map<string, string>();

  for (const report of await readCorpus()) {
    for (const tool of report.tools) {
      const key = tool.name.trim().toLowerCase();
      if (key && !names.has(key)) names.set(key, tool.name.trim());
    }
  }

  return [...names.values()].sort((a, b) => a.localeCompare(b, 'en'));
}

export async function listUsedTags(): Promise<CorpusTag[]> {
  const tags = new Map<string, CorpusTag>();

  for (const report of await readCorpus()) {
    for (const tag of report.tags) tags.set(tag.code, tag);
  }

  return [...tags.values()].sort((a, b) => a.code.localeCompare(b.code, 'en'));
}

const ALL_TAGS_DATA = import.meta.glob<{ default: { code: string; label: string }[] }>(
  '/data/tags.json',
  { eager: true },
);

/** All tags in the vocabulary, whether or not any report uses them. Used to provide
 *  client-side label lookups for values that appear only in fresh cards. */
export async function listAllTags(): Promise<CorpusTag[]> {
  const rows = Object.values(ALL_TAGS_DATA)[0]?.default ?? [];
  return rows.map(({ code, label }) => ({ code, label }));
}

/** Comment count + citation count per report id. Confirmations are in staleness already.
 *  Call this at build time and add it to confirmationCount for the full interaction total. */
export function listInteractionCounts(): Map<string, number> {
  const counts = new Map<string, number>();
  const bump = (id: string) => counts.set(id, (counts.get(id) ?? 0) + 1);

  for (const comment of Object.values(COMMENTS)[0]?.default ?? []) {
    if (comment.parentType === 'report') bump(comment.parentId);
  }
  for (const citation of Object.values(CITATIONS)[0]?.default ?? []) {
    if (citation.sourceType === 'report') bump(citation.sourceId);
    if (citation.targetType === 'report') bump(citation.targetId);
  }

  return counts;
}

// ══ Writes ════════════════════════════════════════════════════════════════════════════
// Everything below runs in a browser and always will. Submitting a report and reporting
// whether one still works are the two things that genuinely cannot be static, and they are
// the only reasons a reader's browser ever opens a connection to the database.

export type Result<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly message: string };

const UNAVAILABLE =
  'The database cannot be reached right now. Your draft is saved in this browser — try again in a few minutes and nothing will be lost.';

export interface Tag {
  readonly id: string;
  readonly code: string;
  readonly label: string;
  readonly scheme: string;
}

export interface SubmissionTool {
  name: string;
  version: string;
  usedOn: string;
  /** Optional, and part of the uniqueness key — the same tool can appear twice on one day
   *  in two roles, which is the account the field exists for. */
  role: string;
}

export interface SubmissionReference {
  kind: ReferenceKind;
  url: string;
}

export interface Submission {
  title: string;
  area: Area;
  /** Required when `area` is `other`, refused otherwise. The database enforces both
   *  directions, so an `areaOther` left behind by changing the area back is a rejection
   *  rather than a stray column. */
  areaOther: string;
  taskType: TaskType;
  taskSecondary: readonly TaskType[];
  careerStage: CareerStage | '';
  tools: readonly SubmissionTool[];
  aim: string;
  method: string;
  outcome: Outcome;
  outcomeNotes: string;
  verification: string;
  prompts: string;
  transcriptExcerpt: string;
  transcriptUrl: string;
  caveats: string;
  references: readonly SubmissionReference[];
  thirdPartyMaterialConfirmed: boolean;
  timeSpentMinutes: number | null;
  wasPublished: string | null;
  wasDisclosed: boolean | null;
  authorConfidence: number | null;
  /** Every scale, including the two conditional ones. A conditional scale that does not
   *  apply is null here, whatever a stale radio somewhere in the DOM says — see
   *  `ratingsFor()`, which is the one place that decides. */
  ratings: Ratings;
  timeSaved: string | null;
  generalises: Generalises | '';
  /** Null is "did not answer" and is not false. */
  learnedSomething: boolean | null;
  learnedNotes: string;
  tagCodes: readonly string[];
}

/**
 * The ratings as they should be *stored*, given the answers the rest of the form holds.
 *
 * A conditional scale is hidden when it does not apply, and a hidden radio group keeps
 * whatever was selected before it was hidden — so somebody who picks Research, answers
 * novelty, then changes the area to Teaching would otherwise submit a novelty score against
 * a question that is no longer on their screen. This nulls those, and it is deliberately not
 * the form's job: the form hides a row, and this decides what a hidden row means.
 */
export function ratingsFor(
  answers: Ratings,
  area: string | undefined,
  taskPrimary: string | undefined,
  taskSecondary: readonly string[],
): Ratings {
  const out: Record<RatingKey, number | null> = { ...answers };

  for (const scale of RATING_SCALES) {
    if (!scaleApplies(scale, area, taskPrimary, taskSecondary)) out[scale.key] = null;
  }

  return out;
}

/**
 * The tag vocabulary, read from the database rather than duplicated here. It is seeded by a
 * migration and curated — no browser role can write to it — so the table is the one source
 * of truth, and a TypeScript copy would drift the first time a tag is retired.
 */
export async function loadTags(): Promise<Result<Tag[]>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('tags')
      .select('id, code, label, scheme')
      .eq('is_active', true)
      .order('sort_order', { ascending: true });

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: (data ?? []) as Tag[] };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/**
 * The RPC arguments, once.
 *
 * `submit_report` and `resubmit_report` take the same thirty-three parameters and differ only
 * in the report id and the return type, so the mapping lives here rather than twice.
 * Thirty-three names written twice is thirty-three chances for the edit form to send a field the
 * submission form does not — which is the failure the shared `ReportFields.astro` and this
 * function exist to prevent.
 */
function rpcArguments(submission: Submission): Record<string, unknown> {
  return {
    p_title: submission.title.trim(),
    p_area: submission.area,
    p_area_other: submission.areaOther.trim() || null,
    p_task_type: submission.taskType,
    p_task_secondary: submission.taskSecondary,
    p_career_stage: submission.careerStage || null,
    p_tools: submission.tools.map((tool) => ({
      name: tool.name.trim(),
      version: tool.version.trim(),
      used_on: tool.usedOn,
      role: tool.role.trim() || null,
    })),
    p_aim: submission.aim.trim(),
    p_method: submission.method.trim(),
    p_outcome: submission.outcome,
    p_outcome_notes: submission.outcomeNotes.trim(),
    p_verification: submission.verification.trim(),
    p_prompts: submission.prompts.trim() || null,
    p_third_party_material_confirmed: submission.thirdPartyMaterialConfirmed,
    p_transcript_excerpt: submission.transcriptExcerpt.trim() || null,
    p_transcript_url: submission.transcriptUrl.trim() || null,
    p_caveats: submission.caveats.trim() || null,
    p_references: submission.references.map((reference) => ({
      kind: reference.kind,
      url: reference.url.trim(),
    })),
    p_time_spent_minutes: submission.timeSpentMinutes,
    p_was_published: submission.wasPublished,
    p_was_disclosed: submission.wasDisclosed,
    p_author_confidence: submission.authorConfidence,
    p_rating_helpfulness: submission.ratings.rating_helpfulness,
    p_time_saved: submission.timeSaved,
    p_rating_trust_before_checking: submission.ratings.rating_trust_before_checking,
    p_rating_verification_effort: submission.ratings.rating_verification_effort,
    p_rating_novelty: submission.ratings.rating_novelty,
    p_rating_understanding_gained: submission.ratings.rating_understanding_gained,
    p_generalises: submission.generalises || null,
    p_learned_something: submission.learnedSomething,
    p_learned_notes: submission.learnedNotes.trim() || null,
    p_tag_codes: submission.tagCodes,
  };
}

/**
 * Returns the new report's id.
 *
 * One RPC rather than three inserts, because the at-least-one-tool constraint is deferred
 * and PostgREST gives every request its own transaction. See the migration that creates
 * public.submit_report.
 */
export async function submitReport(submission: Submission): Promise<Result<string>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase.rpc('submit_report', rpcArguments(submission));

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: String(data) };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Your own submissions ──────────────────────────────────────────────────────────────

/**
 * One row of "Your submissions", from whichever table it came out of.
 *
 * Declared here rather than in a file of its own because this is where the concept started
 * and where most of it still lives, and imported as a type by src/lib/network.ts, which
 * fills the same shape from public.network_entries. Two tables, two queries, each owned by
 * the module that owns its table, one list on the page — the alternative was reports.ts
 * querying somebody else's table, which is the kind of shortcut that makes an export step
 * hard to move later.
 *
 * `kind` is what the page needs to say "network entry" rather than "report", and to decide
 * whether there is an edit screen to offer. There is one for a report and not for an entry.
 */
export interface OwnSubmission {
  readonly kind: 'report' | 'entry';
  readonly id: string;
  readonly title: string;
  readonly status: 'published' | 'hidden';
  readonly createdAt: string;
  readonly deletedAt: string | null;
  /**
   * Whether the author can still change the text.
   *
   * For a report: while it is hidden, and until somebody else has confirmed or commented on
   * it. `reports.answered_at` records that second half — it started life as two `not exists`
   * subqueries in the policy and had to become a column, because a policy on public.reports
   * that reads public.comments recurses through the comment policy that reads
   * public.reports. The policy is still the truth; this decides whether to offer a link to a
   * screen that would refuse.
   */
  readonly editable: boolean;
}

/**
 * What this account has posted as a report, in whatever state it is in.
 *
 * Nothing here waits for anybody: a report is in the corpus the moment it is written. What
 * this list is for is the other end — seeing that something was hidden, rather than
 * discovering it by its absence, and reaching the edit screen that a hide makes available.
 * The reason it was hidden is not on these rows; it is in public.moderation_notices, which
 * src/lib/notices.ts reads and the account page shows beside them.
 *
 * No policy is being worked around: reports_select_own already returns exactly these rows
 * to their author and nothing else. The query is written with an explicit author filter
 * anyway, because a filter that agrees with the policy documents it — and because this table
 * also has a moderator policy, so an unfiltered query would return the whole corpus to one.
 */
export async function loadOwnReports(userId: string): Promise<Result<OwnSubmission[]>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('reports')
      .select('id, title, status, created_at, deleted_at, answered_at')
      .eq('author_id', userId)
      .order('created_at', { ascending: false });

    if (error) return { ok: false, message: describe(error) };

    return {
      ok: true,
      value: (data ?? []).map((row) => ({
        kind: 'report' as const,
        id: row.id as string,
        title: row.title as string,
        status: row.status as OwnSubmission['status'],
        createdAt: row.created_at as string,
        deletedAt: (row.deleted_at as string | null) ?? null,
        editable:
          row.deleted_at === null &&
          (row.status === 'hidden' || row.answered_at === null),
      })),
    };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Editing what is still editable ────────────────────────────────────────────────────
//
// A report's text can change while it is hidden, and until somebody else has confirmed or
// commented on it. Both halves matter: a hidden report is what an author has been asked in
// writing to fix, and an unanswered one is a fresh submission with a typo in it. Once an
// answer exists the text fixes itself, because that answer attests to a version.

/** Full report data needed to pre-fill the edit form. */
export interface EditableReportForEdit {
  readonly id: string;
  readonly title: string;
  readonly area: Area;
  readonly areaOther: string | null;
  readonly taskType: TaskType;
  readonly taskSecondary: readonly TaskType[];
  readonly careerStage: CareerStage | null;
  readonly aim: string;
  readonly method: string;
  readonly outcome: Outcome;
  readonly outcomeNotes: string;
  readonly verification: string;
  readonly prompts: string | null;
  readonly transcriptExcerpt: string | null;
  readonly transcriptUrl: string | null;
  readonly caveats: string | null;
  readonly references: readonly CorpusReference[];
  readonly thirdPartyMaterialConfirmed: boolean;
  readonly timeSpentMinutes: number | null;
  readonly wasPublished: string | null;
  readonly wasDisclosed: boolean | null;
  readonly authorConfidence: number | null;
  readonly ratings: Ratings;
  readonly timeSaved: string | null;
  readonly generalises: Generalises | null;
  readonly learnedSomething: boolean | null;
  readonly learnedNotes: string | null;
  readonly tools: readonly {
    id: string;
    name: string;
    version: string;
    usedOn: string;
    role: string | null;
  }[];
  readonly tagCodes: readonly string[];
}

/**
 * The row that query asks for, named because the query cannot describe itself.
 *
 * supabase-js infers the row from the *literal type* of the select string, and a string
 * built with `+` is not a literal — TypeScript widens `'a,' + 'b'` to `string`. The parser
 * then gives up and types `data` as `GenericStringError`, so every `data.title` in the
 * block below is an error rather than a column. Nineteen of them, all reading as though
 * the columns had been renamed out from under the query, when the query is fine and the
 * string is the only thing wrong.
 *
 * Passing the row type to `.single<T>()` settles it, which is what `loadProfile` already
 * does with `PROFILE_COLUMNS` — same concatenated select, no errors, because it names its
 * row. Reformatting the select onto one line would also work and would be worse: it would
 * fix this by accident, and the next person to wrap the line would break it again.
 */
interface EditableReportRow {
  id: string;
  title: string;
  area: Area;
  area_other: string | null;
  task_type: TaskType;
  task_secondary: TaskType[] | null;
  career_stage: CareerStage | null;
  aim: string;
  method: string;
  outcome: Outcome;
  outcome_notes: string;
  verification: string;
  prompts: string | null;
  transcript_excerpt: string | null;
  transcript_url: string | null;
  caveats: string | null;
  references: CorpusReference[] | null;
  third_party_material_confirmed: boolean;
  time_spent_minutes: number | null;
  was_published: string | null;
  was_disclosed: boolean | null;
  author_confidence: number | null;
  rating_helpfulness: number | null;
  time_saved: string | null;
  rating_trust_before_checking: number | null;
  rating_verification_effort: number | null;
  rating_novelty: number | null;
  rating_understanding_gained: number | null;
  generalises: Generalises | null;
  learned_something: boolean | null;
  learned_notes: string | null;
  report_tools: {
    id: string;
    tool_name: string;
    tool_version: string;
    used_on: string;
    role: string | null;
  }[];
  report_tags: { tags: { code: string } | null }[];
}

/**
 * The full content of one editable report, owned by the caller.
 *
 * Used to pre-fill the edit form. The author filter agrees with reports_select_own; there is
 * deliberately no status filter, because "editable" is a question about other people's
 * answers rather than about this row, and reports_update_own_editable is the guard that
 * settles it when the form is saved.
 *
 * Why the reason a moderator gave is not selected here: it is not on this row any more. The
 * explanation lives in public.moderation_notices, addressed to this author, and the edit
 * page reads it through src/lib/notices.ts — one place that knows what a decision said,
 * rather than a copy on every table a decision can be about.
 */
export async function loadEditableReport(
  reportId: string,
  userId: string,
): Promise<Result<EditableReportForEdit>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('reports')
      .select(
        'id, title, area, area_other, task_type, task_secondary, career_stage,' +
        'aim, method, outcome, outcome_notes, verification,' +
        'prompts, transcript_excerpt, transcript_url, references, caveats,' +
        'third_party_material_confirmed,' +
        'time_spent_minutes, was_published, was_disclosed, author_confidence,' +
        'rating_helpfulness, time_saved, rating_trust_before_checking,' +
        'rating_verification_effort, rating_novelty, rating_understanding_gained,' +
        'generalises, learned_something, learned_notes,' +
        'report_tools(id, tool_name, tool_version, used_on, role),' +
        'report_tags(tags(code))',
      )
      .eq('id', reportId)
      .eq('author_id', userId)
      .single<EditableReportRow>();

    if (error) {
      if (error.code === 'PGRST116') {
        return { ok: false, message: 'This submission was not found.' };
      }
      return { ok: false, message: describe(error) };
    }
    if (!data) return { ok: false, message: 'Not found.' };

    // Both embeds are arrays PostgREST always sends, but an empty one is sent as [] only
    // when the relation resolves; keep the guard rather than trusting that.
    const tools = data.report_tools ?? [];
    const tagLinks = data.report_tags ?? [];

    return {
      ok: true,
      value: {
        id: data.id,
        title: data.title,
        area: data.area,
        areaOther: data.area_other,
        taskType: data.task_type,
        taskSecondary: data.task_secondary ?? [],
        careerStage: data.career_stage,
        aim: data.aim,
        method: data.method,
        outcome: data.outcome,
        outcomeNotes: data.outcome_notes,
        verification: data.verification,
        prompts: data.prompts,
        transcriptExcerpt: data.transcript_excerpt,
        transcriptUrl: data.transcript_url,
        caveats: data.caveats,
        references: data.references ?? [],
        thirdPartyMaterialConfirmed: data.third_party_material_confirmed,
        timeSpentMinutes: data.time_spent_minutes,
        wasPublished: data.was_published,
        wasDisclosed: data.was_disclosed,
        authorConfidence: data.author_confidence,
        ratings: {
          rating_helpfulness: data.rating_helpfulness,
          rating_trust_before_checking: data.rating_trust_before_checking,
          rating_verification_effort: data.rating_verification_effort,
          rating_novelty: data.rating_novelty,
          rating_understanding_gained: data.rating_understanding_gained,
        },
        timeSaved: data.time_saved,
        generalises: data.generalises,
        learnedSomething: data.learned_something,
        learnedNotes: data.learned_notes,
        tools: tools.map((tool) => ({
          id: tool.id,
          name: tool.tool_name,
          version: tool.tool_version,
          usedOn: tool.used_on,
          role: tool.role,
        })),
        tagCodes: tagLinks.flatMap((link) => (link.tags ? [link.tags.code] : [])),
      },
    };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/**
 * Replace a hidden report's content in one transaction.
 *
 * Calls the resubmit_report RPC, which is the only way to replace the tool set atomically
 * while satisfying the deferred at-least-one-tool constraint. Same reasoning as submitReport.
 *
 * It does not unhide anything, and cannot: `status` is reverted by the guard trigger and
 * there is no policy that would let an author set it. Saving revises the text and leaves the
 * report hidden until a moderator looks again — which is the honest shape of the exchange,
 * since a save that republished would be self-approval with extra steps.
 */
export async function resubmitReport(
  reportId: string,
  submission: Submission,
): Promise<Result<void>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { error } = await supabase.rpc('resubmit_report', {
      p_report_id: reportId,
      ...rpcArguments(submission),
    });

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: undefined };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Whether the report still describes what happens ───────────────────────────────────
//
// Two questions, not one. Which two answers are on offer is decided by the report's
// outcome and enforced by a trigger, so a caller passing the wrong pair gets a finished
// sentence back rather than a stored row. `verdictsFor()` in ./status is what the form
// asks with; this layer only carries the value.

export type { Verdict } from './status';

export interface Confirmation {
  readonly id: string;
  readonly userId: string;
  readonly verdict: Verdict;
  readonly note: string;
  readonly createdAt: string;
  readonly displayName: string;
  readonly isPseudonym: boolean;
}

export interface ConfirmationState {
  readonly all: readonly Confirmation[];
  /** The signed-in reader's own, if they have one. Null when signed out. */
  readonly mine: Confirmation | null;
}

/**
 * The live tally, read from the browser rather than taken from the build.
 *
 * The static page already carries a count, and this replaces it a moment later with one
 * that includes anything filed since the last build. A tally is exactly the kind of number
 * a reader will act on — "three people say this no longer works" changes whether they spend
 * an afternoon on it — so a day-stale one is worth one small query to correct.
 */
export async function loadConfirmations(
  reportId: string,
  viewerId: string | null,
): Promise<Result<ConfirmationState>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('report_confirmations')
      .select(
        'id, user_id, verdict, note, created_at, profiles!report_confirmations_user_id_fkey(display_name, is_pseudonym)',
      )
      .eq('report_id', reportId)
      .order('created_at', { ascending: false });

    if (error) return { ok: false, message: describe(error) };

    const all: Confirmation[] = (data ?? []).map((row) => {
      const person = row.profiles as unknown as
        | { display_name: string; is_pseudonym: boolean }
        | null;

      return {
        id: row.id as string,
        userId: row.user_id as string,
        verdict: row.verdict as Verdict,
        note: (row.note as string | null) ?? '',
        createdAt: row.created_at as string,
        // An erased account leaves its confirmations behind only in principle: the row
        // cascades with the account. A null here is a race, not a state.
        displayName: person?.display_name ?? 'A former member',
        isPseudonym: person?.is_pseudonym ?? false,
      };
    });

    return {
      ok: true,
      value: { all, mine: all.find((one) => one.userId === viewerId) ?? null },
    };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/** One row per person per report, so this is an upsert on that pair. Changing your mind
 *  edits the row rather than adding a second one. */
export async function saveConfirmation(
  reportId: string,
  userId: string,
  verdict: Verdict,
  note: string,
): Promise<Result<null>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { error } = await supabase
      .from('report_confirmations')
      .upsert(
        {
          report_id: reportId,
          user_id: userId,
          verdict,
          note: note.trim() || null,
        },
        { onConflict: 'report_id,user_id' },
      );

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: null };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

/** Withdrawing is a delete, so that "I no longer have a view" is representable. Without it
 *  the only way out of a verdict would be to hold a different one. */
export async function withdrawConfirmation(
  reportId: string,
  userId: string,
): Promise<Result<null>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { error } = await supabase
      .from('report_confirmations')
      .delete()
      .eq('report_id', reportId)
      .eq('user_id', userId);

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: null };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

// ── Turning a failure into a sentence ─────────────────────────────────────────────────

/**
 * A write that fails from the browser gives you a SQLSTATE and a message written for
 * whoever wrote the constraint. Neither belongs in front of somebody who has just spent ten
 * minutes on a submission, so each is mapped to what they should do about it.
 *
 * **When a write fails unexpectedly, check the grants before the policies.** A table with
 * no grant and a table whose policy returns nothing are indistinguishable from here: both
 * are 42501, or both are an empty result. Grants decide whether the endpoint exists;
 * policies decide which rows it returns. Both are needed, and the one people forget is the
 * grant, because the policy is the part that felt like the security work.
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
      // Several of our own constraints raise finished sentences — the at-least-one tool
      // rule, the future-dated tool, the daily limit — so the message is passed through
      // when it reads like prose and replaced when it reads like a constraint name.
      return looksLikeProse(message)
        ? message
        : 'One of the fields is outside the limits the form shows. Check the counters and the dates, then try again.';

    case '23505':
      return 'That looks like a duplicate of something already submitted. If you meant to send it twice, it is already there.';

    case '42501':
      return 'This account is not allowed to do that. It usually means the email address has not been confirmed yet — check the confirmation email.';

    case '53400':
      return looksLikeProse(message)
        ? message
        : 'You have reached what one account can post in a day. This exists so nobody can bury a volunteer moderation queue; try again tomorrow.';

    case '22P02':
      return 'One of the choices was not one of the offered values. Reload the page and try again.';

    case 'PGRST301':
      return 'Your session has ended. Sign in again — your draft is saved in this browser.';

    case 'PGRST202':
      return 'Submitting is not available on this deployment yet. Your draft is saved in this browser.';
  }

  if (
    lower.includes('failed to fetch') ||
    lower.includes('fetch failed') ||
    lower.includes('networkerror') ||
    lower.includes('load failed')
  ) {
    return UNAVAILABLE;
  }

  return 'That did not go through, and nothing was saved to the site. If it keeps failing, the details are worth reporting.';
}

/** Whether a database message was written for a person. The functions in
 *  supabase/migrations/ raise finished sentences on purpose; Postgres itself does not. */
function looksLikeProse(message: string): boolean {
  return /^[A-Z].*[.!?]$/.test(message.trim()) && !message.includes('_');
}
