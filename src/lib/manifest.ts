/**
 * When the corpus in data/ was exported.
 *
 * One fact, in one place, because two things depend on it and they must agree: the build,
 * which renders everything the export contained, and the freshness overlay, which asks the
 * database for anything newer. If the overlay's cutoff were the build time instead, every
 * row posted between the export and the deploy would be invisible until the next night.
 *
 * Read at build time from the committed manifest. Null in a checkout that has never run
 * scripts/export.mjs, and the overlay treats that as "no cutoff, so no overlay" rather than
 * guessing — a guess here shows a reader duplicates or nothing, and neither is worth it.
 */

interface Manifest {
  readonly exportedAt: string;
  readonly generator: string;
  readonly licence: string;
  readonly files: Readonly<Record<string, { rows: number; bytes: number }>>;
}

const EXPORTED = import.meta.glob<{ default: Manifest }>('/data/manifest.json', {
  eager: true,
});

const manifest = Object.values(EXPORTED)[0]?.default ?? null;

/** ISO timestamp of the last export, or null when there has not been one. */
export function exportedAt(): string | null {
  return manifest?.exportedAt ?? null;
}

/** Row counts per file, for anything that wants to state the size of the corpus. */
export function exportedRows(file: string): number | null {
  return manifest?.files?.[file]?.rows ?? null;
}
