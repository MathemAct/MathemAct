#!/usr/bin/env node
/**
 * Fill data/ with fixture content, for looking at a populated opinions section locally.
 *
 *   node scripts/dev-seed.mjs          # write the fixtures
 *   git checkout -- 'data/*.json'      # put the real export back
 *
 * ── Read this before running it ─────────────────────────────────────────────────────
 *
 * **`data/` is the published corpus.** It is committed, it is the citable CC BY dataset, and
 * `data/README.md` tells people to cite it by the `exportedAt` in the manifest. The files this
 * script writes are invented — invented claims, invented positions, invented people — so
 * committing them would publish fabricated research conduct under a licence that invites reuse.
 *
 * Nothing here is destructive: `data/*.json` is tracked, so everything this overwrites is one
 * `git checkout` away. But it will show up as a diff, and it must not be committed. Every
 * fixture profile is marked `isPseudonym` and every fixture id starts `dddd`/`eeee`/`ffff` so a
 * row from this script is recognisable at a glance.
 *
 * ── What this can and cannot show you ───────────────────────────────────────────────
 *
 * Seedable, because it is read from `data/` at build time:
 *
 *   /opinions/            the sparkline on each card, the statistics line, all five orderings,
 *                        the area and subject-area filters, the empty and ineligible states
 *   /opinions/<id>/       the whole contributions section — twelve position groups, both views,
 *                        sorting, the movement badge on a superseded contribution, endorsement
 *                        counts, a soft-deleted contribution, the off-scale group
 *
 * **Not seedable: the histogram on a claim page.** That is a live query against
 * `public.claim_ratings`, deliberately — the distribution is withheld until the reader has
 * answered, so it is fetched rather than built into the page, or hiding it would be a decoration
 * that view-source defeats. No amount of static data will populate it, and the endorsement
 * buttons and the writing box are gated behind the same fetch because they need to know the
 * reader has answered.
 *
 * To see those, the database needs this branch's migrations:
 *
 *   supabase link --project-ref fgnmafmzracdytpfqpel && supabase db push
 *
 * ── The numbers ─────────────────────────────────────────────────────────────────────
 *
 * Every aggregate below is **computed from its histogram** by the same formulas
 * scripts/export.mjs uses, rather than typed in beside it. A fixture whose median disagreed
 * with its own bars would make the page look broken in a way the page was not.
 */
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const OUT = process.argv.includes('--out')
  ? process.argv[process.argv.indexOf('--out') + 1]
  : 'data';

// ── The people ────────────────────────────────────────────────────────────────────────
// All pseudonymous, which is both the honest label for invented contributors and a reminder of
// why the badge rules matter: several of these carry an institution that the contributions
// section deliberately does not render.

const REAL_AUTHOR = {
  id: 'acef3dbd-202c-47fa-806a-3c32522f315e',
  displayName: 'Anna Zanoli',
  isPseudonym: false,
  bio: null,
  institution: {
    name: 'Institute of Science and Technology Austria',
    country: 'Austria',
    verifiedAt: '2026-08-17T10:39:33.352Z',
  },
  createdAt: '2026-08-17T10:20:00.000Z',
};

const CAST = [
  ['dddd0000-0000-0000-0000-000000000001', 'A. Kowalski', 'Adam Mickiewicz University', 'Poland'],
  ['dddd0000-0000-0000-0000-000000000002', 'R. Venkataraman', 'Tata Institute of Fundamental Research', 'India'],
  ['dddd0000-0000-0000-0000-000000000003', 'M. Lindqvist', 'KTH Royal Institute of Technology', 'Sweden'],
  ['dddd0000-0000-0000-0000-000000000004', 'J. Okonkwo', null, null],
  ['dddd0000-0000-0000-0000-000000000005', 'C. Beaumont', 'École Normale Supérieure', 'France'],
  ['dddd0000-0000-0000-0000-000000000006', 'S. Halvorsen', 'Universitetet i Oslo', 'Norway'],
  ['dddd0000-0000-0000-0000-000000000007', 'T. Bianchi', 'Scuola Normale Superiore', 'Italy'],
].map(([id, displayName, name, country]) => ({
  id,
  displayName,
  isPseudonym: true,
  bio: null,
  institution: name
    ? { name, country, verifiedAt: '2026-08-19T09:00:00.000Z' }
    : null,
  createdAt: '2026-08-18T09:00:00.000Z',
}));

const who = (n) => {
  const p = CAST[n];
  return { id: p.id, displayName: p.displayName, isPseudonym: p.isPseudonym, institution: p.institution };
};

