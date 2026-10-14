/**
 * The freshness overlay: what has been posted since the site was last built.
 *
 * The corpus is served as static files from the export, which since 2026-10-11 runs within a
 * minute of any write — so a new report reaches the built listing in a few minutes rather than
 * the next day. A few minutes is still a silence to somebody who has just posted, and browsers
 * may hold a built page for ten more. So each listing hydrates from the static page and then
 * asks one question: is there anything newer than the export? Item pages ask the same question
 * of their comments, through `loadThread()` in src/lib/comments.ts.
 *
 * Four rules, and each is the difference between an overlay and a liability.
 *
 * **Plain fetch, never the Supabase client.** A listing is a reading page. Importing
 * src/lib/supabase.ts would pull the auth client, its storage adapter and its session
 * machinery into a page whose job is to be read, and CLAUDE.md forbids exactly that. This is
 * one GET against PostgREST with the publishable key, which is public by design.
 *
 * **Capped.** At most two dozen rows, and never a second page. This is a nudge toward the
 * newest handful, not a substitute for the export: if a hundred reports arrive in a day,
 * the answer is the next build, not a listing that quietly turns into a live query.
 *
 * **Time-limited.** A few seconds, then abandoned. The static content is already on screen
 * and correct; a request that hangs must not delay anything or hold a connection open.
 *
 * **Silent on failure.** Every path returns an empty array. A paused project, a network
 * failure, an over-quota database, a deployment with no keys configured: all of them mean
 * the reader sees the corpus as it stood at the last build, which is the whole point of
 * building it into files. There is no error state here and there should not be one — an
 * error message about a database on a page that is already showing its content would teach
 * readers that this site depends on something it does not.
 */

/** At most this many rows, ever. See the header. */
const LIMIT = 24;

/** Abandoned after this. Long enough for a slow connection, short enough that nobody waits. */
const TIMEOUT_MS = 4000;

const URL_BASE = import.meta.env.PUBLIC_SUPABASE_URL;
const KEY = import.meta.env.PUBLIC_SUPABASE_ANON_KEY;

export interface FreshReport {
  readonly id: string;
  readonly title: string;
  readonly aim: string;
  readonly area: string;
  readonly areaOther: string | null;
  readonly taskType: string;
  readonly taskSecondary: readonly string[];
  readonly careerStage: string | null;
  readonly outcome: 'worked' | 'partial' | 'failed';
  readonly createdAt: string;
  readonly authorName: string | null;
  /** Null for an erased account, and always null when `authorName` is. */
  readonly authorId: string | null;
  readonly tools: readonly { name: string; version: string; usedOn: string | null }[];
  readonly tags: readonly string[];
  /**
   * Enough to compute the version 2 filter facets in the browser.
   *
   * Booleans rather than the text: a fresh card is a summary and never shows a prompt or a
   * transcript, so fetching twenty thousand characters of excerpt to decide whether a
   * checkbox matches would be paying for the whole record to answer a yes-or-no question.
   */
  readonly hasPrompts: boolean;
  readonly hasTranscript: boolean;
  readonly referenceKinds: readonly string[];
  readonly timeSpentMinutes: number | null;
  readonly generalises: string | null;
  readonly ratingHelpfulness: number | null;
  readonly ratingVerificationEffort: number | null;
  readonly ratingNovelty: number | null;
}

export interface FreshClaim {
  readonly id: string;
  readonly statement: string;
  readonly area: string;
  readonly createdAt: string;
}

export interface FreshEntry {
  readonly id: string;
  readonly title: string;
  readonly url: string;
  readonly urlNormalised: string;
  readonly category: string;
  readonly categoryOther: string | null;
  readonly description: string;
  readonly relevance: string | null;
  readonly createdAt: string;
}

/**
 * One request, or none.
 *
 * `AbortController` with a timer rather than `AbortSignal.timeout`, which several browsers
 * this audience still uses do not have. A silent overlay that throws a ReferenceError in
 * Safari 15 is not silent — it takes the rest of the page's script with it.
 */
