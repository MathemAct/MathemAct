# MathemAct

*Collectively shaping the future of mathematical research in the age of AI.*

A platform for the mathematics research community to collect **structured, first-hand
accounts of how AI tools are actually used in mathematical work** — and to record where
the community agrees and disagrees about how they should be used.

The Leiden Declaration on AI and Mathematics supplies the principles, including its call
for a "Tool and computational resource disclosure" section in papers. MathemAct is the
reporting layer underneath: a corpus concrete and well-structured enough that journals
could adopt its posting schema as a disclosure template.

Two consequences worth stating up front. **Failures are first-class content** — a corpus
of only successes is worthless and reads as advertising. And **the corpus is
machine-readable and downloadable**, because researchers studying AI adoption in
mathematics are part of the intended audience.

## Stack

| Layer | Choice |
|---|---|
| Site generator | Astro, static output |
| Hosting | GitHub Pages via GitHub Actions |
| Database + auth | Supabase (free tier, EU region) |
| Auth method | Email + password, mandatory email confirmation |
| Transactional email | Brevo SMTP relay |
| Bot defence | Cloudflare Turnstile, verified by Supabase Auth |
| Math rendering | KaTeX, at build time, and in the browser for what was written since |
| Full-text search | Pagefind, over built HTML |
| Institution data | ROR, CC0 dump loaded into Postgres — see [docs/ror.md](docs/ror.md) |

### The one architectural rule

**Reads are served statically. The database handles writes and auth only.**

A workflow exports published content to JSON committed to [`data/`](data/), and the
site builds from those files. The database asks for that workflow within a minute of any write,
so a change reaches every page in about two minutes; see
[the decision](docs/decisions.md) "The site rebuilds when its content changes". The files are
still the only source a build reads — there is no fallback to a live query, so a build reads files
or reads nothing. Browsers only talk to Supabase when someone logs in, submits, comments,
votes, or confirms a report. A traffic spike therefore never touches the egress quota, and
reading still works if the database is paused or over quota.

The one read a browser makes is the freshness overlay: a listing hydrates from the static
page and then asks, once and with a cap, whether anything has been posted since the export.
Claim and report pages ask the same of their comments, and patch in edits and deletions as
well as new ones. Either way it fails silently, because the page is already correct without
it. Anything the overlay or the writer adds is set in the browser by the build's own markdown
pipeline, loaded only when there is something to set.

Anything the overlay surfaces has no static page yet, so it links to a client-rendered view
page — `/reports/view/`, `/opinions/view/`, `/authors/view/` — which fetches the row at
runtime and hands over to the real page once a build has made it. A view page only ever links to
other view pages: it exists precisely when the export cannot be trusted to contain the rows,
so a link out of it into a generated page would be a 404 one level down. The governing rule
is that **a page exists exactly where a link to it exists**, which is why an author page
covers report authors, claim authors, and entry submitters — everyone whose name
is a link — and why comment authors, whose names are not links, have none.

That same job is the backup, the citable CC BY dataset, and — because a free Supabase project
pauses after about a week without a connection — the keep-alive, which is why it also runs every
night whether or not anything changed.

### Moderation and suspensions

Nothing is reviewed before it appears. A reader flags something, a moderator decides whether it
stays up, and the explanation they write is stored once and read by the author and the flagger
both — never naming the moderator or the flagger. The audit log is separate, append-only, and
moderators-only. Everything goes through one `SECURITY DEFINER` function, `public.moderate()`;
there are no moderator `UPDATE` policies on any content table, so a direct write bypassing the
log silently changes nothing.

**Suspending an account** is the second kind of decision — about a person rather than a post,
for spam or sustained hostility. It sets `profiles.is_banned`, which closes nine insert
policies (reports, claims, network entries, comments, ratings, confirmations, flags,
citations, endorsements) and nothing else:

- **Not a lockout.** Sign-in, reading, profile edits, password changes and erasure requests all
  still work. `auth.users` is untouched. An account somebody could not leave would be a
  data-protection problem, not a moderation tool.
- **Not a content removal.** Everything already posted stays published under CC BY with its
  name and badge. Hiding a post is a separate decision with its own audit row and explanation.
  There is deliberately no bulk "ban and hide everything" — thirty notices to one person turns
  an explanation into a mailshot.
- **Not permanent.** `unban` is its own decision with its own explanation, reachable from the
  banned list on `/moderate/`.