// ── The aggregate maths, borrowed from scripts/export.mjs ──────────────────────────────
// Same definitions, so a fixture card and a real one cannot disagree about what "divided"
// means. See the export for why each is shaped the way it is.

const SORTABLE_MINIMUM = 10;
const round3 = (v) => Math.round(v * 1000) / 1000;

function aggregate({ claimId, histogram, noOpinionCount, contributionCount, positionChanges, lastActivityAt }) {
  const scored = histogram.reduce((a, b) => a + b, 0);
  const totalRaters = scored + noOpinionCount;

  // percentile_disc: the value somebody actually chose, never an interpolation.
  let median = null;
  if (scored > 0) {
    let seen = 0;
    const at = Math.ceil(scored / 2);
    for (let i = 0; i <= 10; i += 1) {
      seen += histogram[i];
      if (seen >= at) { median = i; break; }
    }
  }

  const total = histogram.reduce((sum, n, i) => sum + n * i, 0);
  const mean = scored > 0 ? Math.round((total / scored) * 100) / 100 : null;

  const band = (from, to) => histogram.slice(from, to + 1).reduce((a, b) => a + b, 0);

  let divided = null;
  let consensus = null;
  if (scored >= SORTABLE_MINIMUM) {
    // Twice the smaller side, with the neutral 5s in the denominator and in neither numerator.
    divided = round3(2 * Math.min(band(0, 4) / scored, band(6, 10) / scored));
    consensus = round3(
      Math.max(band(0, 1), band(2, 4), band(5, 5), band(6, 8), band(9, 10)) / scored,
    );
  }

  return {
    claimId,
    histogram,
    median,
    mean,
    totalRaters,
    opinionCount: scored,
    noOpinionCount,
    coverage: totalRaters > 0 ? round3(scored / totalRaters) : null,
    contributionCount,
    positionChanges,
    divided,
    consensus,
    sortableMinimum: SORTABLE_MINIMUM,
    lastActivityAt,
  };
}

// ── The claims ────────────────────────────────────────────────────────────────────────
// Three, chosen so the listing has something to sort and something to refuse to sort:
// one genuinely divided, one near-unanimous, and one below the ten-position threshold.

const READING = 'e5b0335c-06eb-47d0-a515-f8d080c021b7';
const PROOFS = 'eeee0000-0000-0000-0000-000000000001';
const DISCLOSE = 'eeee0000-0000-0000-0000-000000000002';

const claims = [
  {
    id: DISCLOSE,
    statement: 'A preprint whose literature search was done by a model should say so.',
    rationale:
      'Disclosure costs a sentence. The counter-argument is that nobody discloses which search engine they used, and it is not obvious where the line is.',
    status: 'active',
    area: 'writing',
    createdAt: '2026-08-21T14:02:00.000Z',
    activatedAt: null,
    tags: [{ code: 'math.HO', label: 'History and Overview' }],
    sourceUrl: 'https://arxiv.org/abs/2508.00000',
    sourceReportId: null,
    author: who(4),
  },
  {
    id: PROOFS,
    statement: 'Every AI-generated proof step must be checked by a human before publication.',
    rationale:
      'Almost nobody disagrees with this stated baldly, which is itself the finding — the disagreement is about what counts as checking.',
    status: 'active',
    area: 'research',
    createdAt: '2026-08-19T08:30:00.000Z',
    activatedAt: null,
    tags: [
      { code: 'math.LO', label: 'Logic' },
      { code: 'math.NT', label: 'Number Theory' },
    ],
    sourceUrl: null,
    sourceReportId: null,
    author: who(0),
  },
  {
    // The real row, kept: same id, statement, area and author, so a rating already cast against
    // it in the database still lines up with the page.
    id: READING,
    statement: 'AI is exceptional as a reading assistant.',
    rationale:
      'Sometimes people do not trust AI a priori. Reading papers is a good testing ground for the value of the models, as it is supposed to be easy to verify if the produced answers are correct.',
    status: 'active',
    area: 'learning',
    createdAt: '2026-08-17T10:30:51.526Z',
    activatedAt: '2026-08-18T10:11:31.152Z',
    tags: [
      { code: 'math.HO', label: 'History and Overview' },
      { code: 'math.AG', label: 'Algebraic Geometry' },
    ],
    sourceUrl: null,
    sourceReportId: null,
    author: { id: REAL_AUTHOR.id, displayName: REAL_AUTHOR.displayName, isPseudonym: false },
  },
];

// ── The contributions ─────────────────────────────────────────────────────────────────
// Spread across the scale on purpose, including the off-scale group, a soft-deleted one, and a
// superseded pair — somebody who moved from 2 to 9 and wrote again, which is the movement badge
// and the one event this section exists to make visible.

