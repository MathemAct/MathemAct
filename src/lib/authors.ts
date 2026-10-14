/**
 * Who gets an author page, and where their name and badge come from.
 *
 * This is its own file rather than another function in reports.ts for a bundling reason.
 * `network.ts` does a static `import` of data/network.json, so anything that imports it
 * carries the entry corpus — and reports.ts is imported by browser scripts, the
 * submission form among them. Tree-shaking would probably drop it; probably is not a good
 * enough reason to put a build-time-only join into a module the browser loads.
 *
 * **Membership: anyone whose name is linked from something.** That is report authors,
 * claim authors, and entry submitters. Deliberately not everyone in
 * data/profiles.json, which also holds people whose only contribution is a comment — nothing
 * links a name from a comment, so a page for them would be one no reader can reach and
 * Pagefind would index it as an almost-empty result. The rule is that a page exists exactly
 * where a link to it exists. If comment authors ever become links, this function is the one
 * thing to change.
 *
 * **Identity: data/profiles.json, with the corpus as a fallback.** The three corpora do not
 * agree on how much they carry about a person. A report and an entry each embed the
 * institution triple a badge is built from; a claim embeds only the name and the
 * pseudonym flag. Taking identity from the corpus that happened to mention someone first
 * would therefore drop the institutional badge from the page of anyone who has only ever
 * posted a claim — silently, and in the one direction that matters, since a badge that
 * fails to appear looks like an account that was never verified.
 */
import type { CorpusAuthor } from './reports';
import { listReports } from './reports';
import { listClaims } from './claims';
import { listNetwork } from './network';

/** A row of data/profiles.json. A superset of CorpusAuthor, and the same shape for the
 *  fields they share, because scripts/export.mjs writes both from public.profiles. */
interface ExportedProfile extends CorpusAuthor {
  readonly bio: string | null;
  readonly createdAt: string;
}

const EXPORTED = import.meta.glob<{ default: ExportedProfile[] }>('/data/profiles.json', {
  eager: true,
});

export async function listContributors(): Promise<CorpusAuthor[]> {
  const profiles = new Map<string, CorpusAuthor>(
    (Object.values(EXPORTED)[0]?.default ?? []).map((profile) => [
      profile.id,
      {
        id: profile.id,
        displayName: profile.displayName,
        isPseudonym: profile.isPseudonym,
        institution: profile.institution,
      },
    ]),
  );

  const contributors = new Map<string, CorpusAuthor>();

  /** The profile if the export has one, otherwise whatever the corpus knew. */
  const add = (author: CorpusAuthor | null): void => {
    if (!author || contributors.has(author.id)) return;
    contributors.set(author.id, profiles.get(author.id) ?? author);
  };

  for (const report of await listReports()) add(report.author);

  for (const claim of await listClaims()) {
    // Claims carry no institution. Passing null here is safe rather than lossy: `add`
    // prefers the profile, and this value is used only if the export has no profile row for
    // somebody it also lists as an author, which the export's own query rules out.
    if (claim.author) add({ ...claim.author, institution: null });
  }

  for (const entry of listNetwork()) add(entry.submitter);

  return [...contributors.values()];
}