- **Not public.** [scripts/export.mjs](scripts/export.mjs) refuses `profiles.is_banned`
  alongside `profiles.role`, so no page built from `data/` can render a suspension marker, and
  none does. It is visible only on `/moderate/`.
- **Not emailed.** The notice, the banner on `/account/` and the activity line are all on-site,
  so a suspended account that never returns is never told. That is the one significant gap and
  it is stated as such in the code of conduct rather than glossed.

`public.moderate()` refuses a self-ban, a ban of anybody with moderation standing, a second ban
of an already-banned account, and any of it without a written reason.

Full runbook in [docs/moderation.md](docs/moderation.md); the user-facing version is on the
[code of conduct page](src/pages/code-of-conduct.astro).

### Identity, in one paragraph

Two tiers: Registered, and Institutional on top of it. Affiliation is never claimed — it
is derived from the confirmed email domain, matched against ROR by a `SECURITY DEFINER`
trigger. **There is no request shape that carries an affiliation from a browser into the
database.** Those columns have no `UPDATE` grant *and* are reverted by a `BEFORE UPDATE`
trigger, and the pgTAP suite proves both by widening the grant itself and trying anyway.
The email address is never displayed, never returned by the API, never exported, and never
shown to moderators.

### Accounts

Email and password with mandatory confirmation, Cloudflare Turnstile on the four pages that
send mail or take a password, and no account enumeration anywhere — sign-in gives one
message for a wrong password and an unknown address, and the reset confirmation is phrased
conditionally on purpose.

All of it is client-side, because there is no server. `src/lib/auth.ts` holds every
operation and returns finished prose rather than error objects; `src/lib/session.ts` is a
four-state store where "signed out" and "we cannot tell you" are different answers. The
header does **not** load any of this — it guesses from `localStorage`, so a reading page
ships 240 bytes of JavaScript and never touches Supabase.

Dashboard configuration — redirect URLs, CAPTCHA, SMTP, and rewritten email templates —
is in [docs/auth.md](docs/auth.md). None of it is in this repository, which is where the
secrets are not.

## Local development

Requires **Node 22.19 or newer**.

```sh
npm install
cp .env.example .env     # then fill in the two blank values
npm run dev              # http://localhost:4321/MathemAct/
npm run build            # writes dist/
npm run preview          # serves dist/
npm run check            # Astro + TypeScript diagnostics
```

Note the `/MathemAct/` path in the dev URL. The site is a GitHub Pages project site, so
it is served under a path prefix, and `astro dev` reproduces that. **Never hardcode
internal paths** — build them with `path()` or `asset()` from
[src/lib/paths.ts](src/lib/paths.ts).

### Environment variables

The three `PUBLIC_*` variables in [.env.example](.env.example) are public by design and
ship to the browser. The Supabase service role key, the Brevo SMTP key, and the Turnstile
secret key must never appear in this repository — that file documents where each of them
actually lives.

### Database migrations

Plain SQL in `supabase/migrations/`, applied in order by the Supabase CLI. **Append-only:
never edit an applied migration, add a new one.**

```sh
supabase login
supabase link --project-ref fgnmafmzracdytpfqpel
supabase db push          # apply to the remote database
supabase start            # full local stack in Docker
supabase test db          # run the pgTAP suite against it
```

Pushing to `main` with changes under `supabase/migrations/` applies them via
[.github/workflows/migrate.yml](.github/workflows/migrate.yml), which then reports the
Security Advisor findings and asserts that nothing in the `private` schema is executable by
a browser role.

**Branch first for anything touching the database.** `test-db.yml` runs on branches and
pull requests; `migrate.yml` runs only on `main`. So the suite is a gate in front of
production rather than a report after it.

### Database tests