const MOVED_FROM = 'ffff0000-0000-0000-0000-000000000003';
const MOVED_TO = 'ffff0000-0000-0000-0000-000000000008';

const contribution = (id, parentId, n, score, body, at, extra = {}) => ({
  id,
  parentType: 'claim',
  parentId,
  inReplyTo: null,
  body,
  createdAt: at,
  updatedAt: at,
  deletedAt: null,
  agreementScore: score,
  supersededBy: null,
  supersedesEarlier: false,
  endorsedAt: null,
  endorsements: { capturesMyView: 0, agreePositionNotReason: 0 },
  author: n === null ? null : who(n),
  ...extra,
});

const comments = [
  contribution(
    'ffff0000-0000-0000-0000-000000000001', READING, 0, 1,
    'It is exceptional at producing text that reads like a summary. Twice now it has told me a paper proves a converse it explicitly disclaims in the introduction, and both times the prose was fluent enough that I only caught it because I already knew the result.',
    '2026-08-18T11:04:00.000Z',
    { endorsedAt: '2026-08-19T07:12:00.000Z', endorsements: { capturesMyView: 6, agreePositionNotReason: 2 } },
  ),
  contribution(
    'ffff0000-0000-0000-0000-000000000002', READING, 1, 2,
    'The claim conflates two things: reading a paper in your own area, where you can check every sentence cheaply, and reading one outside it, where you cannot. It is useful for the first and dangerous for the second, and the second is where people actually reach for it.',
    '2026-08-18T13:20:00.000Z',
    { endorsements: { capturesMyView: 4, agreePositionNotReason: 1 } },
  ),
  contribution(
    MOVED_FROM, READING, 2, 2,
    'I would want to see this tested on a paper whose main lemma is wrong. My guess is that it summarises the wrong lemma just as confidently.',
    '2026-08-18T15:40:00.000Z',
    { supersededBy: MOVED_TO, endorsements: { capturesMyView: 1, agreePositionNotReason: 0 } },
  ),
  contribution(
    'ffff0000-0000-0000-0000-000000000004', READING, 3, 5,
    'Neither, on the evidence so far. It is very good at telling me which of forty papers to open and close to useless at telling me what is in the one I opened.',
    '2026-08-19T09:15:00.000Z',
    { endorsements: { capturesMyView: 3, agreePositionNotReason: 0 } },
  ),
  contribution(
    'ffff0000-0000-0000-0000-000000000005', READING, 5, 8,
    'For orientation in an unfamiliar area it has saved me weeks. I do not ask it whether a proof is correct; I ask it which of these six papers is the one that introduced the technique, and it is right about that far more often than a search engine is.',
    '2026-08-19T10:02:00.000Z',
    { endorsedAt: '2026-08-19T16:00:00.000Z', endorsements: { capturesMyView: 9, agreePositionNotReason: 3 } },
  ),
  contribution(
    'ffff0000-0000-0000-0000-000000000006', READING, 6, 8,
    'Agreed on the conclusion, and I would put it differently: it is exceptional as an index, not as a reader. The word "reading" is carrying more than the evidence supports.',
    '2026-08-19T12:30:00.000Z',
    { endorsements: { capturesMyView: 2, agreePositionNotReason: 5 } },
  ),
  // Soft-deleted, and it **keeps its position**: deletion empties the body and strips the name,
  // and nothing else. Its score is part of what the distribution is made of, so it stays in the
  // group it was written from rather than falling off the scale — which is what the first draft
  // of this fixture got wrong, filing it under "no opinion" and inventing a view for somebody
  // who had withdrawn theirs.
  contribution(
    'ffff0000-0000-0000-0000-000000000007', READING, null, 7,
    '',
    '2026-08-19T14:00:00.000Z',
    { deletedAt: '2026-08-20T08:00:00.000Z' },
  ),
  contribution(
    MOVED_TO, READING, 2, 9,
    'I ran the test I asked for above, on a preprint with a known gap in Lemma 3.2. It found the gap, unprompted, and described it correctly. That is not what I expected and it has moved me a long way.',
    '2026-08-20T11:45:00.000Z',
    { supersedesEarlier: true, endorsedAt: '2026-08-20T18:20:00.000Z', endorsements: { capturesMyView: 11, agreePositionNotReason: 1 } },
  ),
  contribution(
    'ffff0000-0000-0000-0000-000000000009', READING, 4, null,
    'I have no way to judge this. I read almost entirely in my own area, where the marginal value of a summary is close to zero, so my answer would be about my habits rather than about the tools.',
    '2026-08-20T13:10:00.000Z',
    { endorsements: { capturesMyView: 4, agreePositionNotReason: 0 } },
  ),
  contribution(
    'ffff0000-0000-0000-0000-000000000010', READING, 3, 10,
    'Exceptional is the right word and I would not hedge it. Three months ago I would have answered 3.',
    '2026-08-21T09:00:00.000Z',
    { endorsements: { capturesMyView: 2, agreePositionNotReason: 0 } },
  ),
  contribution(
    'ffff0000-0000-0000-0000-000000000011', PROOFS, 1, 9,
    'The disagreement is entirely about "checked". A human reading a Lean proof they cannot follow has not checked it, and a human who re-derived the step by hand did not need the model.',
    '2026-08-19T11:00:00.000Z',
    { endorsements: { capturesMyView: 8, agreePositionNotReason: 0 } },
  ),
  contribution(
    'ffff0000-0000-0000-0000-000000000012', PROOFS, 6, 10,
    'Yes, and the interesting question is who is accountable when it is not done. The referee cannot check what the author did not disclose.',
    '2026-08-20T09:30:00.000Z',
    { endorsements: { capturesMyView: 5, agreePositionNotReason: 1 } },
  ),
];