async function ask<T>(query: string): Promise<T[]> {
  if (!URL_BASE || !KEY) return [];

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const response = await fetch(`${URL_BASE}/rest/v1/${query}`, {
      headers: { apikey: KEY, Authorization: `Bearer ${KEY}` },
      signal: controller.signal,
    });

    if (!response.ok) return [];
    const rows = await response.json();
    return Array.isArray(rows) ? rows : [];
  } catch {
    return [];
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Published reports created after `since`.
 *
 * The filters restate what row level security already enforces for the anonymous key. That
 * is not redundancy for its own sake: this is the one query in the project whose result is
 * prepended to a page as though it came from the corpus, and the day somebody widens a
 * policy is the day it would start showing pending submissions to everybody.
 */
export async function reportsSince(since: string): Promise<FreshReport[]> {
  const select = [
    'id,title,aim,area,area_other,task_type,task_secondary,career_stage,outcome,created_at',
    // `has_prompts` and `has_transcript` are generated columns and exist for this query.
    // Selecting `prompts` and `transcript_excerpt` instead would mean fetching up to
    // twenty-four thousand characters per row to answer two yes-or-no questions.
    'has_prompts,has_transcript,references,time_spent_minutes,generalises',
    'rating_helpfulness,rating_verification_effort,rating_novelty',
    'author:profiles!reports_author_id_fkey(id,display_name,is_pseudonym)',
    // `used_on` is what the recency filter needs, and it is per tool rather than per report
    // because a session that used one model in March and a proof assistant in June is stale
    // in one half and current in the other.
    'report_tools(tool_name,tool_version,used_on)',
    'report_tags(tags(code))',
  ].join(',');

  const rows = await ask<RawFreshReport>(
    `reports?select=${encodeURIComponent(select)}` +
      `&status=eq.published&deleted_at=is.null&created_at=gt.${encodeURIComponent(since)}` +
      `&order=created_at.desc&limit=${LIMIT}`,
  );

  return rows.map((row) => ({
    id: row.id,
    title: row.title,
    aim: row.aim,
    area: row.area,
    areaOther: row.area_other ?? null,
    taskType: row.task_type,
    taskSecondary: row.task_secondary ?? [],
    careerStage: row.career_stage ?? null,
    outcome: row.outcome,
    createdAt: row.created_at,
    // The name and the id it links to. No institutional badge, because a badge is an
    // attestation with a date on it and the date is not in this query.
    authorName: row.author?.display_name ?? null,
    authorId: row.author?.id ?? null,
    tools: (row.report_tools ?? []).map((tool) => ({
      name: tool.tool_name,
      version: tool.tool_version,
      usedOn: tool.used_on ?? null,
    })),
    tags: (row.report_tags ?? []).flatMap((link) => (link.tags ? [link.tags.code] : [])),
    hasPrompts: row.has_prompts ?? false,
    hasTranscript: row.has_transcript ?? false,
    referenceKinds: (row.references ?? []).map((reference) => reference.kind),
    timeSpentMinutes: row.time_spent_minutes ?? null,
    generalises: row.generalises ?? null,
    ratingHelpfulness: row.rating_helpfulness ?? null,
    ratingVerificationEffort: row.rating_verification_effort ?? null,
    ratingNovelty: row.rating_novelty ?? null,
  }));
}

/** Claims created after `since`. Anything this new is `active`: a claim is part of the
 *  record when it is written, and only a moderation decision moves it out of that state. */
export async function claimsSince(since: string): Promise<FreshClaim[]> {
  const rows = await ask<RawFreshClaim>(
    'claims?select=id,statement,area,created_at' +
      `&status=eq.active&created_at=gt.${encodeURIComponent(since)}` +
      `&order=created_at.desc&limit=${LIMIT}`,
  );

  return rows.map((row) => ({
    id: row.id,
    statement: row.statement,
    area: row.area,
    createdAt: row.created_at,
  }));
}

interface RawFreshReport {
  id: string;
  title: string;
  aim: string;
  area: string;
  area_other: string | null;
  task_type: string;
  task_secondary: string[] | null;
  career_stage: string | null;
  outcome: 'worked' | 'partial' | 'failed';
  created_at: string;
  has_prompts: boolean | null;
  has_transcript: boolean | null;
  references: { kind: string }[] | null;
  time_spent_minutes: number | null;
  generalises: string | null;
  rating_helpfulness: number | null;
  rating_verification_effort: number | null;
  rating_novelty: number | null;
  author: { id: string; display_name: string; is_pseudonym: boolean } | null;
  report_tools: { tool_name: string; tool_version: string; used_on: string | null }[];
  report_tags: { tags: { code: string } | null }[];
}

/** Published entries created after `since`. */
export async function networkSince(since: string): Promise<FreshEntry[]> {
  const rows = await ask<RawFreshEntry>(
    'network_entries?select=id,title,url,url_normalised,category,category_other,description,relevance,created_at' +
      `&status=eq.published&created_at=gt.${encodeURIComponent(since)}` +
      `&order=created_at.desc&limit=${LIMIT}`,
  );

  return rows.map((row) => ({
    id: row.id,
    title: row.title,
    url: row.url,
    urlNormalised: row.url_normalised,
    category: row.category,
    categoryOther: row.category_other ?? null,
    description: row.description,
    relevance: row.relevance ?? null,
    createdAt: row.created_at,
  }));
}

interface RawFreshClaim {
  id: string;
  statement: string;
  area: string;
  created_at: string;
}

interface RawFreshEntry {
  id: string;
  title: string;
  url: string;
  url_normalised: string;
  category: string;
  category_other: string | null;
  description: string;
  relevance: string | null;
  created_at: string;
}