730 pgTAP assertions across twenty-eight files in `supabase/tests/`, covering domain matching, the
API surface, badge derivation, write protection, matching precedence, what signup metadata
is allowed to set, who may file or read an erasure request, every report policy from both
directions, the constraints that make a report structured rather than a paragraph, the
tombstone rule, the rate limits, the submission RPC, the agreement scale, every comment
policy including the nesting limit and what soft deletion destroys, the citation and
flag queues, the activity feed and its backfill, account bans — the nine write paths a
ban closes, asserted one by one, and the notice it sends — contributions on claims: the position
each was written from and that it survives its author changing their mind, flatness on claims
against threading on reports, endorsement and who may not, the edit window closing on the first
endorsement, supersession, and a rating history no browser role can read — and schema version 2
of a report:
the two widened vocabularies, the secondary task types and how they are normalised, the
supporting links and every URL they refuse, the five scales and the two bounds on each, the
ordered `time_saved` vocabulary that replaced a sixth scale, the guard's freeze list, reached
by the one route that gets past the policy, and the column grants on the two columns this
version retyped — which are per column, so a `drop column` silently revokes one. And the two
confirmation questions: that a report which did not work is asked whether it still does not, that
a verdict from the other pair is refused on either table, that a reproduced failure fills the
tombstone, and that a frozen report still answers an outcome change with the silent revert rather
than an exception — which is a trigger's *name* being asserted, since alphabetical firing order is
the only thing holding that apart. And answering a claim: that a scored first answer without an
endorsement or a contribution is refused at commit, that either one satisfies the rule, that "no
opinion", the proposer and a score-to-score change are exempt while "no opinion" to a score is
not, and that a refused endorsement takes the position written before it down with it. And
rebuilding on write: that every table the export reads moves the counter, for a browser role too,
that without a token nothing is asked for and the change stays owed, and that with one exactly one
request goes to the export workflow however many times the dispatcher runs. And the rename of
*Debates* to *Opinions*: that no table, column, constraint, trigger, policy, function, type, enum
label, function body or object comment still says "debate", so a later migration cannot bring
the word back.

Every policy is asserted from both sides. A test that only checks the allowed case proves
the feature works and says nothing about whether it is a door.

They run in CI rather than locally, because the primary development machine is a managed
Windows laptop where WSL is blocked by group policy — there is no container runtime, so
`supabase start` cannot run at all. That turned out to be the better home for them: they
now gate every change rather than depending on someone remembering.

### Loading ROR

```sh
node scripts/load-ror.mjs path/to/ror-data.json --dry-run   # no database needed
```

Full instructions, the licence, the refresh cadence, and the domain-coverage caveats are in
[docs/ror.md](docs/ror.md). `ror-verify.yml` loads the current release into a throwaway
database monthly and reports what the matcher makes of real mathematics institutes.

## Repository layout

```
src/pages/              home, about, privacy, code of conduct, search, 404
src/pages/account/      sign up, confirm, sign in, sign out, reset, password, profile, erase,
                        activity, moderation decisions, and editing a report you may still edit
src/pages/reports/      the listing, a report, the submission form
src/pages/authors/      one contributor's reports, claims, and submitted entries
src/pages/opinions/     the index, a claim, and the suggest form
src/pages/debates/      redirect stubs for the section's old addresses, query and fragment kept
src/pages/network/      the listing and the submission form
src/pages/moderate/     open flags, what is hidden, accounts (search, ban, unban), and erasure
                        requests; ships as the 404 page and reveals itself to a moderator
*/view.astro            client-rendered stand-ins for pages the last export predates
src/components/         Tombstone, Markdown, Badges, Field, FormStatus, Turnstile
src/layouts/            Base (shell), Page (long-form prose), Account (forms + session gate)
src/lib/                paths, site constants, status vocabulary, markdown, auth, session,
                        session-hint (sign-in localStorage guess), mod-hint (moderator
                        localStorage guess), profile queries, validation, formatting,
                        form helpers, the corpus readers (reports, claims,
                        entries), authors (who gets a page), fresh (the overlay)
src/styles/             tokens.css (single source of truth), base.css, forms.css
public/fonts/           self-hosted IBM Plex woff2 + the @font-face that loads them
data/                   the committed export the site builds from, plus the CSV dataset
                        and a README describing both
supabase/migrations/    numbered SQL, applied in order, append-only
supabase/tests/         pgTAP: RLS, grants, triggers, matching
scripts/load-ror.mjs    streams the ROR dump into the private schema
scripts/export.mjs      writes data/ from the database; the whole read path
scripts/dev-seed.mjs    fills data/ with fixtures for looking at a populated site
                        locally. Never committed: data/ is the published dataset
.github/workflows/      deploy, migrate, test-db, ror-verify, auth-config, export,
                        link-check, embed
docs/                   decisions log, ROR notes, auth runbook, moderation runbook,
                        code of conduct
```

Non-obvious choices are recorded in [docs/decisions.md](docs/decisions.md), including the
ones that turned out to be wrong — superseded entries are marked rather than deleted.

## Licence

Content contributed to MathemAct — reports, claims, comments, and the exported
dataset — is published under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Contributors retain copyright
and are credited; reuse requires attribution.