// ── Aggregates, computed from the bars ────────────────────────────────────────────────

const countFor = (id) => comments.filter((c) => c.parentId === id).length;

const aggregates = [
  aggregate({
    claimId: READING,
    //         0  1  2  3  4  5  6  7  8  9 10
    histogram: [2, 3, 5, 2, 1, 1, 1, 2, 6, 4, 2],
    noOpinionCount: 4,
    contributionCount: countFor(READING),
    positionChanges: 3,
    lastActivityAt: '2026-08-21T09:00:00.000Z',
  }),
  aggregate({
    claimId: PROOFS,
    histogram: [0, 0, 0, 0, 0, 0, 0, 1, 3, 8, 9],
    noOpinionCount: 1,
    contributionCount: countFor(PROOFS),
    positionChanges: 1,
    lastActivityAt: '2026-08-20T09:30:00.000Z',
  }),
  aggregate({
    // Below the threshold, so `divided` and `consensus` come out null and the card renders no
    // sparkline-driven ordering — the state a brand-new claim is in.
    claimId: DISCLOSE,
    histogram: [0, 0, 0, 0, 0, 0, 2, 0, 1, 0, 0],
    noOpinionCount: 1,
    contributionCount: countFor(DISCLOSE),
    positionChanges: 0,
    lastActivityAt: '2026-08-21T14:02:00.000Z',
  }),
];

// ── Write ─────────────────────────────────────────────────────────────────────────────

const files = new Map([
  ['claims.json', claims],
  ['claim-ratings.json', aggregates],
  ['comments.json', comments],
  ['profiles.json', [REAL_AUTHOR, ...CAST]],
]);

const out = path.resolve(OUT);
await mkdir(out, { recursive: true });

const manifest = {
  exportedAt: new Date().toISOString(),
  formatVersion: 2,
  generator: 'scripts/dev-seed.mjs — FIXTURES, NOT A REAL EXPORT. Do not commit.',
  licence: 'CC BY 4.0',
  licenceUrl: 'https://creativecommons.org/licenses/by/4.0/',
  files: {},
};

for (const [name, rows] of files) {
  const body = `${JSON.stringify(rows, null, 2)}\n`;
  await writeFile(path.join(out, name), body, 'utf8');
  manifest.files[name] = { rows: rows.length, bytes: Buffer.byteLength(body) };
}

// The listing's freshness overlay asks the database for rows newer than this. Dated in the past
// so the fixtures are not treated as "already seen" against a live database that has none of
// them.
manifest.exportedAt = '2026-08-21T20:00:00.000Z';
await writeFile(path.join(out, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');

const a = aggregates[0];
console.log(`Wrote fixtures to ${OUT}/`);
console.log(`  ${claims.length} claims, ${comments.length} contributions, ${files.get('profiles.json').length} profiles`);
console.log(`  "${claims[2].statement}" — median ${a.median}, mean ${a.mean}, divided ${a.divided}, consensus ${a.consensus}`);
console.log('');
console.log('These are invented. data/ is the published CC BY dataset — do not commit them.');
console.log("Undo with:  git checkout -- 'data/*.json'");
console.log('');
console.log('The histogram on a claim page is a live query and will stay empty until the');
console.log('branch migrations are applied. Everything else on the page is built from these files.');
