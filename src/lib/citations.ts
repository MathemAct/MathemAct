/**
 * The citation graph: which reports and claims point at which others.
 *
 * This is the module that makes the two halves of the site one thing. Everything else here
 * treats a report and a claim as separate kinds of document; this treats them as
 * nodes, and resolves either into the same display shape — a title, a URL, and optionally
 * the exact comment that carried the quotation.
 *
 * Read at build time like the rest of the corpus, and resolved against it: a citation row
 * knows only a kind and an id, so the title comes from src/lib/reports.ts or
 * src/lib/claims.ts. A citation whose endpoint is not in the corpus — hidden since,
 * or never published — resolves to nothing and is dropped rather than rendered as a broken
 * link. Row level security already refuses those rows to the anonymous key the build uses;
 * dropping them here is the second lock, for the day the site builds from a JSON export
 * somebody assembled by hand.
 */
import { path } from './paths';
import { getReport } from './reports';
import { getClaim } from './claims';
import { getSupabase } from './supabase';

export type NodeType = 'report' | 'claim';

export interface Citation {
  readonly id: string;
  readonly sourceType: NodeType;
  readonly sourceId: string;
  readonly sourceCommentId: string | null;
  readonly targetType: NodeType;
  readonly targetId: string;
  readonly targetCommentId: string | null;
  /** The passage as it read when it was quoted. A copy, so it survives the target changing. */
  readonly excerpt: string | null;
  /** Why, in the citer's words. One line. */
  readonly context: string | null;
  readonly createdAt: string;
}

/** A citation with both ends resolved against the corpus, ready to render. */
export interface Reference {
  readonly id: string;
  readonly excerpt: string | null;
  readonly context: string | null;
  readonly createdAt: string;
  /** The page at the other end of the arrow, whichever direction is being shown. */
  readonly other: {
    readonly type: NodeType;
    readonly id: string;
    readonly title: string;
    readonly href: string;
  };
  /** An anchor on *this* page: the comment that was quoted, when one was. */
  readonly hereCommentId: string | null;
}

// ── The swap point ────────────────────────────────────────────────────────────────────

const EXPORTED = import.meta.glob<{ default: Citation[] }>('/data/citations.json', {
  eager: true,
});

let cached: Citation[] | null = null;

/**
 * The committed export, and nothing else.
 *
 * Every arrow in the file has both endpoints public: the export filters on it, because a
 * citation carries a verbatim excerpt of its target and one that outlived its target being
 * hidden would republish, on a third page, exactly the passage a moderator removed. The
 * resolution below drops anything that still fails to resolve, which is the second lock.
 */
async function readCitations(): Promise<Citation[]> {
  if (cached) return cached;

  const exported = Object.values(EXPORTED)[0]?.default;

  if (!exported) {
    console.warn(
      '[citations] data/citations.json is missing, so no page shows what references it. ' +
        'Run scripts/export.mjs, or let .github/workflows/export.yml commit one.',
    );
    cached = [];
    return cached;
  }

  cached = exported;
  return cached;
}

// ── Resolving a node ──────────────────────────────────────────────────────────────────

/**
 * A kind and an id become a title and a URL, or nothing.
 *
 * A claim's "title" is its statement, which is capped at 200 characters precisely so
 * that it can be used this way: one claim, quotable whole, no truncation needed.
 */
async function resolve(
  type: NodeType,
  id: string,
): Promise<{ type: NodeType; id: string; title: string; href: string } | null> {
  if (type === 'report') {
    const report = await getReport(id);
    return report
      ? { type, id, title: report.title, href: path(`/reports/${id}/`) }
      : null;
  }

  const claim = await getClaim(id);
  return claim
    ? { type, id, title: claim.statement, href: path(`/opinions/${id}/`) }
    : null;
}

