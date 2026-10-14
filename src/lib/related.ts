/**
 * Related reports: cosine similarity over precomputed sentence embeddings.
 *
 * Runs at build time only — this module is imported in Astro frontmatter, never in a
 * client <script>. The embeddings file is loaded via import.meta.glob (eager), so Vite
 * reads it once per build and caches it across all report pages.
 *
 * Model: sentence-transformers/all-MiniLM-L6-v2 (Apache 2.0), 384 dimensions.
 * Each embedding is L2-normalised then stored as uint8 (0–255 per dimension) encoded in
 * base64. Dequantisation reverses the map: byte / 255 * 2 - 1. Cosine similarity on
 * L2-normalised vectors is a dot product; after dequantisation they are approximately
 * unit vectors, so we renormalise before comparing.
 *
 * The reason string is rule-based: shared task type first, then shared tags, then shared
 * area, then a generic fallback. The words are always taken from the report's own
 * metadata — nothing is generated.
 *
 * If data/embeddings.json does not yet exist (before the first embed.yml run), findRelated
 * returns [] rather than failing the build.
 */
import type { Report } from './reports';
import { areaLabel, taskTypeLabel } from './report-schema';

interface StoredEntry {
  readonly id: string;
  readonly title: string;
  readonly taskType: string;
  readonly area: string;
  readonly tags: readonly string[];
  /** base64-encoded Uint8Array, 384 bytes */
  readonly v: string;
}

interface EmbeddingStore {
  readonly reports: readonly StoredEntry[];
}

export interface RelatedReport {
  readonly id: string;
  readonly title: string;
  /** One-line explanation derived from shared metadata, never generated prose. */
  readonly reason: string;
}

// ── Load embeddings ────────────────────────────────────────────────────────────────────

const EXPORTED = import.meta.glob<{ default: EmbeddingStore }>('/data/embeddings.json', {
  eager: true,
});

// Pre-dequantised entries, built once per build process and reused across all pages.
let precomputed: Array<StoredEntry & { readonly vec: Float32Array }> | null = null;

function getPrecomputed(): Array<StoredEntry & { readonly vec: Float32Array }> {
  if (precomputed) return precomputed;

  const store = Object.values(EXPORTED)[0]?.default;
  if (!store) {
    precomputed = [];
    return precomputed;
  }

  precomputed = store.reports.map((e) => ({
    ...e,
    vec: dequantize(e.v),
  }));
  return precomputed;
}

// ── Vector math ────────────────────────────────────────────────────────────────────────

function dequantize(b64: string): Float32Array {
  // atob is available globally in Node.js 16+.
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const floats = new Float32Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    floats[i] = bytes[i] / 255 * 2 - 1;
  }
  return floats;
}

function dot(a: Float32Array, b: Float32Array): number {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i] * b[i];
  return s;
}

function norm(a: Float32Array): number {
  return Math.sqrt(dot(a, a));
}

function cosine(a: Float32Array, b: Float32Array): number {
  const na = norm(a);
  const nb = norm(b);
  if (na === 0 || nb === 0) return 0;
  return dot(a, b) / (na * nb);
}

// ── Reason string ──────────────────────────────────────────────────────────────────────

function buildReason(subject: Report, candidate: StoredEntry): string {
  if (subject.taskType === candidate.taskType) {
    return `Same task type: ${taskTypeLabel(subject.taskType as never)}`;
  }

  const subjectCodes = subject.tags.map((t) => t.code);
  const shared = subjectCodes.filter((c) => candidate.tags.includes(c));

  if (shared.length >= 2) {
    return `Shared topics: ${shared.slice(0, 3).join(', ')}`;
  }

  if (subject.area === candidate.area) {
    return `Same area: ${areaLabel(subject.area as never)}`;
  }

  if (shared.length === 1) {
    return `Shared topic: ${shared[0]}`;
  }

  return 'Similar aim and approach';
}

// ── Public API ─────────────────────────────────────────────────────────────────────────

const THRESHOLD = 0.70;
const DEFAULT_COUNT = 4;

/**
 * Find related reports for a given report, using cosine similarity over the
 * precomputed sentence embeddings. Returns up to `count` results above the similarity
 * threshold, sorted by descending similarity.
 *
 * Returns [] when the embeddings file is absent or when the subject has no embedding.
 */
export function findRelated(
  report: Report,
  count: number = DEFAULT_COUNT,
): RelatedReport[] {
  const entries = getPrecomputed();
  if (entries.length === 0) return [];

  const subject = entries.find((e) => e.id === report.id);
  if (!subject) return [];

  return entries
    .filter((e) => e.id !== report.id)
    .map((e) => ({ e, sim: cosine(subject.vec, e.vec) }))
    .filter(({ sim }) => sim > THRESHOLD)
    .sort((a, b) => b.sim - a.sim)
    .slice(0, count)
    .map(({ e }) => ({
      id: e.id,
      title: e.title,
      reason: buildReason(report, e),
    }));
}
