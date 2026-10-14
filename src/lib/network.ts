/**
 * Entry data access — build-time reads from data/network.json, and one browser read.
 *
 * The corpus reads happen at build time from the nightly export. Nothing in that half talks
 * to Supabase, and the client is only loaded on pages that need live writes.
 *
 * The exception at the bottom, loadOwnEntries(), is a browser read for the same reason
 * loadOwnReports() is one: a pending submission is a row the static export must never
 * contain, so the only way its author can see what state it is in is to ask. Importing
 * getSupabase() here does not pull the client onto /network/, which reads this module from
 * frontmatter — that runs at build time and is never bundled for a browser.
 */
import rawJson from '../../data/network.json';
import { getSupabase } from './supabase';
import type { OwnSubmission, Result } from './reports';

export type NetworkCategory =
  | 'research_tool'
  | 'educational'
  | 'formalisation'
  | 'guidelines_and_policy'
  | 'community'
  | 'reading'
  | 'other';

export type NetworkLinkStatus = 'ok' | 'unreachable' | 'redirected' | null;

export interface NetworkSubmitter {
  readonly id: string;
  readonly displayName: string;
  readonly isPseudonym: boolean;
  readonly institution: {
    readonly name: string;
    readonly country: string;
    readonly verifiedAt: string;
  } | null;
}

export interface Entry {
  readonly id: string;
  readonly title: string;
  readonly url: string;
  readonly urlNormalised: string;
  readonly category: NetworkCategory;
  readonly categoryOther: string | null;
  readonly description: string;
  /** Retired on 2026-08-21: the description absorbed it. Null on everything submitted since. */
  readonly relevance: string | null;
  readonly createdAt: string;
  readonly linkStatus: NetworkLinkStatus;
  readonly linkCheckedAt: string | null;
  readonly submitter: NetworkSubmitter | null;
}

/**
 * The category vocabulary, with a one-line explanation each.
 *
 * The hints are not decoration: the submission form renders these as a radio list rather
 * than a select, for the reason given in forms.css — a select hides most of the options and
 * all of their explanations, and a category picked without reading the alternatives is the
 * one that makes a filter useless.
 *
 * `other` sits last and is the only value that takes free text beside it.
 */
export const CATEGORIES: readonly { value: NetworkCategory; label: string; hint: string }[] = [
  {
    value: 'research_tool',
    label: 'Research tool',
    hint: 'Something used directly in doing mathematics.',
  },
  {
    value: 'educational',
    label: 'Educational',
    hint: 'Courses, lectures, and material for learning.',
  },
  {
    value: 'formalisation',
    label: 'Formalisation',
    hint: 'Proof assistants, their libraries, and formal methods.',
  },
  {
    value: 'guidelines_and_policy',
    label: 'Guidelines and policy',
    hint: 'Declarations, journal policies, and codes of practice.',
  },
  {
    value: 'community',
    label: 'Community',
    hint: 'Groups, seminars, forums, and mailing lists.',
  },
  {
    value: 'reading',
    label: 'Reading',
    hint: 'Papers, essays, and reports worth the time.',
  },
  {
    value: 'other',
    label: 'Other',
    hint: 'None of these. You will be asked to say which.',
  },
];

export function categoryLabel(value: NetworkCategory, categoryOther?: string | null): string {
  if (value === 'other' && categoryOther) return categoryOther;
  return CATEGORIES.find((c) => c.value === value)?.label ?? value;
}

let _entries: Entry[] | null = null;

export function listNetwork(): Entry[] {
  if (_entries !== null) return _entries;
  _entries = (rawJson as Entry[]);
  return _entries;
}

export function getEntry(id: string): Entry | undefined {
  return listNetwork().find((r) => r.id === id);
}

/** One person's published entries, for their author page. Erased submitters are absent by
 *  construction: their rows keep the entry and lose the name. */
export function entriesBySubmitter(submitterId: string): Entry[] {
  return listNetwork().filter((r) => r.submitter?.id === submitterId);
}

/**
 * Client-side URL normalisation, kept in sync with private.normalise_url() in
 * supabase/migrations/20260816100000_resources.sql.
 *
 * Used in the submission form to check for duplicates before submitting.
 */
export function normaliseUrl(url: string): string {
  const TRACKING_PARAMS = new Set([
    'fbclid', 'gclid', 'mc_cid', 'mc_eid', 'msclkid', 'origin', 'ref',
    'source', 'utm_campaign', 'utm_content', 'utm_creative_format',
    'utm_id', 'utm_marketing_tactic', 'utm_medium', 'utm_source',
    'utm_source_platform', 'utm_term',
  ]);

  let u = url.toLowerCase().replace(/^https?:\/\//, '');
  const qmark = u.indexOf('?');

  if (qmark === -1) {
    return u.replace(/\/+$/, '');
  }

  const pathPart = u.slice(0, qmark).replace(/\/+$/, '');
  const params = u
    .slice(qmark + 1)
    .split('&')
    .filter((p) => p !== '' && !TRACKING_PARAMS.has(p.split('=')[0]))
    .sort()
    .join('&');

  return params ? `${pathPart}?${params}` : pathPart;
}

// ── Your own entries ──────────────────────────────────────────────────────────────────

const UNAVAILABLE =
  'Your submitted entries cannot be loaded right now. Try again in a few minutes; nothing has been lost.';

/**
 * What this account has submitted to the network, in whatever state it is in.
 *
 * The other half of "Your submissions" on the account page, alongside loadOwnReports(). An
 * entry is live the moment it is written, so this list matters when one has been hidden: the
 * explanation is in public.moderation_notices and shown beside it, and the row is editable
 * for as long as it stays hidden.
 *
 * What is still missing, and is not fixed here: there is no edit screen for an entry, so
 * acting on the explanation means deleting and reposting. docs/moderation.md says so.
 *
 * network_entries_select_own already returns exactly these rows to their submitter. The
 * explicit filter is written anyway, because a filter that agrees with the policy documents
 * it — and because this table also has a moderator policy.
 */
export async function loadOwnEntries(userId: string): Promise<Result<OwnSubmission[]>> {
  const supabase = getSupabase();
  if (!supabase) return { ok: false, message: UNAVAILABLE };

  try {
    const { data, error } = await supabase
      .from('network_entries')
      .select('id, title, status, created_at, deleted_at')
      .eq('submitter_id', userId)
      .order('created_at', { ascending: false });

    if (error) return { ok: false, message: UNAVAILABLE };

    return {
      ok: true,
      value: (data ?? []).map((row) => ({
        kind: 'entry' as const,
        id: row.id as string,
        title: row.title as string,
        status: row.status as OwnSubmission['status'],
        createdAt: row.created_at as string,
        deletedAt: (row.deleted_at as string | null) ?? null,
        // An entry has no confirmations and no comments to freeze against, so the rule is
        // the simple half of the one on reports: editable while it is hidden.
        editable: row.status === 'hidden' && row.deleted_at === null,
      })),
    };
  } catch {
    return { ok: false, message: UNAVAILABLE };
  }
}