async function toReferences(
  citations: readonly Citation[],
  direction: 'incoming' | 'outgoing',
): Promise<Reference[]> {
  const resolved = await Promise.all(
    citations.map(async (citation) => {
      const other =
        direction === 'incoming'
          ? await resolve(citation.sourceType, citation.sourceId)
          : await resolve(citation.targetType, citation.targetId);

      if (!other) return null;

      return {
        id: citation.id,
        excerpt: citation.excerpt,
        context: citation.context,
        createdAt: citation.createdAt,
        other: {
          ...other,
          // The anchor on the *other* page: for an incoming reference that is the comment
          // that did the citing, which is what makes "referenced by" land on the paragraph
          // rather than the top of a long page.
          href:
            direction === 'incoming' && citation.sourceCommentId
              ? `${other.href}#comment-${citation.sourceCommentId}`
              : direction === 'outgoing' && citation.targetCommentId
                ? `${other.href}#comment-${citation.targetCommentId}`
                : other.href,
        },
        hereCommentId:
          direction === 'incoming' ? citation.targetCommentId : citation.sourceCommentId,
      };
    }),
  );

  return resolved.filter((reference): reference is Reference => reference !== null);
}

/** Everything pointing at this page. The "referenced by" block. */
export async function referencesTo(type: NodeType, id: string): Promise<Reference[]> {
  const all = await readCitations();
  return toReferences(
    all.filter((citation) => citation.targetType === type && citation.targetId === id),
    'incoming',
  );
}

/** Everything this page points at. Shown alongside, because a claim built out of
 *  three accounts should say so on its own page and not only on theirs. */
export async function referencesFrom(type: NodeType, id: string): Promise<Reference[]> {
  const all = await readCitations();
  return toReferences(
    all.filter((citation) => citation.sourceType === type && citation.sourceId === id),
    'outgoing',
  );
}

// ══ Writes ════════════════════════════════════════════════════════════════════════════

export type Result<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly message: string };

export interface NewCitation {
  sourceType: NodeType;
  sourceId: string;
  /** The comment on the source that carried the quotation, when one did. */
  sourceCommentId?: string | null;
  targetType: NodeType;
  targetId: string;
  /** The comment on the target that was quoted, when the passage came from one. */
  targetCommentId?: string | null;
  excerpt?: string | null;
  context?: string | null;
}

/**
 * Record one reference.
 *
 * Called after the comment or claim it belongs to already exists, because the
 * citation carries that row's id. That ordering means a failure here leaves a posted
 * comment with no citation attached rather than a citation pointing at nothing — the right
 * way round, since the comment is the contribution and the citation is the index entry.
 * Callers report the failure and do not roll the comment back.
 */
export async function createCitation(
  citation: NewCitation,
  createdBy: string,
): Promise<Result<string>> {
  const supabase = getSupabase();
  if (!supabase) {
    return { ok: false, message: 'The reference could not be recorded: the database is unreachable.' };
  }

  try {
    const { data, error } = await supabase
      .from('citations')
      .insert({
        source_type: citation.sourceType,
        source_id: citation.sourceId,
        source_comment_id: citation.sourceCommentId ?? null,
        target_type: citation.targetType,
        target_id: citation.targetId,
        target_comment_id: citation.targetCommentId ?? null,
        excerpt: citation.excerpt?.trim() || null,
        context: citation.context?.trim() || null,
        created_by: createdBy,
      })
      .select('id')
      .single<{ id: string }>();

    if (error) return { ok: false, message: describe(error) };
    return { ok: true, value: data.id };
  } catch (error) {
    return { ok: false, message: describe(error) };
  }
}

function describe(error: unknown): string {
  const code =
    typeof error === 'object' && error !== null && 'code' in error
      ? String((error as { code?: unknown }).code ?? '')
      : '';

  switch (code) {
    case '23505':
      return 'That reference is already recorded. It appears once, which is enough.';
    case '23514':
      return 'A page cannot reference itself, and an excerpt has to fit in 2,000 characters.';
    case '23503':
      return 'One end of that reference is no longer available. Reload the page.';
    case '42501':
      return 'This account cannot record a reference. It usually means the email address has not been confirmed yet.';
    case '53400':
      return 'You have reached what one account can link in a day. Try again tomorrow.';
  }

  // The comment or claim it belongs to has already been posted, so the failure is
  // partial rather than total and the message has to say which half survived.
  return 'The text was posted, but the reference to the passage was not recorded.';
}
