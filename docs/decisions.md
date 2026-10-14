# Decisions

One entry per non-obvious choice: what was decided, and the reasoning that would otherwise
have to be reconstructed. Append; do not rewrite history. If a decision is reversed, add a
new entry saying so and leave the old one standing.

---

## 2026-08-13 — Astro as the site generator

Static output is a hard requirement (GitHub Pages, no application server), and the site is
overwhelmingly content: report pages, debate pages, listings. Astro ships zero JavaScript by
default and lets the few genuinely interactive parts — the submission form, the rating widget,
the auth flow — opt in individually. That default matters for this audience specifically: pages
are read on institutional networks and old hardware, and a corpus meant to be citable for years
should not depend on a client-side framework to render its own text.

Rejected: Next.js and SvelteKit, whose static export modes are a supported side path rather
than the primary one. Rejected: a bare static site generator with no component model, because
the report page is a dense, repeated, structured layout and building it from string templates
would not survive contact with a dozen field types.

## 2026-08-13 — Reads are static; the database serves writes and auth only

A nightly job exports published content and rating aggregates to JSON committed to `data/`, and
the site builds from those files. Browsers reach Supabase only to log in, submit, comment,
rate, or confirm a report.

This is what makes the free tier viable in production rather than merely cheap:

- A traffic spike — the realistic scenario being a link circulating on a mailing list — never
  touches the 5 GB egress quota, because reads never reach the database.
- Reading still works when the database is paused, over quota, or down. The site degrades to
  read-only instead of to a blank page.
- The export doubles as the backup the free tier does not provide, *and* as the citable
  machine-readable dataset the project owes its researcher audience. One job, three jobs done.
- The job's own nightly activity prevents the free tier's ~1 week inactivity pause.

Cost: content is up to a day stale. Mitigated by a freshness overlay — listing pages render
from static JSON, then make one background query for rows newer than the build timestamp and
prepend them. When the database is unreachable the overlay fails silently and the static
content stands, which is the correct failure mode.

*Since 2026-10-11 the export also runs within a minute of any write, so content is minutes stale
rather than up to a day. See "The site rebuilds when its content changes".*

## 2026-08-13 — Supabase, chosen for the exit and not for the free tier

Supabase is real Postgres and is open source. The exit is `pg_dump` to any other Postgres host,
and the worst case is self-hosting the same components. No proprietary query language, no
proprietary schema format.

The corollary is a standing constraint: **keep logic in Postgres.** Constraints, triggers, RLS
policies, plain SQL. Anything expressed in a vendor-specific layer — Edge Functions in
particular — makes that exit more expensive and should be avoided unless something genuinely
needs an outbound network call at request time.

The free tier's limits (500 MB database, 5 GB egress, no backups, no SLA, pause after
inactivity) shaped the read/write split above rather than the choice of vendor.

## 2026-08-13 — EU region, and why it is load-bearing

The project's users are professional mathematicians, skewed European, working at institutions
with data protection offices that read privacy notices. Personal data processed here — email
addresses, which are additionally never displayed or exported — stays in the EU, so the privacy
notice can say so without qualification.

Two operational consequences: (1) **The region is irreversible.** Changing it means creating a
new project and migrating. (2) It constrains every future service choice: a processor that
cannot keep EU data in the EU is disqualified.

Processors to disclose: Supabase (database, auth), Brevo (transactional email), Cloudflare
(Turnstile), GitHub (hosting).

## 2026-08-13 — The Supabase GitHub integration is not used

Its headline feature is database branching, which is billed per branch-hour and violates the
zero-budget constraint outright. Migrations are plain SQL in `supabase/migrations/`, applied by
the Supabase CLI from `.github/workflows/migrate.yml`, which is the portable path and the same
command a developer runs locally.

## 2026-08-13 — Served at mathemact.github.io/MathemAct/, no custom domain

A domain costs money. The cost is a `/MathemAct` path prefix, held in `base: '/MathemAct'` in
`astro.config.mjs` and in `path()`/`asset()` in `src/lib/paths.ts`. Reversal: set `site` and
`base: '/'`, add `public/CNAME`, configure DNS.

`trailingSlash: 'always'` so GitHub Pages serves `index.html` directly without a 301. `path()`
enforces the trailing slash; `asset()` does not, because a trailing slash on a filename names a
non-existent resource.

## 2026-08-13 — GitHub Actions pinned to commit SHAs

Every third-party action is pinned to a full commit SHA with the version in a trailing comment.
A tag is a mutable pointer: whoever controls the action's repository can move `v5` to different
code, and that code would run with this repository's `pages: write` permission and, in the
migration workflow, with a connection string to the live database. A SHA cannot be moved. The
cost — updates are manual and visible in review — is the right trade for a workflow that can
write to production.

## 2026-08-13 — The three public keys are Actions variables, not secrets

`PUBLIC_SUPABASE_URL`, `PUBLIC_SUPABASE_ANON_KEY`, and `PUBLIC_TURNSTILE_SITE_KEY` are stored
as repository **variables**. Astro inlines any `PUBLIC_`-prefixed value into the built JavaScript,
so all three are readable by anyone viewing source on the deployed site. Storing them as secrets
would not hide them from anyone; it would only mask them in CI logs and imply that leaking one is
an incident. It is not — the anon key identifies the anonymous *role*, and RLS is what decides
what that role can do. This split also makes the genuine secrets easier to police: anything in
the secrets list is something whose exposure *is* an incident.

## 2026-08-13 — The migration workflow warns rather than fails when secrets are absent

`migrate.yml` checks whether `SUPABASE_DB_URL` and `SUPABASE_ACCESS_TOKEN` are set and, if not,
emits a GitHub warning annotation and skips the push instead of erroring. The alternative failure
mode is worse: a red X on a workflow that was never configured trains the maintainer to ignore
red X marks, which is how a real migration failure gets missed. The check compares each secret to
the empty string inside an expression, which yields a plain boolean and exposes nothing.

## 2026-08-13 — `compressHTML: false`

Astro's HTML compressor deletes whitespace between a text node and an adjacent inline element
rather than collapsing it, producing `licensedCC BY 4.0`. Keeping the source correct by hand is
not a fix because the editor's formatter re-wraps long lines on save and reintroduces it. Turning
the compressor off removes the failure mode entirely; the output is a few hundred bytes larger
before compression and near-identical after gzip.

## 2026-08-13 — The font stylesheet lives in `public/`, not `src/styles/`

CSS cannot call `path()`, and the site is served under a `/MathemAct` prefix. Putting `fonts.css`
next to the woff2 files means every `src` is a bare filename resolved against the stylesheet's
own URL — correct under any base and surviving a move to a custom domain untouched. Fourteen
files: seven faces, each as a latin and a latin-ext subset, with real `unicode-range` values so
latin-ext is fetched only when a page contains a character in it (Erdős, Poincaré, Ważewski, and
Lindelöf all live there).

## 2026-08-13 — Markdown is sanitised *before* KaTeX renders, not after

Sanitising after KaTeX would mean allowlisting KaTeX's output — dozens of layout classes on
nested spans plus a parallel MathML tree — which in practice means allowing arbitrary spans and
classes and giving up most of what the sanitiser was for. Sanitising first is sufficient: by the
time KaTeX runs, all that survives of a formula is its TeX source as a text node, and KaTeX
escapes what it renders.

Three independent defences:

1. `remark-rehype` is called without `allowDangerousHtml`, so raw HTML is discarded before the
   sanitiser sees it.
2. `rehype-sanitize` runs on the untrusted input, with the default schema extended in exactly one
   respect: `math-inline` and `math-display` are allowed as class *values* on span and div,
   because `rehype-katex` finds formulas by that class.
3. KaTeX runs with `trust: false`, which rejects `\href`, `\url`, `\includegraphics`, and
   `\htmlClass`.

Note: there is no `throwOnError` option — `rehype-katex` always catches parse errors itself,
rendering the offending source in a `.katex-error` span. One malformed formula must not fail the
build.

## 2026-08-13 — Outcome colours go on the tombstone glyph, never on the label

The rule is uniform regardless of contrast ratios: the outcome colour sets the square and the
text label stays in ink. As a graphic the square only needs 3:1; as text the label needs 4.5:1,
which all three colours clear. More importantly, colour must never be the sole carrier of
meaning, so the words should be the primary signal and the colour a secondary cue. See also the
`--outcome-partial` contrast entry dated 2026-08-21, which corrected a wrong figure.

## 2026-08-13 — Cascade layers for the global stylesheet

`base.css` declares `@layer reset, base, layout` and wraps every reset selector in `:where()`,
so those rules carry zero specificity. Astro's scoped component styles are unlayered, and
unlayered styles beat layered ones regardless of specificity, so a component always wins against
a global default without needing a longer selector or `!important`. The practical effect is that
nobody has to know `base.css` exists in order to style a component correctly.

## 2026-08-14 — The affiliation trigger is SECURITY DEFINER; the guard that protects it is not

`private.protect_profile_columns()` reverts every system-owned column on `public.profiles` and is
deliberately **SECURITY INVOKER**. Inside a DEFINER function `current_user` is the function's
owner, not the caller; a DEFINER guard would conclude every caller was trusted, revert nothing,
and read in review as though it worked. As INVOKER, `current_user` is `authenticated` for a
browser and the table owner when the badge trigger (DEFINER, because it must read the private
schema) performs its update. The trusted set is computed via `pg_has_role` rather than a
hardcoded role name.

## 2026-08-14 — Protection is doubled: column grants and a trigger

`UPDATE` on `public.profiles` is granted per column; the trigger reverts the same columns
regardless. The trigger exists for the day someone writes `grant update on public.profiles to
authenticated` to clear the way for a feature — the pgTAP suite tests exactly that. Institution
columns are reverted for admins too: an admin override would make "verified" mean "an admin said
so", which is not a claim this project can make.

## 2026-08-14 — The badge is re-derived when a confirmed address changes

The trigger also fires on address change; a failed match *clears* the columns. Confirm at a
university, move the account to a personal address, keep the institution forever — the trigger
closes that hole.

## 2026-08-14 — The institution is a snapshot, and has no foreign key

The institution triple is copied at badge issuance and never refreshed. A badge claims "this
address was confirmed at this institution on this date"; rewriting it because ROR renamed a record
makes the claim untrue. No foreign key — CI reloads `private.ror_institutions` wholesale and a
routine refresh must not cascade into anyone's profile.

## 2026-08-14 — Candidate suffixes are enumerated, not matched with LIKE

`private.match_institution()` builds the suffix list of a domain and compares each with equality.
`like '%.' || domain` cannot use an index and this runs on every domain in ROR. The bare TLD is
never a candidate: treating a single-label domain as a match would badge an entire country.

## 2026-08-14 — Database tests run in CI, because they cannot run here

WSL is blocked by group policy (`0x80070569`). `test-db.yml` stands up the full local stack on a
runner — the full stack because the `auth` schema and roles are created by the auth service and
every test depends on at least one. It runs on branches; `migrate.yml` only on `main`, so the
tests gate production.

## 2026-08-14 — What the Security Advisor flags, and why it is accepted

Initial check: three `rls_enabled_no_policy` (INFO) on the three `private` tables (RLS with no
policies is deny-all, the intended design) and two `*_security_definer_function_executable` (WARN)
on `public.rls_auto_enable`, a platform-managed object. `migrate.yml` also asserts the invariant
we control: no function in the `private` schema grants EXECUTE to `anon` or `authenticated`.
Postgres grants EXECUTE to PUBLIC on every new function by default. The baseline grew with new
DEFINER functions; see the 2026-08-15 and 2026-08-16 entries.

## 2026-08-14 — The ROR loader reconciles; it does not only upsert

`scripts/load-ror.mjs` stages the whole dump, upserts, then **deletes rows the dump no longer
contains** in one transaction. A stale row would forever hand out badges for a domain the
institution no longer claims. It refuses a load that would more than halve the table (`--allow-shrink`
overrides). It streams rather than reads the file: the v2.11 dump is 291 MB and `JSON.parse` on
it dies with an allocation failure.

## 2026-08-14 — Three domain layers, and why the simple approach was wrong

A vanity domain nobody sends mail from produces a **useless** derived entry, not a harmful one —
the badge is absent either way. The genuinely dangerous outcome is a derived host that another
record has already curated, and that is precisely detectable. Against ROR v2.11, deriving from
each record's website and accepting only hosts claimed by exactly one record accepts 85,860 and
refuses 752 already-curated hosts, 3,196 shared by two or more, 9 public suffixes, and 49 parents
of three or more curated domains. The headline number: only **41.1%** of active European
`education` records carry a domain in ROR's curated field alone.

A domain comes from one of three layers:

| | |
|---|---|
| `manual` | `private.manual_domains`, added by a human with written evidence |
| `ror_domain` | ROR's curated `domains` field |
| `ror_website` | derived by the loader, unique hosts only |

**Longest suffix wins first; source only breaks ties at equal length.** Correctness (specificity)
comes before authority (trust). The block list overrides everything.

The parent-of-many guard: without it the loader was about to map `min-saude.pt` (the Portuguese
health ministry) to a single hospital whose website is a page on it. Those cases are withheld for
human decision — which is also how the high-value ones are found: `psl.eu`, `kyoto-u.ac.jp`.
`institution_source` is stored and never displayed, so a bad derived domain can be traced to the
badges it issued.

## 2026-08-14 — ORCID was built, tested, and removed

Built as an OAuth link on an existing account, covered by 14 pgTAP assertions, removed for scope
— it needed a dashboard registration and added a fifth data processor for a badge nobody had asked
for. If revived: (1) OAuth only, not a self-declared iD; (2) a link on an existing account, never
a sign-in — ORCID OIDC returns no email claim, so an account created by signing in with ORCID
would have no email, no institutional badge, no password reset; (3) connecting a real-name iD to a
pseudonymous account must be disclosed at the point of the decision. Implementation in git history
at `20260814140000_orcid_verified_by_oauth.sql`.

## 2026-08-14 — Implicit flow rather than PKCE for email links

Under PKCE the code in a confirmation link is worthless without a verifier held in the browser
that started the flow. Our users sign up on a laptop in an office and open their mail on a phone;
under PKCE that produces an error indistinguishable from a broken link for an audience already
inclined to read an unfamiliar automated email as phishing. The cost is not one annoyed person; it
is a signup that never completes.

Under implicit flow the tokens arrive in the URL fragment. A fragment is never sent to any server;
the client strips it from the address bar on arrival; the link is single-use. The residual
exposure — browser history and anything with access to the URL — is smaller than a confirmation
flow that breaks whenever mail is read on a different device.

## 2026-08-14 — The header guesses whether you are signed in

The header is on every page, including the ones people come here to read. Deciding between
"Sign in" and "Account" by asking the real session store would mean loading the Supabase client
on the home page, which is the coupling the read/write split exists to prevent. `src/lib/session-hint.ts`
reads `localStorage` directly, matching Supabase's storage key by shape. Both destinations are
real pages that establish the truth for themselves, so a wrong guess costs a click and never a
broken flow. A rename upstream degrades it to "always signed out", which is the harmless
direction. Measured result: the home page ships 240 bytes of JavaScript and the account pages
ship the client.

## 2026-08-14 — Four session states, not two

"Signed out" and "we cannot tell you" are different facts. `SessionState` has `loading`,
`signed-in`, `signed-out`, and `unavailable` with a reason; `Account.astro` renders each in its
own words. A checkout with an unfilled `.env` builds, deploys, serves every page, and says
"accounts are not switched on for this deployment yet" on the eight pages that need them.

## 2026-08-14 — Erasure is a row, not an email

`public.deletion_requests` is written by an authenticated session; the `user_id` is established
by the session rather than typed into a field. Withdrawing deletes the row outright rather than
marking it cancelled. There is no UPDATE grant and no UPDATE policy — `status` is the operator's
and is unreachable from a browser. Reading is limited to the requester and to admins (not
moderators: erasure is an account action, not a content action).

## 2026-08-14 — Signup metadata is read for exactly two keys

`private.handle_new_user()` reads `display_name` and `is_pseudonym` and nothing else. A version
that copied the object wholesale or read `role` would hand out moderator accounts to anyone who
could open a network tab. `006_signup_metadata.test.sql` asserts that a signup asking for
`role: admin`, `is_banned: false` and an institution gets none of them.

## 2026-08-14 — No account enumeration, in the copy as well as the code

Supabase returns a decoy user on signup with a taken address. That protection is undone by an
interface that says "this address is already in use". Sign-in gives the same message for a wrong
password and an unknown address; the password-reset confirmation is phrased conditionally. Some
members have professional reasons to keep their participation private, and a form that answers "is
this person registered" hands that away to anyone who can type.

## 2026-08-14 — A dashboard setting that must match the repo gets a workflow

The minimum password length lives in `LIMITS.password.min` in `src/lib/validation.ts` and in
Supabase Auth's dashboard. `auth-config.yml` reads the dashboard setting through the Management
API and fails on a mismatch. It runs **weekly** — a dashboard change leaves no commit, so a check
that only ran on push would never catch it. It fails (not warns) on a mismatch — missing secret
means the check could not run; mismatch means it ran and found the defect.

## 2026-08-15 — profiles.confirmed_at exists because a policy cannot read auth.users

`authenticated` holds no privilege on `auth.users` and no USAGE on the `private` schema. The
JWT's `user_metadata.email_verified` is writable by the browser — trusting it would let anyone
mark themselves confirmed. So the confirmed-at timestamp is copied to `public.profiles` by the
SECURITY DEFINER trigger that already reads `auth.users` for the badge. It is called `confirmed_at`
rather than `email_confirmed_at` because `002_exposure.test.sql` asserts that no exposed column is
named like an email address.

## 2026-08-15 — Erasure detaches: author_id is nullable, ON DELETE SET NULL

A cascade would make "delete my account" mean "delete the discussion other people had about my
work", which the licence does not permit us to promise. `report_confirmations.user_id` cascades:
a confirmation is an attestation rather than a durable contribution, and an unattributed one could
not be corrected or counted against the one-per-person rule.

## 2026-08-15 — The staleness window is a literal in the view, not a setting

`security_invoker = on` means names in the view resolve with the caller's privileges; anonymous
callers have no USAGE on the private schema, so a settings lookup would fail for exactly the
readers the view exists to serve. Changing the window is therefore a migration — the right weight
for a number that changes every tombstone on the site.

## 2026-08-15 — An author may confirm their own report

Forbidding self-confirmation would refuse the most likely source of a truthful "it no longer
works". The tombstone reflects the most recent verdict, whoever filed it.

This is also the only route by which a report's outcome can move under a live verdict, since an
author's own confirmation does not set `answered_at` and so does not freeze the report. See
2026-08-23 below for the guard that closes it.

## 2026-08-15 — The status column grant is wide, and the policy is what narrows it

`grant update (status, ...)` includes `status`, which most callers must never write. Moderators
reach PostgREST as the same `authenticated` role — no column grant can distinguish them; the
moderator policy and `private.protect_report_columns()` restrict it. `author_id` has no column
grant: reassigning a report fails before any trigger runs.

## 2026-08-15 — Submission is one RPC, because a deferred constraint made it one

`reports` must record at least one tool, enforced by a DEFERRABLE INITIALLY DEFERRED constraint
trigger — deferred means at the end of the transaction, and PostgREST gives every request its own.
A browser inserting the report and then its tools in two requests fails on the first, at commit,
before the tools exist. `public.submit_report` is **SECURITY INVOKER**: it buys a transaction and
nothing else. Every policy, grant, constraint and trigger that guards those tables still guards
them through it. A DEFINER function here would be a hole around all of it and would look the same.

`p_author_confidence` is `integer` although the column is `smallint` — Postgres will not
implicitly narrow an integer literal while resolving which function to call, so a smallint
parameter makes `submit_report(..., 8, ...)` fail with "function does not exist".

## 2026-08-15 — A transcript link may not stand alone

A link without an excerpt is evidence that lives on somebody else's server under terms they can
change. `reports_link_needs_excerpt` enforces it. An excerpt without a link is ordinary and
common; a link without an excerpt is refused.

## 2026-08-15 — The three outcomes are given identical weight, deliberately

`OutcomeChoice.astro`: identical size, border, padding and type for all three; outcome colour on
the glyph only, labels in ink; a sentence saying all three are equally useful. These are
constraints on any future change to that component, not observations.

## 2026-08-15 — Draft autosave is per account, in localStorage

Keyed by account id so a shared machine shows each person their own draft. localStorage rather
than the database — a draft is not content and every keystroke to Postgres would hit rate limits.
The draft is discarded only after the write is confirmed; clearing on submit would lose it to a
failed request.

## 2026-08-15 — Reading is built, not fetched

`readCorpus()` runs during the build. The decisive reason: **Astro needs the ids at build time to
generate `/reports/<id>/` at all**, and GitHub Pages has no SPA fallback. A corpus meant to be
cited needs real URLs. A missing export warns on stderr and produces the empty state, which is a
designed state.

## 2026-08-15 — `[hidden]` needs `!important`

The browser's own `[hidden] { display: none }` is in the user-agent stylesheet, which any author
rule outranks. So the moment a component sets `display: flex` on a class, `element.hidden = true`
silently stops working on it. `base.css` carries `[hidden] { display: none !important }` — the
only `!important` in the project, not wrapped in `:where()`, because component scoped styles are
unlayered and otherwise win.

## 2026-08-15 — Filters are URL state, and a stale link says so

Filters are query parameters so a filtered view can be cited. A URL naming a value the corpus no
longer has is reported rather than dropped: "you are seeing more than the person who sent it."
Silently ignoring it widens a cited view without either party finding out.

## 2026-08-15 — The staleness rule is read, never recomputed

Every tombstone comes from `public.report_staleness`. A second TypeScript implementation would be
a second definition of "verified" — divergent with nothing to show that it is.

## 2026-08-15 — The aggregate is a SECURITY DEFINER function under a security_invoker view

A rating row is readable only by the person who wrote it. A plain view with `security_invoker = on`
reads `public.ratings` as the caller — who can see exactly one row. The histogram would be a
histogram of one. So the counting is in `public.rating_aggregate()`, SECURITY DEFINER, which
returns a histogram, median and counts and has no argument by which it can return a score
attributable to anybody. It refuses hidden debates. The view over it stays `security_invoker`,
which still joins `public.debates` so a hidden debate's aggregate does not appear in a listing.
The Security Advisor flags this twice — expected and accepted. The baseline was updated
accordingly; see the 2026-08-16 entry.

## 2026-08-15 — The median is percentile_disc; the mean is now shown as a secondary figure

`percentile_disc` returns a value somebody actually chose; `percentile_cont` interpolates and on
an even number of raters returns 6.5, which is not a point on an eleven-point scale. The mean was
originally forbidden because on a bimodal distribution it reports mild agreement for a community
that has split cleanly into two camps — smoothing over the exact thing this corpus exists to make
visible.

**Reversed 2026-08-21**: the mean is now shown beside the median as a secondary figure, never as
a headline and never on its own. The page says in words that a split community produces a mean
reporting mild agreement and a histogram showing the split. If the mean ever appears as a card
headline, on a sort control, or without the histogram beside it, that is the prohibition being
violated in the way that mattered. The test in `013_ratings.test.sql` was updated to permit the
aggregate function while preserving the display-layer rule.

## 2026-08-15 — The distribution is fetched, not built, so withholding it means something

A histogram built into the page and hidden with CSS is a decoration view-source defeats. The page
ships without it and fetches it once a rating exists. Anonymous readers cannot rate, so they do
not see the distribution; the rule is about who has formed a view before looking, not about who is
logged in.

## 2026-08-15 — A hidden grid child breaks automatic placement

A hidden grid child is removed from flow entirely, shifting every following child up a row. The
histogram has markers absent from nine of eleven columns; each column now has an explicit
`grid-row`. Any grid whose children can be `hidden` needs the same.

## 2026-08-15 — Comments post immediately; reports wait

A reply that appears a day later is not a reply. Pre-moderating discussion with volunteer
moderators means no discussion. The trade — visible before anyone acts — is what the hide path,
the flag queue and the per-account daily limit exist for.

## 2026-08-15 — The comment edit window is in a trigger because permissive policies are OR'd

An author may edit for 24 hours and delete at any age — two permissive UPDATE policies. Postgres
ORs permissive policies together (USING and WITH CHECK). An out-of-window edit satisfies the
delete policy's USING (author's, undeleted) and then the edit policy's WITH CHECK — so the window
in one policy is granted by the other and would be decorative. The window lives in
`private.protect_comment_columns()` and raises 23514. **A restriction cannot live in one
permissive policy if another permissive policy on the same command would admit the row.**

## 2026-08-15 — Deleting a comment destroys the text

The trigger sets `body` to empty string and `author_id` to null; a CHECK requires exactly that
shape. Moderators who need the text intact should **hide**. No `deleted_by` column: only the
author can delete, so it would record the name the deletion just removed.

## 2026-08-15 — A citation's endpoints are pages; its provenance is comments

`public.citations` links reports or debates, not comments — but both ends carry an optional
`*_comment_id` so a "referenced by" entry can point to a paragraph. A trigger requires each
comment id to belong to its end's page. A citation is visible only when **both** endpoints are —
a citation outliving a hidden target would republish removed text on a third page. No UPDATE
grant: immutability is a grant-level fact.

## 2026-08-15 — Citations are the one hard delete on the site

No replies, no attribution to preserve, excerpt at the target. The citer may withdraw their own;
a moderator may remove one whose excerpt should not be there.

## 2026-08-15 — Comments render at build time; new ones show as source

Build-time comments arrive as sanitised HTML; live comments are plain text. Rendering markdown in
the browser means shipping a parser and KaTeX to every reader and sanitising in the one place an
attacker controls. The 24 hour edit window follows: a comment carrying TeX is first seen set at
the next build, so a shorter window would mean nobody could fix a formula that came out wrong.

*Reversed 2026-10-11 — see "What you write is set as soon as you post it". The edit window stays.*

## 2026-08-15 — `public.flags` added early

A flag control that files nothing is worse than none. Lives in `public` because a browser UI reads
it. A flagger reads their own flags only — without that it is a list of who complained about whom.
Nothing about a flag is shown on the page: a visible count turns flagging into a downvote. Flags
cannot be withdrawn or edited; the queue is a record of what was raised.

## 2026-08-15 — `:scope >` in the thread

A comment element contains its replies, so `item.querySelector('[data-comment-body]')` on a
top-level comment returns the *first reply's* body. Every per-comment lookup in `CommentThread.astro`
uses `:scope >`. This stays true for reports after debates go flat, and the component is shared.

## 2026-08-15 — `auth_leaked_password_protection` is permanent, and the baseline is five

Supabase's check of a new password against a breach corpus is a paid feature. Constraint 1 is
zero budget with no credit card, so it stays off and the warning is permanent. **The baseline is
five and a sixth warning means something new.** A client-side check against Have I Been Pwned was
rejected: Supabase Auth validates the password, not our code, so a browser-side check is advisory
only, and it would put a third-party request into the signup flow of an audience that reads its
own network tab and was promised there are none.

## 2026-08-16 — Moderation goes through one audited function, and the direct path is closed

`public.moderate()` is SECURITY DEFINER, writes to `public.moderation_actions` in the same
transaction, and is the only thing that changes a row on a moderator's behalf. The moderator
UPDATE policies were dropped in the same push. A moderator's direct `update` now succeeds and
changes nothing — that silence is correct and is asserted in three test files. `public.moderate()`
authorises on `auth.uid()`, which is a JWT claim and is unaffected by DEFINER.

## 2026-08-16 — A moderator cannot act on their own contributions

Enforced in `public.moderate()` by name for reports, debates and comments, backed by the absent
moderator policies. With one moderator, that moderator's own submissions can never be published —
the argument for appointing two, which is now in `docs/moderation.md`. No account with moderation
standing can be banned from the screen; no account can ban itself.

## 2026-08-16 — The moderation log is append-only for the owner too, with one exception

A BEFORE UPDATE OR DELETE trigger raises for every caller including the table owner. The exception
is `actor_id` going from a value to null — the foreign key doing `ON DELETE SET NULL` when a
moderator erases their own account; without it the log would make a moderator undeletable. To
remove a row for real, a migration must `ALTER TABLE ... DISABLE TRIGGER` explicitly.

## 2026-08-16 — An erasure records that it happened, not whose account it was

`moderation_actions.target_id` is null for `erase_account`, by CHECK. Recording the user id would
preserve in an append-only log precisely the fact somebody asked to forget. The parameter to
`public.moderate()` is the deletion-request id, not the person's — impossible to erase someone
who has not asked.

## 2026-08-16 — "Request changes" writes to the report, because there is nowhere else

No address any code may read, no server to send mail, no inbox. `reports.moderation_note` holds
the current request; the author reads it under "Your submissions". A message table is a second
inbox nobody checks. One note at a time, cleared on publication.

## 2026-08-16 — /moderate/ ships as the 404 page

Reveals itself only after a signed-in profile comes back with a moderator role: no crawler
indexing, no shareable "you are not allowed" page. What it does not buy: secrecy — templates are
in the HTML, logic in the bundle. Data is defended by RLS. **A gate described as security that is
really courtesy is how somebody later decides RLS is redundant.**

## 2026-08-16 — Expect a sixth Security Advisor warning, and it is `public.moderate`

`public.moderate()` is DEFINER and executable by `authenticated`, so the next migrate run reports
one more `*_security_definer_function_executable` against it. It is DEFINER on purpose: it writes
rows the caller may not write — the audit row above all, which has no INSERT grant to anybody.
**The baseline is six, and a seventh warning means something new.**

## 2026-08-16 — The export reads over a direct connection, not with the service role key

Both authorise the same thing through different doors. A direct connection is one round trip per
dataset, can express lateral aggregates, and is the `pg_dump`-shaped exit this project chose
Supabase for. Handing a job a credential it does not need is how credentials end up in logs. The
WHERE clauses in `scripts/export.mjs` are the entire boundary between public and private —
everywhere else in this project the policies do that work.

## 2026-08-16 — The build reads data/ or reads nothing

The PostgREST fallback is gone: a build with credentials silently produced a different site from a
build without them. With every request to `*supabase.co*` blocked in devtools, all reading pages
render their main content. The only requests any of them make are the overlay and the thread's
live top-up, all of which fail silently.

## 2026-08-16 — A freshness card has no link, and that is the honest version

`/reports/<id>/` is generated at build time from the export, so a report newer than the export
has no page. The overlay could link to one anyway and let GitHub Pages serve the 404; it does not.
The card's title is plain text and the marker says "new since the last build — its own page
follows at the next one." The overlay uses plain `fetch` rather than the Supabase client so a
listing does not pull the auth bundle — checked in the built output.

## 2026-08-16 — The export commits only when content changed

`manifest.json` carries `exportedAt`, which changes every run, so the workflow stages `data/` and
compares against the index excluding the manifest. A push made with `GITHUB_TOKEN` does not start
another workflow (GitHub's recursion guard), so the job calls `gh workflow run deploy.yml`. The
job runs nightly rather than on demand because its own connection stops a free Supabase project
pausing after a week of quiet.

*Since 2026-10-11 it runs on demand as well as nightly; the nightly run stays for exactly this
reason. See "The site rebuilds when its content changes".*

## 2026-08-16 — profiles.json holds only people with something public

Somebody with an account and no contributions has published nothing; copying their display name
into a public repository commit would publish something on their behalf. Erasure removes an
account from every future export and cannot remove it from history or from any downloaded copy —
`data/README.md` says so, and the privacy notice too.

## 2026-08-16 — Pagefind for full-text search

Pagefind indexes the generated HTML after build, writing `dist/pagefind/`. The JS API is used
so results group by content type and connect to the existing filter vocabulary. `/moderate/` is
excluded automatically via `noindex`. The bundle loads at runtime on the search page only.

## 2026-08-16 — Embeddings computed locally on CPU, not via an API

`sentence-transformers/all-MiniLM-L6-v2` (Apache 2.0, 384 dimensions) runs in the GitHub-hosted
runner. No API key, no external call. Stored as int8 base64 — one byte instead of four per float,
~75% smaller, ≤±0.004 error per dimension, negligible at the cosine-similarity thresholds used.

## 2026-08-16 — The "related reports" reason is rule-based, not generated

The one-line reason is derived from shared metadata (task type, tags, area) in a fixed priority
order; the words are always taken from the report's own fields. A generated summary risks
mischaracterising the author's stated position — a serious problem in a citable corpus.

## 2026-08-16 — Near-duplicate detection uses transformers.js from jsDelivr CDN

Loaded lazily on blur of title or aim fields. jsDelivr is an asset CDN for npm packages, not an
analytics service. Model weights (~23 MB quantised) download from HuggingFace Hub on first use
and are cached in IndexedDB. If anything fails the warning does not appear; submission is never
blocked.

## 2026-08-16 — Embed workflow runs weekly, not nightly

~90 MB model download and ~30 seconds of CPU for data that can be a week stale is not a good
trade. The moderation queue catches true duplicates before they are published.

## 2026-08-16 — Network are a separate content type, not a tag on reports

An entry is a pointer, not an account of using something. Conflating them would mean asking for
a verification section from people adding a link and a URL field from people describing a session.
Rate limit is 5/day vs 10 for reports — lower friction, more likely to be abused.

## 2026-08-16 — The link-checker uses SUPABASE_DB_URL, not the service role key

The direct connection is already a secret in CI for the export. Same principle as there: handing
a job a credential it does not need is how credentials appear in logs.

## 2026-08-16 — Bot-rejecting status codes are treated as reachable

403, 405, 406, and 429 prove the server is alive and actively handling the request. 404 and 410
are explicit "this is gone" signals. A false 'unreachable' label — marking working links broken
because they use Cloudflare to block automated HEAD requests from cloud IPs — is worse than no
check, because it tells moderators and readers that working links are broken.

## 2026-08-17 — /debates/view/ is the client-rendered viewer for pre-export debates

A debate posted between exports has no static page. `/debates/view/?id=<uuid>` is a static HTML
shell that fetches its content from Supabase at runtime. The freshness overlay links fresh debates
here instead of rendering unclickable text. Once the nightly build generates the static page, new
external links use `/debates/<id>/`; the view page stays reachable for any existing link.

## 2026-08-17 — Same view-page pattern applied to reports; freshness overlay added to entries

`/reports/view/?id=<uuid>` follows the same pattern as `/debates/view/`. The staleness-confirmation
section and related-reports sidebar are omitted (the confirmation section reads `data-report-id`
at initialisation rather than at submit time, and related reports require the corpus in memory).
Both appear on the static page once the build runs. Network have no internal pages — every card
links to an external URL — so the fix for entries is a freshness overlay that prepends newly
published entries linking directly to their external URLs.

## 2026-08-17 — /account/edit-submission/ closes the "send back for changes" loop

A moderator could request changes and write a note, but the author had no screen to act on it.
`/account/edit-submission/?id=<uuid>` loads the full report via `loadPendingReport`, shows the
moderator's note at the top, pre-fills every form field, and on submit calls `resubmit_report` —
an RPC for the same reason `submit_report` is one: the deferred constraint fires at COMMIT, and
two PostgREST requests are not in the same transaction. No draft system: editing and resubmitting
is one deliberate action.

## 2026-08-17 — /authors/view/, because an author's first report has no author page

`/authors/<id>/` exists only for somebody with a published contribution at the last export, so a
person's first report goes live with their name on it and a 404 under it. `/authors/view/?id=<uuid>`
fetches the profile, published reports, and `report_staleness` for the tombstones. Everything this
page links to is a view page too — this page exists precisely when the export cannot be trusted,
so a link to `/reports/<id>/` would reintroduce the 404 one level down.

## 2026-08-17 — Entry submitter badges: the compact variant, and a sibling

`/network/` passed `profile={entry.submitter}` to `Badges`, which takes `institution`. Astro does
not fail on an unknown prop, so the component rendered its no-institution branch and the badge was
silently blank — a type error in `astro check` the whole time, which is the argument for keeping
that at zero. The fix uses `compact` (the one-line variant for comment headers). The badge sits
*outside* `.entry-card__submitter` because `.badge-line` is a `<p>`, and a `<p>` inside a `<span>`
is invalid markup.

## 2026-08-17 — Author pages cover entry submitters, and list what they submitted

`getStaticPaths` previously built author pages from the report corpus only, so a person whose only
contribution was an entry had a permanent 404. **`listContributors()` in `src/lib/authors.ts`** is
now the union of report authors, entry submitters, and debate authors — the definition of which
author pages exist. `listAuthors()` is gone; the next person looking for "the list of author pages"
would have found it first. Comment-only contributors have no page, because nothing links their name.

Identity comes from `data/profiles.json` rather than from whichever corpus mentioned somebody
first. A report and entry each embed the institution triple; a debate embeds only a name and the
pseudonym flag. Taking identity from the first corpus to mention somebody would have dropped the
institutional badge from anyone who had only ever posted a debate — silently, in the direction that
makes a badge appear missing rather than withheld.

## 2026-08-17 — Debate authors are contributors too, and their names link

Completing the rule: a page exists exactly where a link to it exists. Debate authors were the
remaining case where the *name* was shown and not linked. `listContributors()` includes debate
authors, and author pages list debates between the reports and the entries.

## 2026-08-17 — `.card__facts > li + li` skipped the variant that is not a list

The selector named `li`, missing the two places using `.card__facts` as a `<p>` of `<span>`s. The
column gap is zero, so facts ran flush: `WritingActive since 20 July 2026`. Now `> * + *`.
**An element name inside a shared-class selector is a silent opt-out** — the failure reads as
missing copy rather than missing CSS.

## 2026-08-17 — The landing page becomes a poster: one red, one diagram

The home page runs warm paper, near-black ink, and brick red `#b1231a`, overriding two lines of
CLAUDE.md that forbade cream grounds with warm accents and `01/02/03` markers. Both prohibitions
were rescoped in CLAUDE.md to the reading pages rather than deleted. Kalam is a fourth font family,
fenced to the diagram — mathematics as it is done on a board, not a decorative pseudo-formula.
Self-hosted, latin subset only, never in prose.

## 2026-08-17 — The reading pages adopt the landing palette. One palette again

Four values in `tokens.css` changed the colour of 29 pages. The `--home-*` names survive as
aliases of the real tokens: the home page and footer read better with role names, and a rename
would bury the actual change in noise. Focus rings moved from the accent to ink — a red ring
around a red button is not a focus indicator.

## 2026-08-17 — The home page asks for a submission instead of an email address

Posting is open. "Create an account" and "Post a report" replace `mailto:`. The copy names the
three fields the form will ask for and the ten minutes it takes. It also says an account of
something that did not work is worth as much as one that did — that decision is made before
anybody opens the form.

## 2026-08-17 — Renamed the three content types, and moved the moderation control aside

Practices are **reports**, propositions are **debates**, resources are the **network**. The change
is everywhere: routes, copy, TypeScript, corpus filenames, CSV headers, docs, and the schema. Both
names are load-bearing: the schema is the corpus's public surface named in CSV headers and in
every query against a dump.

**"Report" was already taken**, so the moderation control — `public.reports`, `report_reason`,
`report_status` — became **flag** first, and only then did `practices` move in. The last statement
in migration `20260817130000` asserts over the catalogues, settings keys, and every function body,
and raises if any old vocabulary survived.

## 2026-08-18 — Every listing carries its submit action, unconditionally, above the corpus

`/reports/` had its invite inside its empty state, so **the invitation to post disappeared the day
the first report was published**. There is now one rule for all three: a single `.corpus__action`
at the end of the introduction, above the corpus. **Unconditional**, because an empty listing
whose freshness overlay has found a row hides its own empty state — so the page can show a report
card and, under the conditional version, no way to write another.

## 2026-08-18 — Name the row rather than reflow the select string

supabase-js infers a row from the **literal type** of the select string; TypeScript widens
`'a,' + 'b'` to `string`, so a concatenated select is typed `GenericStringError`. Fix: name the
row and pass it — `.single<PendingReportRow>()` — rather than reflowing onto one line (fixes it
by accident until somebody wraps it again). `astro check` sees these errors; `astro build` does not.

## 2026-08-18 — Display math needs the delimiters on their own lines

`$$…$$` written on a single line is read as **inline** math by remark-math 6, even alone in its
own paragraph — so it renders in textstyle, with `\prod` and `\sum` limits beside the operator
instead of under it. The tell in built HTML is the presence of `math-inline` class rather than
`math-display` on the wrapper. On a site whose readers judge the typesetting before the sentence,
that is the expensive kind of quiet.

## 2026-08-18 — The embed job's two bugs: a missing file, and detection that never detected

`embed.py` prints "nothing to embed" and returns 0 without writing a file; `git add embeddings.json`
on a non-existent path exits 128. A missing file is now `changed=false`. Fixing that exposed the
change-detection step: `embed.py` writes a single JSON line, so any change rewrites that one line —
both versions contain `generatedAt` — and the filter was stripping the content and leaving only
diff headers. Detection now compares staged vs committed with `generatedAt` removed in Python.

## 2026-08-18 — A `counter` prop that counted nothing on two of the four forms

`Field.astro`'s `counter` prop renders the counter element; the page must wire it. The counter
reads `0 / 200` and looks like a loading component rather than an unwired one. It is now
`syncCounters()` and `wireCounters()` in `src/lib/forms.ts`; all four forms use it.

## 2026-08-18 — There is a notification centre, and it is an event table rather than an inbox

`public.activity` and `public.activity_seen`, read at `/account/activity/`. This stores *events*
— a kind, a target, a timestamp, sometimes an actor — and every word a person reads is composed in
`src/lib/activity.ts`. Nothing written by a human, so nothing goes stale.

**Why a table rather than deriving the feed at read time.** Three events cannot be derived: (1)
`public.reports` has no `published_at` — status is the current state; (2) `public.moderation_actions`
is moderator-only — the moderated person must not gain access to it; (3) `public.ratings` is
readable only by its author — a debate's author cannot count ratings on their own debate.

**The moderation trigger hangs off the log.** One `AFTER INSERT` on `public.moderation_actions`
covers all decisions. One audit row per decision, therefore one notification per decision.

**`label` is always the heading of the thing the event is on** — content the subject either wrote
or can already read. Never a comment body, flag detail, or moderator's reason. A flagged comment
resolves to the heading of its thread.

**`is_inbound` is a column.** `private.log_activity()` classifies every kind with a `CASE` that
has no `ELSE`, so adding an enum value without deciding which half it is in raises `case_not_found`
in CI. The header badge is a localStorage guess like session-hint and mod-hint — a live count
would load Supabase on every reading page.

## 2026-08-18 — The activity feed shipped empty, because a trigger cannot see the past

Triggers observe statements; everything before `20260818120100` happened unwatched.
`20260818140000_activity_backfill.sql` reconstructs from `created_at` on each source table and the
moderation log. Only `edited_report` is unrecoverable. `private.log_activity()` gained `p_created_at`
so the reconstruction uses real dates. The dedup key is that timestamp: trigger and source row share
the same `now()`. Granting `created_at` INSERT on any content table would break this.

## 2026-08-18 — The activity feed pages by keyset, because its timestamps are not unique

A trigger writes multiple rows in one transaction, equal to the microsecond — offset pagination
would skip or repeat rows at a boundary inside a group. Sort is `created_at desc, id desc`;
cursor carries both. The timestamp never touches `Date`: `timestamptz` has microseconds, JS `Date`
has milliseconds — round-tripping moves the boundary. It goes back exactly as PostgREST returned it.

## 2026-08-19 — Post-moderation: nothing is approved, and every decision is explained to both sides

Content is published when it is written. A moderator's work starts when somebody flags something,
ends with hide or leave-up, and carries a written explanation that the author and the flagger both
read.

**Why the gate went.** Three costs: (1) it put a volunteer between a mathematician and the corpus,
turning a ten-minute submission into an unknown number of days; (2) it scaled with submissions
rather than with problems — two volunteers answering flags scales with the number of things that
turn out to be wrong; (3) it read as approval, implying the moderators vouched for the mathematics.
They did not and cannot.

**What replaced it.** `public.moderate()` keeps its shape: one audited door, one audit row per
decision, still no moderator UPDATE policies. `publish`, `request_changes` and `promote` now
refuse by name, with a sentence saying the gate is gone rather than a generic refusal.

**The explanation is the new obligation, and it has two recipients.** The same sentence goes into
`public.moderation_actions` (moderator-only log) and `public.moderation_notices` (addressed to a
person). One row per recipient, making the policy `recipient_id = auth.uid()`. A notice never
names the moderator and never names the flagger.

**Hiding closes every open flag that named it.** One decision, one press; each closure is still a
real audit row. `resolve_flag` survives for flags against already-hidden or already-deleted content.

**Editing rethought.** Publishing is now instant, so "frozen at publication" would mean a typo was
permanent one second after it was made. The rule is: **editable while hidden, and until somebody
else has answered it**. A hide is answerable — the author reads the reason and edits; `status` is
reverted by the guard trigger so a save cannot republish. `report_tools` and `report_tags` had to
move with it — their policies gated on the parent being `pending`, and under a "hidden only" rule
every new submission would have broken at the deferred constraint.

## 2026-08-19 — Two private.log_activity()s, and every write on the site failing

The post-moderation migration reissued `private.log_activity()` with a seven-parameter signature,
but `20260818140000` had already replaced it with an eight-parameter one. `create or replace function`
does not replace across a signature change — it created a second overload, and every trigger call
became `function ... is not unique`. Every content write stopped working; reading was untouched so
the site looked healthy. The fix drops the seven-argument overload. `018_activity.test.sql` now
asserts both functions have exactly one overload each. **Before reissuing any function, read the
latest migration that touched it**, not the one that created it.

`test-db.yml` failed on the branch before the merge. `migrate.yml` runs on the same push to `main`
in parallel — not after it — so the migration was applied to production while the suite was going
red. A red branch run is a stop sign.

## 2026-08-19 — "Has anybody answered this?" is a column, because as a subquery it recurses

The editing rule — editable while hidden, and until somebody else has answered — was written as
`not exists` subqueries inside `reports_update_own_editable`. It raised `infinite recursion detected`:
a policy on `public.reports` reading `public.comments` calls the comment policy, which reads
`public.reports`. `public.reports.answered_at` is stamped by a SECURITY DEFINER trigger the first
time a confirmation or comment arrives from somebody other than the author, giving one indexable
comparison per row and the same phrase in the policy, the guard trigger, and the four child-table
policies. `answered_at` has no INSERT or UPDATE column grant; the guard trigger reverts it.

## 2026-08-19 — A ban was in the database and out of reach, and its explanation went nowhere

`ban` and `unban` had been in `public.moderate()` since `20260815200200`; the *effect* always
worked. What did not work:

**The explanation never arrived.** `moderation_notices_subject_is_content` restricted `subject_type`
to the four content kinds — an account is not one. The sentence a moderator is compelled to write
reached other moderators and nobody else, directly contradicting the post-moderation rule for the
harshest decision available.

**A ban could not be lifted.** `unban` was in the enum and the function. Nothing emitted it and
nothing listed banned accounts, so the reversible half of a reversible decision had no route.

**A ban was reachable only from a flag.** Spam produces no flag — people leave rather than flag
an advertisement. A network entry cannot be flagged at all (`public.flags.subject_type` is
`public.content_kind`, which has no `entry`).

What was built: widened CHECK, a notice in the account branch, an accounts section on `/moderate/`
with search and the banned list, a ban control on hidden rows and flags, a suspension banner on
`/account/`. Four decisions inside that: `recipient_role` gained `account_holder` rather than
reusing `author` (a ban may reach somebody who wrote nothing that was decided about); the audit
row moved inside the account branch, removing one way for a later action to log the wrong target;
banning twice is refused (the effect is idempotent, the notification is not); and no "ban and hide
everything" — one decision writes one audit row and one notice.

## 2026-08-20 — Schema version 2 of a report: fifteen sections, and five scales that may all be skipped

The form grew from twelve sections to fifteen. See CLAUDE.md for the full content model. Key
decisions:

**The three example reports were deleted, not migrated.** Backfilling `schema_version = 1` would
leave rows in a citable dataset that answer none of the new questions and nobody can complete. `data/`
was emptied in the same commit rather than waiting for the nightly job, because the export's shrink
guard would have refused the drop — correctly.

**The enums were extended, not converted to text.** `alter type ... add value` is the right weight
for a decision that changes what every past account means. New vocabularies with no enum (career
stage, generalisation, reference kind) are text with a CHECK.

**`task_secondary` is an array of the same enum as `task_type`.** Two spellings of one word is how
two entries for the same task stop being the same filter. The listing's task filter reads primary
and secondary together.

**A hidden scale stores null, not 0.** `ratingsFor()` in `src/lib/reports.ts` is the one place
that decides — it nulls anything that no longer applies. A 0 would put "no help at all" into the
corpus for a question the author was never shown.

**The ratings are sort keys and not filters.** "Reports where helpfulness ≥ 8" reads as a
measurement; an ordering is honest about being rough.

**The third-party affirmation became conditional.** Required when there is a transcript excerpt or
a prompt, not on every submission. An unconditional tick carries no information.

**`"references"` is a quoted column name.** REFERENCES is reserved. The alternative —
`supporting_material` in the database and `references` in the JSON and CSV — is a third name for
one field, a permanent tax on everybody reading the dataset.

**`role` joined the tool table's uniqueness key** as a functional index over `coalesce(role, '')`,
so two role-less rows are still the duplicate they were before the column existed.

**`ReportFields.astro` and `src/lib/report-form.ts`** are the form's markup and behaviour, shared
by `/reports/new/` and `/account/edit-submission/`. **`src/lib/report-facets.ts`** holds the four
derived filter values: the build and the freshness overlay both compute them, and a card whose
recency band was worked out a second way fails a filter it should match.

**`has_prompts` and `has_transcript` are generated columns** so the freshness overlay can answer
"includes the prompts" for rows newer than the export without fetching thousands of characters per
row onto a reading page.

## 2026-08-20 — `was_published` is four answers, and a boolean held three

`true` and `false` were fine; `null` was carrying both *not yet* and *not applicable*. Those are
not the same fact: "of the work that could have been published, how much was?" is unanswerable
when both answers map to null. The column is now text over `yes` / `not_yet` / `no` /
`not_applicable`. The disclosure constraint reads `was_disclosed is null or was_published = 'yes'`.

## 2026-08-20 — Time saved is an ordered list of durations, not a 0-to-10 score

`rating_time_saved` (0 to 10) and `cost_more_time_than_saved` (boolean) are replaced by one
`time_saved` text column. Two things were wrong with the number: a scale has no negative, so the
most useful answer needed a checkbox beside it, and the pair had to be read together; and "8 out
of 10 for time saved" is not comparable between two people, while "about a day" is.

The vocabulary is `none`, `few_minutes`, `about_an_hour`, `few_hours`, `about_a_day`, `few_days`,
`about_a_week`, `more`, `cost_more` — and `cost_more` is deliberately **last** even though it is
the only value below `none`. It is the answer this project most wants and the one an author is
most reluctant to give; putting it last means the reluctant answer is not also the first thing the
reader of the form rules out. The ordering lives in `TIME_SAVED` in `src/lib/report-schema.ts`;
the CHECK constraint is a membership test and says nothing about order.

## 2026-08-20 — A supporting link no longer carries a label

It was the only optional field in a repeating row — the worst place for one. The `kind` already
tells a reader what they are about to open. The field is removed from the form only: the jsonb,
the trigger, and `/reports/<id>/` still handle a `label`, so the column is null on every new row
rather than null where an author declined — a different fact, and the version `data/README.md`
now states.

## 2026-08-20 — Two task types added after the schema landed, in their own migrations

`example_counterexample` and `brainstorming` join the task type enum in separate one-line
migrations. A new enum label cannot be *used* in the same transaction that adds it, so an enum
value and a constraint or default that names it belong in different migrations.

## 2026-08-20 — A dropped column takes its column grant with it, and every submission failed

INSERT and UPDATE on `public.reports` are granted per column — deliberately, so a caller cannot
name `status` or `created_at`. A column added by a later migration arrives with no privilege; a
column dropped and re-added loses the privilege it had. Both happened in schema version 2, and the
whole submission path stopped working.

How it presents: the column is there, the CHECK is there, the policy matches, and
`public.submit_report()` — SECURITY INVOKER precisely so the grants still apply through it — dies
with `permission denied for table reports`. It reads as a policy that stopped matching rather than
one missing grant. The rule again: **grants decide whether the endpoint exists, check them first.**
Any migration that adds, drops or retypes a column on a per-column-granted table issues the `grant`
in the same file. `021_report_schema_v2.test.sql` asserts both columns on both commands.

## 2026-08-21 — `Field.astro` has no `input` slot, and `/network/new/` shipped the wrong controls

`Field.astro` renders its own control from its `type` prop. It has exactly one slot, `hint`. Astro
drops slotted content addressed to a named slot that does not exist — no error, no unused-prop
diagnostic, `astro check` is green. `/network/new/` had been written with `<Field><select
slot="input">…</select></Field>`, so every control was the component's default `<input type="text">`:
no `<select>`, no `<textarea>`. The tell is in the built HTML: grep `dist/` for the element you
think you wrote. The fix is the props API plus a bespoke `fieldset` for the choice list. An
`input` slot was deliberately not added — it would make the same silent failure available again.

## 2026-08-21 — The network category is a closed vocabulary with an `other`, and it is radios

`other` and `category_other` follow the same both-directions CHECK as `reports.area_other`: an
unqualified `other` is a row that has opted out of the axis, and a label on a non-`other` row
will never be displayed and will be read as data by somebody. Radios match Area on the report
form: a select hides the options and their one-line hints, and a category chosen without reading
the alternatives is the one that makes the listing filter useless. The free-text box is cleared
when the category changes away from `other` — left behind, it would fail the CHECK from a field
no longer on screen.

## 2026-08-21 — One prose box on a network entry, not two

"Why mathematicians should care" (`relevance`, 600 characters) was removed and the description's
cap went from 200 to 1000. Two short prose boxes in a row asked one question twice, and 200
characters was not enough once the second box had taken the interesting half of the answer.
`relevance` is **made nullable, not dropped**: dropping it would destroy the only copy of text
somebody wrote by hand, and a null column costs nothing.

## 2026-08-21 — The accessibility page states type properties, and claims no conformance from them

`/accessibility/` opens the *Type and legibility* section by saying WCAG places no requirement on
typeface choice — the load-bearing sentence. The section states properties that can be verified:
x-height at 74% of cap height, body at 17px/1.6, sizes in `rem`, latin-ext shipped, `font-display: swap`.
The reason the Serif / Sans / Mono split belongs here: **Plex Mono dots its zero** while Sans and
Serif do not. Everything meant to be read character by character is already Mono for semantic
reasons, so the family that disambiguates is the family carrying the strings where it matters.
Kalam's limitations — `I`, `l` and `1` are near-identical strokes — are stated rather than omitted,
and the fence is what keeps the limitation acceptable: the day Kalam appears in a sentence, the
page is wrong.

## 2026-08-21 — The debate statement is the page's `h1`, inside the blockquote

A debate page had no `h1` at all — the statement was a `<p>` inside a `<blockquote>`, leaving the
page's first heading as *1. Where do you stand?*, the rating control. It is now `<blockquote><h1>`:
a blockquote takes flow content so a heading is legal inside one; the reverse nesting is not.
This also fixed Pagefind: it takes a result title from the first `h1` and falls back to `<title>`,
so every debate came back in search as *"… — MathemAct"*. The CSS is now `.debate__statement > *`
rather than `> h1`, for the reason already recorded about `.card__facts`: an element name inside a
shared-class selector is a silent opt-out.

## 2026-08-21 — `--outcome-partial` is 4.63:1, and the glyph-only rule was never about contrast

`tokens.css` gave two different ratios for `#8a6a1f` — 4.41:1 in prose and 4.6:1 on the
declaration — and `Tombstone.astro`, `OutcomeChoice.astro` and CLAUDE.md all repeated 4.4:1 with
the conclusion it *fails* the 4.5:1 floor. Computed against `--ground` it is **4.63:1**, which
passes at every text size. The rule — outcome colour on the square, label in ink — stands on the
other reason: colour must never be the sole carrier of meaning. A wrong contrast figure is the
kind of thing somebody later acts on, and the action it invites is darkening a colour that already
clears the floor.

## 2026-08-21 — What the accessibility review changed, and what it deliberately did not

An audit of all 33 built pages had one real defect: the missing debate `h1` above. Three false
positives worth recording: (1) unlabelled controls in tool rows — they live in a `<template>`,
which lxml does not implement; parse built HTML with html5lib when the question is what is in the
accessibility tree; (2) unnamed `<svg>`s on the home page — both are inside `<div aria-hidden="true">`,
and `aria-hidden` inherits; (3) two `<header>`s per page — `header` is only `role="banner"` when
not inside `article`, `aside`, `main`, `nav` or `section`; `.page__header` is inside `main`.

Not built: **no automated accessibility check runs anywhere.** Every claim on `/accessibility/`
was verified by hand on one day.

## 2026-08-21 — One filter engine behind all three listings

The three listings had drifted into unrelated things. Network's filter classes were only ever
styled inside `search.astro`'s *scoped* block, so on `/network/` they matched nothing — the
`Field.astro` slot trap in another costume: valid markup, no warning, feature reads as
unimplemented.

Now: **`src/lib/listing-filters.ts`** is the engine, **`src/components/Listing.astro`** is the
frame, and **`src/lib/listings.ts`** holds each listing's dimensions, sorts and noun — read by
both the frontmatter and the client script, because defining them apart is how a sort option ends
up in a menu with no comparator behind it.

**Debates and network get one dimension each** — area, and category. Offering a filter the data
cannot support reads as a corpus that is empty. Nothing on `/debates/` filters on ratings: a "most
disagreed" filter leaks where the community landed to a reader who has not answered yet.

Two bugs fixed, both invisible on a populated corpus: (1) **the rail lived inside the `length > 0`
branch** — on an empty export the first day the site has content was the one day none of it could
be filtered; (2) **`readUrl()` ran before the overlay resolved** — a link filtering on a value
only today's content carries applied nothing and told the reader "nothing currently has this" —
both halves wrong. `add()` now re-reads the address bar after injecting options.

**The general rule: any feature that reads the corpus has to work on both halves.** A card the
overlay added carries the same data attributes as one the build wrote — that is what
`src/lib/report-facets.ts` exists to guarantee.

`?cat=` still works on `/network/` — `legacyParams` maps the old name forward on read.

## 2026-08-23 — A report page reads in the order the work happened, not conclusion-first

Reversed. `src/pages/reports/[id].astro` opened with **Outcome** and **How this was verified** on
a raised surface, ahead of the narrative, on the argument that they are what a reader is deciding
on and that burying them under the method arranges the page for the author. The order is now
tools → aim → method → prompts → outcome → verification → caveats → supporting material.

The old order answered *is this worth reading* before the page said what "this" was. A reader
arriving at a report has not yet met the work: an outcome sentence read before the aim and the
method is a verdict on something unspecified, and "partially worked" carries nothing until you
know what was attempted and with which model. Tools lead because the model and version are the
first thing that decides whether a report is about the reader's situation at all — a 2024 result
from a superseded model is a different document from the same result last week.

Outcome keeps `field-block--key`; **verification lost it**. Two raised blocks in a row stopped
reading as emphasis and started reading as a panel, and the boxed treatment sat oddly mid-page
now that the narrative runs above it. Verification is still required of every report and still
titled — the constraint was never carried by the box.

Both renderings changed together: `[id].astro` and `src/pages/reports/view.astro`, the runtime
fallback for a report with no static page yet. Those two are the same report seen a day apart,
and letting the order drift between them is the `report-facets.ts` problem in another surface.

## 2026-08-21 — A contribution stores the position it was written from, rather than joining it

`public.comments.agreement_score`, copied from the author's rating row at insert and frozen.

The alternative — a view joining a contribution to its author's *live* rating — is one join
shorter and wrong. Somebody who changes their mind would drag every contribution they have ever
written into a different group, retroactively, so the record of what the community thought in
March would silently become a record of what those same people think now. A contribution is
written *from* a position. That is a fact about a moment, and it is stored like one.

`022_debate_contributions.test.sql` asserts the column **after** the author has moved from "no
opinion" to 7, because before that the two designs are indistinguishable.

## 2026-08-21 — The score trigger overwrites what the client sent; it does not raise on a mismatch

Both defences work today and only one keeps working if the grant is ever widened. Raising turns
a lie into an error but depends on the client having been able to name the column in order to be
wrong about it. Overwriting does not care: grant the column by accident, add a service-role
path, widen a column list in a migration about something else, and the stored value is still the
one read out of the rating row, because the last write before the row lands is the trigger's.

The grant is still withheld — INSERT and UPDATE on `public.comments` are per column, so a column
nobody names is a column no browser can write. The two failure modes are both wanted and differ:
naming the column is refused outright with 42501, and a value arriving by any other route is
silently replaced. The test widens the grant on purpose, because a test that only proves the door
is locked says nothing about the floor under it.

## 2026-08-21 — A NULL `agreement_score` on a debate comment means "no opinion", not "unset"

The agreement scale's off-scale option is stored as a NULL `score` on a **real** `public.ratings`
row, not as an absent row, and the trigger refuses a contribution from anyone holding no rating
row at all. Between those two facts the column is unambiguous by construction: a contribution
exists only where a rating exists, so a NULL here can only have been copied from a NULL there.

So no sentinel, no coercion to 5, and no companion boolean. A sentinel puts a non-answer on the
scale; coercing to 5 files a declared non-opinion as a neutral opinion, which is the exact
corruption the off-scale option exists to prevent; a boolean is a second source of truth for
something the column already says.

## 2026-08-21 — Endorsements are readable only by their author, and the reason is two tables away

A rating row is readable only by its author — that is why `public.rating_aggregate` is
`SECURITY DEFINER` — and endorsing a contribution requires holding a rating on that debate.

So a public endorser list would leak, by inference, the private position of everybody on it.
"This captures my view" on a contribution written from 8 places its endorser near 8, and the leak
is worst on the contributions that matter most: one written from 0 or from 10 pins its endorsers
hard. **Counts are public; names are not.** Counts arrive through the nightly export; the browser
reads its own rows only, to decide which button is pressed.

Two things follow and both are deliberate absences. **No `SECURITY DEFINER` aggregate for live
counts** — `rating_aggregate` has one because a distribution must be current the moment a reader
answers, which is what they get in exchange for answering; an endorsement count is not that, and
a second DEFINER function on a private table to save a reader from a number being a day old is a
seventh Security Advisor warning for nothing. **No activity trigger** — "somebody endorsed your
contribution" cannot name the endorser without undoing the above, an unnamed one is a
notification that a number went up, and not touching `private.log_activity()` is worth something
on its own after 20260819090000.

## 2026-08-21 — "Has anybody endorsed this?" is a column, because the guard cannot ask the table

`private.protect_comment_columns()` is and must stay `SECURITY INVOKER`: it is the
`current_user` test in it that tells a browser from the table's owner, and a DEFINER guard sees
its own owner on every request. But the window closes on the first endorsement, and the guard
has no honest way to read `public.comment_endorsements`.

**An inlined `exists` fails silently, in the dangerous direction.** The subquery runs under the
caller's own policies; that table is own-rows-only; the caller is the contribution's *author*,
who cannot endorse their own contribution and so owns none of its rows. It would return false
however many endorsements exist — the window closed in the source and open in production, which
is the failure that reviews as correct.

**A `SECURITY DEFINER` helper in `private` fails too, and louder.** `authenticated` holds no
USAGE on the private schema — 20260813200000 revoked it and `002_exposure.test.sql` asserts it —
so the call is refused with 42501 and every legitimate edit becomes a permission error. This was
written and then reverted before it ever ran; recorded here because it looks obviously right.

So `public.comments.endorsed_at`, stamped by a DEFINER trigger on the endorsement insert, and
the guard reads a column on the row it is already updating. Same move as
`public.reports.answered_at` in 20260819100000 — there a subquery recursed, here it lies — and
cheaper either way. The stamp is never cleared: the text was frozen when somebody said it was
theirs too, and an erasure removing that row should not reopen an edit window on text other
people have since read.

## 2026-08-21 — Rating history exists, is append-only, and no browser role may read it

`public.rating_changes`, written by an AFTER UPDATE trigger on `public.ratings` when the score is
`is distinct from` the old one. **This reverses 20260815160100's "no history is kept."** The half
of that decision which stands is its reason: the aggregate is computed from current ratings only,
and `public.ratings` still holds exactly one row per person, so "the current distribution" stays
unambiguous. What changed is that the transition is no longer discarded — a position change is
the most valuable event this section produces.

Both score columns are nullable, because moving between "no opinion" and a number is a real
change and the most interesting one on the site. A `NOT NULL` on either would record every
position change except that one. The trigger's WHEN clause uses `is distinct from` and not `<>`
for the same reason: `<>` evaluates to NULL on exactly that transition and the trigger would
silently not fire.

**No SELECT grant to `anon` or `authenticated`, and no policy.** A readable per-person history is
a public voting record for a rating that is deliberately private, and it is worse than exposing
the rating: a current position is one fact, a trail through somebody's changes of mind is a record
of how they think, attached to a name, on a site whose audience includes people contributing
pseudonymously because admitting AI reliance carries professional stigma. The table exists to
produce one number per debate in the export, which runs as service role and is not subject to RLS.
History is never shown as a voting record.

## 2026-08-21 — Every rule in the debates rebuild carries a subject-type condition

`public.comments` serves reports and debates. Reports keep one level of nesting, keep replies,
and keep an edit window that closes on the first reply — a report thread is a discussion of one
specific account of one specific piece of work, and a remark with the author's answer under it is
the shape of a referee's note.

So flatness is `check (parent_type <> 'debate' or in_reply_to is null)`, the score column is
`check (parent_type = 'debate' or agreement_score is null)`, the supersession trigger carries
`when (new.parent_type = 'debate')`, and the guard branches on `old.parent_type` before choosing
which early-close rule applies. A CHECK without a `parent_type` term in it would break report
threads silently.

The flat rule is written **twice** — once in the constraint, once in `comments_insert_own` — and
the policy was **dropped and reissued** rather than supplemented. Permissive policies on one
command are OR'd, so a second INSERT policy carrying the rule would not add a restriction; it
would add a route that grants exactly what the rule withholds. The same reasoning keeps the edit
window in the guard.

## 2026-08-22 — The mean is computed once, in the function, and the test was narrowed to allow it

The 2026-08-15 entry above records the reversal in principle. This is what it took in practice,
because the prohibition had been written into three places and one of them was load-bearing.

`public.rating_aggregate` gains a `mean` column, and it had to be **dropped and recreated**:
adding a column to a `returns table (...)` changes the return type, which `create or replace
function` refuses outright. `public.debate_ratings` came with it, since the view depends on the
function — and dropping a view loses its `security_invoker` reloption and its comment, both of
which are restated. A view over a user-content table without `security_invoker` hands hidden
rows to anonymous callers while looking correct in review.

**The mean is in the function rather than only in the export**, and that is not tidiness. The
debate page shows the distribution twice at two different moments: the export writes it into
`data/debate-ratings.json`, and the browser fetches the live aggregate once the reader has
answered. A mean in only one of those places is a page whose summary changes when you answer it.

`013_ratings.test.sql` asserted against the catalogue that **no function or view in `public`
contained `avg(`** — written broadly on purpose, "so it covers whatever is added next". It now
exempts `rating_aggregate` by name and nothing else. The view assertion was left unexempted and
still passes, because the view calls the function rather than restating the arithmetic; that
assertion is what would notice somebody inlining it. Note that `sum(score)/count(score)` slips
past the regex — the honest move was to narrow the test, not to evade it.

## 2026-08-22 — Divided and consensus are export-time, and absent is not zero

Both are computed in `scripts/export.mjs` and stored, never derived in the browser.

- **divided** — twice the smaller of (share of 0–4) and (share of 6–10). Twice, so a clean
  50/50 split scores 1 and the number reads as a proportion of the most divided a debate could
  be. The *smaller* side, so 90/10 and 10/90 both score 0.2: they are the same shape seen from
  two directions. **The neutral 5s are in the denominator and in neither numerator**, so a
  debate where everybody sits at 5 comes out as 0 divided — which a mean of 5.0 could not tell
  apart from a clean two-camp split.
- **consensus** — the largest share held by any one of the five families. Families rather than
  single scores because 8 and 7 are not a disagreement, and a metric that treated them as one
  would report a united community as fractured over rounding. Labelled *Most agreed on*:
  "consensus" is a claim about the community, not about the numbers.

Off-scale positions are in neither, like everything else computed from the eleven.

**Below ten scored positions both are null, and null is not zero.** Two people at opposite ends
is perfectly divided by the arithmetic and tells a reader nothing, and it would outrank a
genuinely contested claim answered by ninety. A zero is a real reading — "nobody disagrees" —
which a debate with four answers has not established. The null travels all the way to the DOM as
the **empty string**, because `numeric()` in the listing engine reads `''` as "cannot be sorted
by this" and `'0'` as a value. That is the whole of the "a fresh card is ineligible" behaviour:
no new code path, just the absence of a number.

## 2026-08-22 — A sort may read an aggregate; a card may not show one

`src/lib/listings.ts` said that nothing on the debates listing touches ratings, full stop. That
has been **narrowed rather than abandoned**, and the line is worth stating because the two
sound identical and are not.

An *ordering* says "these claims divide the community" about the corpus. A *figure on a card*
says "this claim divides it 60/40" about one debate, to a reader who has not opened it — which
is exactly what the debate page withholds, and a listing that leaked it instead would make the
withholding pointless. So the sorts exist and the cards stay silent: no count, no median, no
mean, no share anywhere on `/debates/`.

The filters are unchanged and still area-only, for the older reason: a "has answers" or "median
above 7" checkbox hands over the same thing one bit at a time.

## 2026-08-22 — `src/lib/debate-facets.ts`, and why `Number('')` is a bug

The same argument as `report-facets.ts`: cards are built by the build and by the freshness
overlay, and a card whose attributes were assembled by two different pieces of code is a card
that fails a sort it should be in, with nothing to notice it. Both callers now hand a shape to
`debateCardAttrs()` and neither writes an attribute name.

It also owns `readCount()`, which exists because of a trap worth writing down: **Astro renders
an attribute whose value is the empty string as a bare attribute**, `dataset` hands that back as
`''`, and `Number('')` is `0`. Parsing a `data-` count directly therefore turns "the export has
never counted this" into "somebody counted this and the answer was none" — and the debate page's
statistics line depends on exactly that distinction, since a contribution count of 0 printed
under a chart with contributions listed beneath it is the page contradicting itself.

## 2026-08-22 — The shrink guard watches every JSON file, not just reports.json

It compared `reports.json` against the previous manifest and nothing else, so the discussion,
the debates, the aggregates and the citations could each go to zero without a word.

That was survivable while those queries were plain selects. It stopped being survivable when
`AGGREGATES` and `COMMENTS` grew lateral joins for the endorsement counts and the position
changes: **a join that matches nothing does not error, it returns fewer rows**, and the failure
would have arrived as a quietly empty `comments.json` committed over a full one.

Every JSON file is now checked against its own previous count. The CSVs are skipped as
projections of files already checked — `csv/reports.csv` cannot shrink without `reports.json`
shrinking first, and reporting both would make one fault read as two. A file that was empty last
night is not checked, which is why an empty `data/` cannot trip it.

## 2026-08-22 — The debate page has no section numbers and no date

Three changes to the top of `/debates/<id>/`, and the reasons are unrelated.

**No "Active since <date>".** It described a lifecycle the site stopped having on 2026-08-18,
when post-moderation made a debate part of the record the moment it was written; `activated_at`
is now a date on which nothing happened. Dating a standing question also framed it as news. The
date stays in the export and on the listing card, where "posted" is what it honestly means.

**The asking block is removed once answered**, not collapsed and not replaced by a summary of
their own answer. The question has been asked; a spent control left on the page turns a reading
page into a form. Their answer comes back as the marker on the histogram, and one button under
the chart reopens the same scale — one scale on the page, because two would be two sources of
truth for one answer.

**No "1." and "2."** The numbering only worked while both panels were always present. Once the
first is removed at the moment it is answered, a "2." with no "1." above it numbers the page's
history rather than the page.

One consequence to know about: the form's `#rate-status` lives inside the asking block, so a
success message had nowhere to be displayed by the time the save had succeeded. There is now a
second status element on the results panel, and that is what a confirmation uses.

## 2026-08-22 — Four stat cards became one line, because the mean was about to be a headline

The distribution used to be summarised by four equal bordered boxes with their numbers set at
`--size-5`. That layout makes every number in it a headline, and one of them is now the mean —
which is the one reading the display rule exists to prevent, because it is what survives a skim:
on a bimodal debate "6.2" reports mild agreement for a community that has split cleanly in two.

One line instead, in the order d4 specifies, with the median in ink and heavier and the mean
muted and no larger than the surrounding prose. The mean sits *below* the chart that contradicts
it. Coverage is spelled "X expressed an opinion" rather than as a percentage: a ratio invites
reading it as a quality score for the debate, where the count invites the comparison that
matters — how many of the people who answered were willing to put a number on it.

The two export-time figures hide their own wrappers when the number is unavailable, so the line
ends after the mean on `/debates/view/` rather than trailing two zeros.

**The off-scale answers are said in words** under the chart, naming the reader's own decline
first — they looked for their marker, it is not there, and that sentence is the answer. They get
no column, because "outside my expertise" is not a position on a scale of agreement, and they
are not parked at 5, because filing a declared non-opinion as a neutral opinion is the exact
corruption the off-scale option exists to prevent.

## 2026-08-22 — The thread component is split, reversing its own header

`CommentThread.astro` argued that a thread is a thread and that separating the report thread
from the debate thread would guarantee they drift. That was right while both were the same
surface: a list of remarks under a page, threaded one level, newest at the bottom.

They stopped being the same surface. A debate now has twelve groups, two views, a sort control,
no replies, no nesting and no badge line — none of which has an analogue on a report, where the
thread is a discussion of one specific account and threading is correct. Branching on
`parentType` inside one file would have meant two mutually exclusive markup trees and two client
scripts in one component, with every shared selector a way to change how a report thread renders
by accident. That risk is not hypothetical here: report interaction cannot be exercised locally,
because it needs a database and a signed-in account.

So: reports keep `CommentThread.astro`, **byte-identical** — `git diff` shows no change to it —
and debates get `Contributions.astro` plus `Contribution.astro`.

**The boundary is rendering only.** Reading the corpus, editing, deleting and flagging all still
go through `src/lib/comments.ts`, so the behaviour the old header was protecting cannot drift;
what diverged is markup, which is what was supposed to diverge. The `:scope >` discipline is
carried into the new component even though a debate contribution can no longer nest, because
historical replies are rendered flat in that list and the rule is the discipline rather than the
current shape of the data.

`Contribution.astro` is its own component rather than a snippet repeated in the position groups
and the off-scale group, and **its styles live in it** — Astro does not put a parent's
scoped-style attribute on a child component's root element, so `.contribution` styled in the
parent would compile to a selector matching nothing.

## 2026-08-22 — The zero-JavaScript case is "open a position, read those contributions"

The selector is native `<details>`: one per family, each holding one per position, all closed.
So the by-position view starts empty because the disclosures are closed, not because script
emptied it — and the prompt line disappears through
`.view:has(details[data-position-group][open])`, which needs no state kept in step with
anything.

What is the enhancement, deliberately: exclusive selection, the URL, opening a whole family at
once, landing on the reader's own position, the sort control, and **the flat view**. A reader
with no JavaScript gets one view in one order and no dead controls — the view switch and the
sort `<select>` are `hidden` in the markup and revealed by script, because a control that does
nothing is worse than an absent one.

The flat view **moves** the same `<li>` nodes rather than rendering a second copy. Two copies
would mean two elements carrying one `id`, and `#comment-<id>` is a real address: the activity
feed builds it to point somebody at the contribution they were told about. `data-position` on
each node is what lets the move be reversed.

## 2026-08-22 — Three things a single null would have collapsed

`agreementScore` is null in three situations and only one of them means what the off-scale group
claims.

- On a **report comment** it argues from no position, which is correct rather than missing.
- On a **debate contribution** it is the off-scale answer: the author was asked and declined.
- On a **debate contribution from an export written before the column existed** it is nothing
  at all.

The third was filing that contribution under "No opinion, or outside my expertise" — **publishing
a position its author never took**, which is the precise failure the off-scale group exists to
prevent, inverted. It was found by reading the built HTML rather than by any check: the row
rendered, the page looked right, and the label was a claim about somebody's view that nothing
supported.

So `Comment.positionKnown` distinguishes an absent key from an explicit null (`'agreementScore'
in comment`, not `??`), and `groupKeyFor(score, known)` returns a thirteenth key for it. That
group renders **only when it has something in it**, so a current export shows the twelve groups
the design describes and nothing else, and the rows in it say "position not recorded" until the
next nightly export gives them their real one.

## 2026-08-22 — What only the distribution knows arrives by event

"People answered at this position and none of them wrote anything" is the interesting empty
state and the one the design asks for. It is also a fact about the histogram, which is fetched
after the reader has answered precisely so that it is not in the page source — so the section
cannot render it, and weakening that rule to get a nicer empty state would trade the thing for
the description of the thing.

The debate page therefore tells the contributions section, once, on the same code path that
reveals the chart: a `mathemact:rated` CustomEvent carrying the histogram, the off-scale count,
and the reader's own score. That is also how the section knows which position to land on.

An event rather than a shared module holding DOM state, because these are two components with
two client scripts on one page and the only thing that should cross between them is the payload.
Until it arrives, an empty position says only that it has no contributions — which is all the
page can honestly claim.

## 2026-08-22 — Editing, deleting and flagging came across; writing did not

The specification for this surface covers the two views and what a contribution shows. It says
nothing about the per-contribution controls, and carrying them over is a slight widening of it —
but the alternative was shipping a debate page where an author could no longer correct their own
contribution and **no reader could flag one**, which is a moderation path, and losing it silently
would have been the worst of the three outcomes.

Writing a contribution deliberately did **not** come across. It belongs inside the reader's own
position group, below what is already there, collapsed behind an explicit control, and that
sequence is specified separately. What is here is the seam: a `data-compose-seam` element per
position group, empty and hidden, so there is no always-visible box to have to remove later.

One consequence to know about: `installQuoteAffordance()` lived in `CommentThread.astro`'s
script, so the selection popover — quote a passage into a comment, cite one into a debate — is
not on debate pages at present. It is not an oversight and it is not restorable on its own: the
affordance exists to put a passage into a composer, and there is no composer on this surface
yet. It belongs with the writing box.

## 2026-08-22 — An endorsement is withdrawable, so a count may go down

`20260821120200` shipped `public.comment_endorsements` with no DELETE policy and no grant, and
said in as many words that withdrawal was a decision about whether a count may go down rather
than a gap. `20260822100000` decides it: yes.

The alternative is worse in a specific way. "This also captures my view" is an assertion about
what somebody currently thinks, and this whole section rests on people being able to change
their minds and on that being visible. An endorsement given and never retractable would be the
one claim on the page its author was stuck with.

**A hard delete, and the second on the site** after `public.citations`, for the same reason:
nothing is threaded under it, there is no attribution to preserve and no prose. A soft delete
would leave a row saying "this person once said this captured their view", which is a record
nobody asked for and which the select policy would then have to hide from its own author.

**A banned account cannot withdraw**, matching the update policy, which already re-tests the
ban. A ban closes write paths and removes nothing already posted — their reports stay up, their
contributions stay up, their endorsements stay counted — and permitting this one write would
make a ban a way to retract things quietly. Note this clause sits on a DELETE policy and is
therefore **not** one of the nine `not p.is_banned` INSERT clauses the count in
docs/moderation.md refers to.

`public.comments.endorsed_at` is **not** cleared, so the edit window stays shut. The text was
frozen when somebody said it was theirs too, and other people have read it since on that basis;
reopening it because the one endorser changed their mind would let the words move under
everybody who read them. `022_debate_contributions.test.sql` asserts that directly.

## 2026-08-22 — The optimistic count is relative to what the page was showing

The export's count already includes the reader's own endorsement if they made it before the last
nightly run, and excludes it otherwise — and **nothing in the file says which.** So adjusting the
number at page load would be a guess in one direction or the other.

What is not a guess is the change the reader just made. The displayed count is
`base + (now === kind) - (atLoad === kind)`: zero adjustment until they act, and exactly one
either way when they do. It can be off by one against the true total, which is the same accuracy
every other number on this site has between exports, and the prompt for this work says so.

Failure rolls back **in prose**, not by silently restoring the number. A count that reverts with
no explanation reads as the page glitching; a sentence saying what happened is what lets somebody
decide whether to try again.

## 2026-08-22 — "Nothing renders on your own contribution" is a rule about the controls

Both actions and the "answer the debate" pointer are **removed from the document** on the
reader's own contribution — not disabled, not greyed, not left in the accessibility tree. A
control that explains why you cannot use it is still a control telling you it exists.

The **counts stay**, and that is a reading of the rule rather than an exception to it. They are
export data rendered for every reader including anonymous ones, they name nobody, and hiding them
from the one person the number is about would withhold the feature's entire output from its
subject. The clarifying phrase in the rule is "not a disabled button", which is what the actions
would have been.

## 2026-08-22 — Not having answered is pointed at the scale, not at a sign-in wall

The same message for an anonymous reader as for a signed-in one who has not answered, because
the thing standing between either of them and this control is not having a position — and the
scale, which is on the same page and visible for exactly these readers, says what signing in is
for by itself. A sign-in wall would answer a question neither of them asked.

## 2026-08-22 — The composer moves, and it has a second home

One composer on the page, moved into the reader's own position group once that group is known.
Twelve would be twelve places for a draft to be stranded, and one textarea means one counter and
one set of ids — the same argument `CommentThread.astro` makes for relocating its own.

The sequence is the deliverable rather than the button: their position opens, they read what
people who answered the same way have already written, each of those offers "this also captures
my view", and *then* one control below all of them opens the box. **Collapsed, not gated** — a
plain button, not disabled, not behind a warning, not conditional on having endorsed anything.
Somebody with a genuinely new point loses one click; somebody about to retype an argument three
rows above sees it first.

*Amended 2026-10-11:* the box is still collapsed, but giving a reason is no longer optional for a
first answer. See *A position needs a reason, and the reason arrives with it*. The same collapsed
box also appears in the answering form.

The second home matters more than it looks. A position nobody has written from renders as an
inert paragraph rather than a disclosure, and a debate with no contributions renders no groups at
all — so in both cases there is no seam to move into, and both are precisely the moment somebody
is about to write the **first** contribution at their position. `[data-compose-fallback]` at the
end of the section is where it goes instead. Without it the one case that most needs a box would
not have had one.

## 2026-08-22 — A `!` that outlived the element it asserted about

`/debates/view/` set the contributions section's id through
`document.querySelector('[data-thread]')!` — and `[data-thread]` is `CommentThread.astro`, which
that page stopped using when debates moved to `Contributions.astro` on 2026-08-22.

The non-null assertion silenced the null the type system had correctly inferred. `astro check`
passed, the build passed, and the line would have thrown a TypeError on the next `.dataset`
access, taking the rest of the function — including the reveal of the page content — with it.
This is the trap CLAUDE.md records about accumulating `!`s, arriving from the other direction:
not a narrowing lost inside a hoisted function, but an assertion that stayed true-looking after
the thing it asserted about was deleted. It was found by re-reading the file to add a line to
it, which is not a strategy.

## 2026-08-22 — The movement badge reads "6 to 9", because U+2192 is not in the font

The design called for "6 → 9". It renders as "6 to 9", and the reason is typographic rather
than editorial.

The self-hosted IBM Plex subsets are `latin` and `latin-ext`. U+2192 is in neither, so an arrow
would be drawn by whatever the browser fell back to — a different weight and a different shape
sitting directly beside IBM Plex Mono digits, in front of an audience this project describes as
unusually sensitive to typographic sloppiness. It is the same problem as U+25A0, which the
tombstone draws in CSS for exactly this reason. A word costs two characters and is set in the
right typeface.

`movementLabel()` in `src/lib/positions.ts` is the one place it is worded, which also makes the
off-scale case fall out for free: moving to or from "no opinion" is a position change like any
other and gets the same badge with words where the number would be — "no opinion to 9".

Noted while checking this: **the `←` in the breadcrumbs has the same problem** and predates all
of it. Not fixed here, because changing every breadcrumb on the site is not this branch's, but
it is the same fallback in the same place and is worth a decision of its own.

## 2026-08-22 — The edit window is shown, and read from the stamp rather than the counts

The database enforces the window and raises; the interface agrees with it. So the author sees
the time remaining, and where it is shut, **which rule shut it** — "somebody has said this
captures their view" rather than a disabled button with no account of itself.

It reads `comments.endorsed_at`, which meant carrying that column into the export. The
tempting shortcut was to infer "endorsed" from the endorsement counts, which are already
exported — and it is wrong in a way that only shows up after a withdrawal. The stamp is set by
the first endorsement and **never cleared**, so a contribution every endorser has since
withdrawn from has both counts at zero and a window that is still shut. Inferring from the
counts would offer an Edit button the guard refuses, which is precisely the interface
substituting for the database rather than agreeing with it.

The remaining time is computed in the browser. Rendered at build time it would be hours stale
before anybody read it, and it is deliberately coarse — "about 3 more hours" — because nobody
needs the seconds and a countdown nobody asked for is worse than a rounding.

Deleting is unaffected at any age. A contribution is withdrawable whenever, and its position
stays in the distribution either way.

## 2026-08-22 — A position change invites a contribution; it does not require one

The movement is already recorded by the time the invitation appears: the rating update wrote a
`rating_changes` row by trigger, and the earlier contribution keeps its text, its group and its
score with a link forward. So the invitation is an offer above a control that stays exactly as
collapsed as it was — not an auto-opened box, not a step in a flow. Somebody who moved and has
nothing to add has already done the part that counts.

`justChanged` is set for exactly one reveal and cleared immediately after. A first answer is not
a position change, and neither is arriving on a page you had already answered — both would
otherwise show an invitation to rewrite something in response to nothing.

*Amended 2026-10-11:* still true from one score to another. Moving from "no opinion" to a score
now needs a reason, because it is taking a position for the first time. The invitation is also
skipped when the change itself came with a new contribution.

## 2026-08-22 — The count of changes is all `rating_changes` may produce

The statistics line carries "K changed position" and there is no list behind it, by design.
Ratings are private on this site, so a per-person history of who moved and when is a public
voting record for something deliberately hidden — which is why the table has no grant to any
browser role and the export takes a `count(distinct user_id)` out of it and nothing else.

If a list is ever wanted, it is built from **superseded contributions** instead: the people
whose positions are public because they chose to write them down. That is what the badges
already are, read collectively. It will be smaller than K, and the difference is the finding
rather than a bug — more people change their mind than write about it. Anything rendering both
has to label them so that gap is legible.

## 2026-08-22 — A debate card shows a shape, which reverses "a card may not show an aggregate"

From the day the shared listing engine landed until now, `/debates/` rendered no aggregate at
all — no count, no median, no share — and `src/lib/listings.ts` argued the case: a figure on a
card tells a reader where the community landed before they have opened the question, which is
exactly what the debate page withholds.

**Reversed.** A card now carries a distribution sparkline and one statistics line,
`N positions · C contributions · K changed position`.

What changed is not the analysis but the judgement about which failure costs more. A list of bare
sentences gives a reader no way to choose what to read, so they open whatever is at the top; a
claim four people answered and a claim that has split ninety look identical. The section's second
most important flow — a reader understanding where the community stands in about thirty seconds —
never starts, because nothing on the page tells them which claim is worth thirty seconds. The
shape is what makes a claim worth opening.

What survives of the old rule is the whole of the constraint:

- **Positions lead**, never a contribution count, and **never the mean.** A card is where a
  single number gets mistaken for the finding, and on a bimodal debate the mean is the number
  most likely to be mistaken for it. It stays on the debate page, beside the median and the
  chart.
- **No axes, no numbers, no ranking figure.** Nothing says where a card came in under the
  current sort, and neither `divided` nor `consensus` is printed anywhere.
- **One colour, the accent.** A ramp from disagreement to agreement would assert that one end is
  the bad end, on a page whose entire point is that the site takes no position — and it would
  collide with the outcome semantics, the only place on this site where red and green mean
  anything.
- **A card the overlay added shows neither the sparkline nor the statistics line.** Aggregates
  are an export-time product, and a zero histogram reads as unanimous disagreement.

### The consequence, stated rather than buried

**This pulls against *Do not reveal the aggregate until the user has rated*.** The sparkline
shows the shape of a debate to somebody who has not answered it, which is the effect that rule
exists to prevent — and on 2026-08-21 the choice was made deliberately to keep that rule real,
by leaving the debate page's distribution as a live fetch rather than baking it into the page.

The two are not fully reconcilable and the split is now: the **listing gives away the shape**,
and the **debate page still withholds the precise distribution, the median, the mean, and the
reader's own place in it**. That is a real trade, not a technicality — bandwagoning is driven
more by shape than by precision.

If the effect is judged to matter more than orientation does, **the sparkline is the thing to
remove.** The statistics line does not carry the shape, and neither do the sorts. Removing it is
one conditional in `DebateCard.astro`.

## 2026-08-22 — "Recently active" needed a definition, and it went where the others are

The brief said to surface five orderings and not to define them here, because prompt 3 had put
them in `src/lib/listings.ts`. Four were there; *Recently active* was not.

The prohibition is against defining a sort **on the page** — that is what puts a listing on two
definitions and lets the build and the freshness overlay disagree. So the definition went into
`DEBATE_SORTS` beside the others, and the export gained the value it reads.

`lastActivityAt` is the later of the newest contribution and the newest rating activity, falling
back to the debate's own date so a claim nobody has touched sorts by when it was asked rather
than sorting last for want of a value. The ratings side uses `max(updated_at)` and not
`created_at`, because somebody changing their answer is activity and it is the kind this section
most wants to notice.

**It is a timestamp and nothing else.** It says *when*, never who moved or to what, so it is not
a way back into the per-person history `public.rating_changes` deliberately withholds.

It is deliberately last in the menu. It is the only ordering here that is about attention rather
than about the claim, and a listing of claims that opened ordered by whatever was touched most
recently would be a feed.

## 2026-08-22 — What "most divided" measures is on the page, not in a tooltip

Two of these orderings rank disagreement, and an opaque ranking of disagreement is the least
trustworthy thing this site could put in front of this audience. So both are defined in words
beside the control: what each measures, that both run over the scored positions only, that the
neutral 5s count in neither side, and that a debate needs at least ten scored positions to appear
in either at all.

The threshold is read from the export's own `sortableMinimum` rather than typed into the
sentence, so the copy cannot come to disagree with `SORTABLE_MINIMUM` in `scripts/export.mjs`.

`Listing.astro` gained a named `sort-note` slot for it. Two traps met in one change: Astro
**drops** content addressed to a slot that is not declared, without a warning — so the slot had
to be added there rather than assumed — and slotted content carries the **page's** scope
attribute rather than the component's, so the styles live in `corpus.css`.

## 2026-08-22 — Debates have no tag vocabulary, and this is the seam

`public.debates` has no tag table: `tags` and `report_tags` are the reports' vocabulary, and
nothing else has one. So tag filtering is not half-built here.

An empty "Subject area" fieldset would be a rail of dead ends with a zero beside every option,
which reads as a corpus that is empty rather than as a question nobody asked — the same argument
that keeps unused areas out of the area filter. When debates get tags, it is one entry in
`DEBATE_DIMENSIONS` and one line in `DebateCard.astro`, and both places say so.

## 2026-08-22 — The card's styles are global, because a `<template>` cannot be a component

The freshness overlay builds its card by cloning a `<template>` in the page, since a template
cannot instantiate an Astro component. That markup therefore carries the **page's** scope
attribute and not `DebateCard.astro`'s — so a scoped `.debate-card__claim` in the component would
style every built card and leave every fresh one bare.

The styles are in `corpus.css`. What is *not* duplicated between the two paths is the attribute
list: `debateCardAttrs()` writes those on both, which is the half whose drift would silently
break a sort rather than merely look wrong.

## 2026-08-22 — Proposing a debate requires answering it, so it is one RPC

`public.submit_debate()` writes the claim and the proposer's own rating in one transaction.

The requirement — **somebody unwilling to say where they stand should not be setting the
question** — cannot be expressed in a policy: it is a statement about two rows in two tables, and
row level security only ever sees one row at a time. And it cannot be left to two client calls,
because a debate whose proposer never answered it is precisely what the rule forbids, and that is
what any failure of the second call produces.

`SECURITY INVOKER`, like `submit_report()`, and worth stating because a function writing to three
tables looks like it wants elevation. Every insert runs under the caller's own policies —
`debates_insert_own`, `ratings_insert_own`, `debate_tags_insert_own_unanswered` — so **the
function authorises nothing.** It is a transaction boundary and a required-field check. A DEFINER
version would have had to restate all three sets of conditions, and the restatement is where they
drift. The test asserts that a banned account's refusal comes from the policy and not the
function.

What it does not close, stated so nobody assumes otherwise: a caller inserting into
`public.debates` directly still can, and gets a debate with no position on it. The policies must
allow that — the guard trigger and the wording freeze both need an author who can write their own
row — so what this function does is make the supported path the one that produces a well-formed
debate, and make the form unable to produce anything else.

**The position is two parameters**, `p_score integer` and `p_off_scale boolean`, because a single
nullable score would collapse two different things. On this scale a NULL score is "no opinion, or
outside my expertise" — a real answer on a real row, and the whole reason the eleven points have a
twelfth group beside them. Collapsed, the function would either refuse the people the off-scale
option exists for, or accept an empty submission as a declared non-opinion.

`integer` and not `smallint` for the same reason `submit_report`'s `p_author_confidence` is:
Postgres will not implicitly narrow an integer literal during overload resolution, so a smallint
parameter turns `submit_debate(..., 8, ...)` into "function does not exist" — a message that
sends you looking for a missing migration.

## 2026-08-22 — Your own answer is not an answer, or the whole feature dies on arrival

This is the interaction that would have shipped broken, and it was invisible in any single file.

Requiring the proposer to rate their own claim means **a rating exists from the moment a debate
does.** Two rules were written as "once anybody has rated it":

- `private.protect_debate_columns()` freezes `statement` and `area`. It would have engaged on
  creation, so a proposer could never fix a typo in their own claim — with nobody having agreed
  to anything, the rule protecting a reader who does not exist.
- `debate_tags`' insert and delete policies. They would have refused **every tag**, including the
  ones `submit_debate()` inserts three lines after the rating. The feature would have been dead
  from the first submission.

Both now test for a rating by somebody *other than* the author, which is the rule
`private.mark_report_answered()` already states in as many words for reports: "An author
correcting their own report in the thread should not thereby lose the ability to correct the
report."

`is distinct from` and not `<>` in the guard, because `author_id` is nullable — erasure detaches a
debate rather than deleting it — and on a detached debate `<>` would evaluate to NULL for every
rating, the EXISTS would find nothing, and the wording of a claim dozens of people had answered
would come unfrozen. No browser can reach that path, since the ownership policy also fails, but a
guard that depends on another rule holding is a guard with a footnote.

`023_submit_debate.test.sql` asserts all three directions: the author can still correct after
answering themselves, somebody else answering closes it, and the tags go in.

## 2026-08-22 — The reasoning is capped at 500, and the cap is the mechanism

Down from 2000. An opening post that runs to two thousand characters turns a claim somebody can
answer into an essay somebody has to agree or disagree with in aggregate, and the distribution
that comes out is a distribution over whatever each reader took the essay to be arguing.

Guidance in the form asks nicely and is ignored by exactly the people whose rationale most needs
shortening. A CHECK is not. Five hundred is about a paragraph — enough to say why the claim is
contested and what the strongest case against it is, and not enough to make the case itself. The
case belongs in a contribution, where it carries the position it was argued from and other people
can say it captures their view.

The label changed with the cap: "why it is worth asking" invited a case for asking the question,
which is a different thing from the reasoning behind the claim and is what produced the long ones.

Existing rows over the cap are **refused, not truncated.** Cutting somebody's writing to make a
migration apply is not a migration's business, and a rationale trimmed mid-sentence is worse than
one that is too long.

## 2026-08-22 — Debates reuse the reports' tag vocabulary

`public.debate_tags` over `public.tags`, which is `report_tags` with one column renamed. Not a
second vocabulary: the question a tag answers — *which part of mathematics is this about* — is the
same on both surfaces, and two lists would drift and force a reader to learn which page uses
which.

The write policies are **not** `report_tags`' write policies. Those gate on
`p.status = 'pending'`, from the period when a report waited for approval; a debate has never had
that state. The rule here is the one that governs the claim itself — frozen once somebody else has
rated — because a tag is part of what the claim was taken to be about.

This also closes the seam d8 left open. `DEBATE_DIMENSIONS` gains the reports' `tag` dimension
with the same attribute and the same chip, and the card renders labels rather than codes. A debate
the freshness overlay added carries no tags, because `debatesSince()` does not fetch them, so it
matches no tag filter until the next build — the same staleness the overlay has everywhere.

## 2026-08-22 — A source is not a citation, and it is two columns

Optional, at most one: an external `https` URL, or a report from this corpus.

**Not a citation.** `public.citations` records one page referencing another and produces a
"referenced by" entry at the far end. This is thinner: it says where the proposer got the idea,
and it is read once, above the scale, by somebody deciding whether the claim is well formed.

**Two columns and not one**, because a link into this corpus and a link out of it behave
differently. A report id resolves to a title, can be checked for existence, and leads somewhere
that will still be there; a URL can do none of those. Storing both as text would make every
consumer parse the string to find out which it held, and the first one to get that wrong would
render an internal id as a broken link.

The URL is validated to the same rules **and the same sentences** as a report's supporting links:
somebody who has met "Links have to start with https://" once should not meet a second,
differently worded refusal for the same mistake on another form. `on delete set null` on the
report reference: a report being erased must not take a claim with it.

The form makes the exclusivity structural rather than validated — three radios, and only one input
is ever on the page — so there is no state in which both hold a value and the submission has to
choose. `debates_one_source` refuses both anyway.

## 2026-08-22 — Grepping `dist/` for the controls, because this form has shipped two of them wrong

The brief was explicit and the history earns it: this page has previously shipped a `Field.astro`
counter stuck at 0, and controls addressed to a slot that does not exist.

So the checks were run against the built HTML rather than the source: both counters present and
wired, both textareas rendered as textareas rather than as `Field.astro`'s default text input,
twelve radios on the scale (eleven points and the off-scale answer), the tag picker's search box
and options container, all three source radios with their two panels, and no `maxlength="2000"`
left anywhere.

`wireCounters(form)` was already called on this page and now covers two counters instead of one.
`syncCounters(form)` is called after a successful submission, because `form.reset()` clears the
textareas and does not touch the counters that describe them — and `reset()` also restores the
source radios without closing the panels they revealed, which is done by hand for the same reason.

# The debates rebuild, in ten decisions

The entries above record each change as it was made. These ten are the load-bearing ones, stated
once each so the section can be understood without reading the whole log. Each names the longer
entry it summarises.

## 2026-08-22 — Debate contributions stay in `public.comments`, with rules conditional on the subject

A separate table would have meant touching everything that keys on a comment id: two FK columns
and a six-column unique constraint on `public.citations`, `public.activity.comment_id` and its
CHECK, `public.flags`, four branches of `public.moderate()`, `private.activity_label()`,
`private.enforce_daily_limit()` — which **raises on a table it does not know**, so a new one is
either a loud failure or silently unlimited — plus about ten sites in `src/lib/moderation.ts`.

Staying cost four objects: a column with no grant, one CHECK, a reissued guard, and
`comments_insert_own` **dropped and reissued** rather than supplemented, because permissive
policies are OR'd and a second one would grant round the rule. Every rule carries a
`parent_type` condition; a CHECK without one would silently change report threads, which are the
one place on this site where nesting is correct.

## 2026-08-22 — A contribution is grouped by the score stored when it was written, not the live rating

`comments.agreement_score` is copied from the author's rating by a trigger and frozen. A view
joining the live rating is one join shorter and wrong: somebody changing their mind would drag
every contribution they had ever written into a different group, retroactively, so the record of
what the community thought in March would become a record of what those same people think now.

The test asserts the column **after** the author has moved from "no opinion" to 7, because before
that the two designs are indistinguishable. The trigger overwrites what the client sent rather
than raising on a mismatch, so the protection does not depend on the column staying ungranted —
and it is ungranted.

## 2026-08-22 — NULL on a debate contribution means "no opinion", never "unset"

The off-scale answer is a NULL score on a **real** rating row, and the trigger refuses a
contribution from anybody holding no rating at all — so a contribution exists only where a rating
exists, and a NULL here can only have been copied from a NULL there. No sentinel, no coercion to
5, no companion boolean.

Three things share that null and only one of them is the off-scale answer: a report comment
argues from no position, a debate contribution declines, and a contribution from an export
written before the column existed has nothing recorded. `positionKnown` and `groupKeyFor()` keep
them apart. The third was being filed under "no opinion" — publishing a position its author never
took — and was found by reading built HTML, not by any check.

## 2026-08-22 — Who endorsed something is private, and the UI could not want more

`comment_endorsements_select_own` returns one person's own rows. Endorsing requires holding a
rating, ratings are readable only by their author, so a list of endorsers would publish the
private position of everyone on it by inference: "this captures my view" on a contribution
written from 8 places its endorser near 8, and hardest on the contributions written from 0 or 10.

Counts are public and come from the nightly export, because a browser cannot count rows it cannot
read. There is deliberately no function taking a comment id and returning people, and no
`SECURITY DEFINER` aggregate for live counts: `rating_aggregate` has one because a distribution
must be current the moment a reader answers, and an endorsement count is not that.

## 2026-08-22 — `public.rating_changes` produces one count and nothing else

No grant to any browser role, no policy, RLS on. The export takes `count(distinct user_id)` per
debate and the statistics line renders it. A readable per-person history is a public voting record
for a rating that is deliberately private — worse than exposing the rating, because a current
position is one fact and a trail through somebody's changes of mind is a record of how they think,
attached to a name, on a site whose contributors include people posting pseudonymously.

If a list of movements is ever wanted, it comes from **superseded contributions** — the positions
people made public by writing them down. It will be smaller than the count, and that gap is the
finding rather than a bug: more people change their mind than write about it.

## 2026-08-22 — Replies are removed on debates only

A debate is a map of positions; a reply is a position on a position, and a thread under a
contribution is how the map turns back into the chronological wall the section exists not to be.
A report thread is a discussion of one specific account, and a remark with the author's answer
under it is the shape of a referee's note — so it keeps its nesting, its replies, and its
window that closes on the first reply.

Written twice on purpose: `comments_debate_contributions_are_flat` and a clause in
`comments_insert_own`. Historical replies are rendered **flat rather than hidden** — a remark
somebody wrote is not a schema change's to withdraw. And the `:scope >` discipline stays in the
new component even though nothing nests there now, because those historical replies are in that
list.

## 2026-08-22 — The edit window closes on the first endorsement, in the guard

Twenty-four hours, and closed as soon as anybody says a contribution captures their view: they
agreed to the words in front of them, and unlike a reply there is no visible follow-up in which a
rewrite could be noticed.

**In the guard, not a policy.** Two permissive UPDATE policies are OR'd, and the soft-delete
policy has to permit an update at any age — so a window written into the edit policy is granted
straight back by the delete policy and withholds nothing while reading exactly like one that
works.

The guard reads `comments.endorsed_at`, stamped by a DEFINER trigger, because it can read neither
the endorsement table (own-rows-only, and the caller is the author, so an `exists` returns false
however many exist) nor a `private` helper (`authenticated` has no USAGE on that schema). The
stamp is never cleared, so a withdrawal does not reopen the window.

## 2026-08-22 — Contributions are not ranked by endorsement count by default

Most recent is the default order, in both views, and "most endorsed" is a choice the reader makes.
Nothing says where a contribution came in.

A vote count and a shared-reason count render identically as a number and do opposite things: one
ranks contributions against each other and rewards whoever phrased it most sharply, the other
measures how many people hold a reason. Defaulting to the count would make the first true whatever
the label said. So the label is always spelled out in words, and there is no heart, thumb, arrow,
`+1` or karma anywhere near it — audited in the built HTML.

## 2026-08-22 — Badges are suppressed on debate contributions, and only there

Name and date only: no verification status, no institution, no country. A contribution is read by
the position it argues from, and an institution beside it invites a reader to weigh the
affiliation instead of the reason.

A **rendering** rule on one surface. Nothing about what is stored or derived changes, the export
still carries the institution, and badges are untouched on report pages, entry pages, author pages
and report comments. Worth recording that this had been a stated rule in `CLAUDE.md` and was **not
implemented** until the surface was rewritten — `CommentThread.astro` rendered a badge on any
author with an institution, debate or not.

## 2026-08-22 — Divided and consensus, defined

Both computed at export time, never in the browser, over the **scored positions only** — the
off-scale answers are in neither, because "outside my expertise" is not a mild version of
agreeing.

- **divided** — twice the smaller of (share of 0–4) and (share of 6–10). Twice, so a clean 50/50
  scores 1. The *smaller* side, so 90/10 and 10/90 both score 0.2: the same shape seen from two
  directions. **The neutral 5s are in the denominator and in neither numerator**, so a debate
  where everybody sits at 5 is 0 divided — which a mean of 5.0 could not tell from a two-camp
  split.
- **consensus** — the largest share held by any one of five families: 0–1, 2–4, 5, 6–8, 9–10.
  Families rather than single scores, because 7 and 8 are not a disagreement.

Both are **null** below ten scored positions, and null is not zero: two people at opposite ends
are perfectly divided by the arithmetic and establish nothing. The null reaches the DOM as the
empty string, which the listing engine already sorts last — so "a fresh card is ineligible"
needed no new code path. What each measures, and the threshold, are stated beside the sort
control rather than in a tooltip.

## 2026-08-22 — The wording freeze needed a column, because nothing that asks can see

`023_submit_debate.test.sql` failed two assertions on the first run that got far enough to make
them: an author rewrote their claim after somebody else had answered it, and added a tag after
the same. Both succeeded. The rule was written correctly in two places and enforceable in
neither.

**A rating is readable only by its author.** `private.protect_debate_columns()` is SECURITY
INVOKER — it must be, because its `current_user` test is what tells a browser from the table's
owner — so its `exists (select 1 from public.ratings ...)` runs under the caller's own policies.
The caller is the claim's author, who can see exactly one rating: their own. The `debate_tags`
policies read the same table from the same position and fail identically, because a policy
subquery is evaluated as the caller too.

The version before this was broken differently and less visibly: it looked for *any* rating,
found the author's own when they had one and nothing at all when they had not — so the freeze
engaged on the author's own answer and never on anybody else's. It has never done what it says.

`debates.answered_at`, stamped by a DEFINER trigger on the first rating by somebody other than
the author, ungranted, frozen in the guard, and backfilled. **This is the second time this schema
met this shape in two days** — `comments.endorsed_at` exists for the identical reason on
`comment_endorsements` — and it was documented at the time, which did not stop it recurring one
migration later on a different own-rows-only table. It is now a trap entry rather than an
anecdote.

Worth noting what did catch it: not review, and not `astro check`. A pgTAP assertion written from
the browser's side, under `set local role authenticated`, on a rule whose failure mode is silence.

## 2026-08-23 — Two questions, because "does this still work?" is nonsense on a failure

The confirmation control asked one question of every report from the day it was built: *Does this
still work?*, answered `still_works` or `no_longer_works`. On a report whose outcome was `failed`,
both answers were claims its author had not made. Somebody who rechecked a failure and found that
it still failed — which is exactly the work this feature exists to collect, and the cheapest
contribution anyone can make to the corpus — had no way to say so, and the nearest available
answer was the one that meant the opposite.

Two questions now, chosen by the report's outcome: *does this still work?* for `worked` and
`partial`, *does this still not work?* for `failed`.

**Four enum values, not two neutral ones.** `reproduced` / `changed` would have been a smaller
enum and would have kept the wording entirely in the frontend. It was refused because the corpus
is downloadable and every row in it should stand alone: a researcher reading `latest_verdict` out
of the CSV must be able to tell which question was asked without joining the report back to find
its outcome, and `changed` cannot say whether a tool stopped working or started. Adding values
also reinterprets nothing — the two original names keep the exact meaning they were written with.

**The pairing cannot be a CHECK,** since the verdict and the outcome are on different tables, so
it is two BEFORE triggers: one refusing a verdict from the wrong pair, one refusing an outcome
change that would strand a verdict already filed. Both are needed because there are two ways to
break the rule. The second is reachable only through the author's own confirmation of their own
report, which does not set `answered_at` and so does not freeze anything — that is the one hole
the existing freeze leaves.

Neither guard exempts `service_role` or the table owner, which is a deliberate departure from
`private.protect_report_columns()` next door. That one is about privilege, and an administrator
repairing data is not the author it defends against. These two are the cross-table CHECK constraint
Postgres will not let us write, and a CHECK exempts nobody either.

**The pairing is written out three times** — twice in SQL, once in `verdictsFor()` in
`src/lib/status.ts` — and the duplication is not laziness. `authenticated` holds no USAGE on the
`private` schema, so a shared `private.verdicts_for_outcome()` helper called from inside a
SECURITY INVOKER trigger body is refused with 42501 at the moment a user tries to confirm
something. The alternative is a public function granted to browser roles, which is a permanent API
surface for an implementation detail.

**The trigger's name is load-bearing.** BEFORE ROW triggers fire in alphabetical order, and a WHEN
clause sees NEW as earlier triggers have already modified it. `reports_protect_columns` reverts the
outcome on a frozen report and lets the statement succeed having changed nothing, which is relied
on: an author who sends one UPDATE that both deletes their report and sneaks a content change gets
the deletion and none of the sneak. `reports_verdicts_match_outcome` sorts after it on purpose, so
the revert lands first and the raise never happens. Rename it to anything sorting before `p` and a
frozen report's harmless no-op becomes an exception that aborts the legitimate half of the same
statement. `024_confirmation_by_outcome.test.sql` asserts the no-op rather than the ordering,
which is the assertion that survives somebody not knowing why.

**`broken` became `changed`,** and this is a rename in the published dataset rather than an
addition. The label "No longer works" is right for a success that stopped and states the opposite
of what happened for a failure somebody has since got working. The status means "somebody
rechecked this and found something different"; the words for it are composed from both axes in
`verificationOf()`, which is how a tombstone's accessible name has always been assembled. The
dataset carried no `broken` rows, so nothing had to be migrated.

**A reproduced failure fills the square.** `src/lib/status.ts` has said since it was written that
"a report can report 'did not work' and still be verified and current" — the axes were always
meant to be independent. The question was simply never asked in a form that let anybody say it.
This is the same rule the rest of the project states as *failures are first-class content*, and
the tombstone was quietly the one place it was not true.

## 2026-10-10 — The Supabase CLI is pinned in CI, and moving the pin is a deliberate act

`test-db.yml` installed the CLI with `version: latest`. The suite went red on a commit that had
passed in August, with nothing under `supabase/` changed in between: 45 assertions across 15
files, every one of them a `throws_ok(..., '42501')` that caught no exception at all. The CLI
version chooses the image tags `supabase start` pulls. `supabase/postgres` had moved
`17.6.1.159` -> `17.11.0.004`, and under the newer image `anon` and `authenticated` hold
privileges these migrations never grant — INSERT and DELETE on `profiles`, UPDATE on `role` and
`is_banned`, SELECT on `ratings`, `flags` and the activity feed.

**A floating version is worse on this job than on any other**, because the thing that drifts is
the grant baseline, and the grant baseline is what the suite exists to police. The failure is
indistinguishable by eye from somebody having widened a grant in a migration; it lands on a branch
that changed no SQL; and it surfaces on whichever pull request happens to be open — here
`confirmation-by-outcome`, which wore the blame for it until the same workflow was dispatched
against `main` alone and failed identically. Pinned to `2.115.0`, the last release before the
known-good run of 2026-08-22.

`migrate.yml` and `ror-verify.yml` take the same pin. `ror-verify.yml` runs `supabase start` and
has the identical exposure. `migrate.yml` does not, but it holds write access to the production
database, and `latest` there meant the tool applying the SQL could differ from the one the gate
proved it against.

Bumping the pin is its own branch: raise it, diff `role_table_grants` for the two browser roles
against this version, and revoke whatever widened in a migration. The alternative — relaxing the
assertions until they pass — would retire the only check that noticed.

## The Activity link is permanent; the count is the notification

*2026-10-11.* The header's "Activity" link used to be hidden until the stored unread count was
above zero, so the whole control appeared and vanished. A reader who noticed it once had no way
to find it again, and a nav item that pops in reads as a glitch rather than as news.

Now the link is shown to every signed-in reader on every page, and only the count beside it comes
and goes. The count is a filled accent tab with square-ish corners rather than the bare accent
digits it used to be: with the link always present, bare digits were too easy to miss. This
reverses the earlier "not a filled shape" note in `Base.astro`; a round bubble is still out.

Unchanged on purpose: the count is still a `localStorage` hint (the header may not ask the
database), it is cleared only by opening the activity page, and endorsements still do not
generate activity.

## The header checks for new activity on every page, with plain fetch

*2026-10-11.* The count behind the Activity badge used to be written only by pages that already
loaded the Supabase client, so a notification could sit unseen for as long as somebody kept to
listings. The header now makes one check per page load (throttled to once per 30 seconds): two
plain `fetch` GETs against PostgREST — the watermark, then a head count — using the access token
the client left in `localStorage`. No Supabase client reaches a reading page.

It **never refreshes the token**. Refreshing rotates the refresh token, and doing that from here
while the real client does it in another tab is how somebody ends up signed out. An expired token
(about an hour after the client last ran) means no check and a badge that stays as it was until an
account or comment-thread page wakes the client. So "as soon as possible" is "on every page while
the session token is fresh". Making it unconditional would need a small database function or the
client itself on every page, and was not worth either. The check is skipped on the activity page,
which zeroes the count and would otherwise race it.

## A sixteenth section: "What you learned"

*2026-10-11.* Schema version 3 adds an optional section with a yes/no answer to *Did you learn
something new?* and a note of up to 1000 characters elaborating on it. Migration
`20261011100000_report_learned_something.sql`, tests in `025_report_learned_something.test.sql`.

Choices worth keeping:

- **Radios, not checkboxes.** Two tick-boxes can both be ticked and cannot tell "no" from "did
  not answer". The radios start unselected, as the scales do, so `learned_something` is a nullable
  boolean where null is "not answered".
- **Appended as section 16, not placed after Outcome.** Inserting mid-form renumbers ten sections
  in `SECTIONS`, the docs and the progress counter for no gain a reader would notice.
- **A note needs an answer** (`reports_learned_notes_need_an_answer`), the same shape as the
  disclosure-needs-publication rule. The form says so first; the RPCs say it in a sentence; the
  constraint is the truth.
- **Asked of every outcome.** A failed attempt that taught something is a "yes" like any other,
  and the display words both answers the same way. This is *failures are first-class content*
  applied to a new question.
- **It sits beside the novelty and understanding scales rather than replacing them.** Those are
  conditional 0-to-10 scales about what the tool contributed; this is unconditional and carries a
  sentence. The hint says "about the mathematics, the tool, or how to work with it" because this
  audience will otherwise ask which was meant.
- **Existing rows stay at version 2 and the default moves to 3.** A version 2 row was never asked.
  The guard freezes `schema_version`, so a version 2 report edited later to add an answer stays
  at 2 — a small untruth in a rare case, accepted over letting a caller move the version.
- **No listing filter or sort.** Nothing needs one yet; `report-facets.ts` is where it would go.

## What the debate orderings mean moved to the About page

*2026-10-11.* This reverses the placement (not the principle) of *What "most divided" measures is
on the page, not in a tooltip* (2026-08-22). The three-part note beside the sort control was hard to
read: it opened with "twice the smaller of the two sides", which is the formula rather than the idea,
and it sat above the list on every visit although nobody needs it more than once.

It is now one paragraph in the About page under *How debates are ordered*, stated as what each
ordering puts first and why, with the formula dropped from the prose (`DEBATE_SORTS` in
`src/lib/listings.ts` and CLAUDE.md still hold it). The principle stands: the ranking is explained
in words, not in a tooltip, and the minimum of ten positions is still read from the export's
`sortableMinimum` rather than typed in, now by `about.astro`.

Removed with it: the `sort-note` slot in `Listing.astro`, which nothing else filled, and `.sortnote`
in `corpus.css`. The sort control on /debates/ no longer has an explanation beside it. If readers
cannot find the About paragraph, a link from the sort label to `/about/#debate-orderings` is the
first thing to try; the anchor exists for that.

## A position needs a reason, and the reason arrives with it

*2026-10-11.* Joining a debate somebody else proposed now means a point on the scale **and** a
reason: an endorsement of at least one existing contribution, or a contribution of one's own,
submitted in the same form. Before this, a rating was saved alone and the reason came afterwards,
optionally. Most positions arrived with nothing explaining them, and the groups filled with counts.
That is the feed the governing sentence says a debate is not. Migration
`20261011110000_answer_debate.sql`, tests in `026_answer_debate.test.sql`.

- **A deferred constraint plus one INVOKER RPC**, the shape *Submission is one RPC, because a
  deferred constraint made it one* (2026-08-15) already records. It cannot be a policy, because it
  is about rows in three tables. The order is forced: the comment trigger and the endorsement
  policy both need the rating at row time, so the rating goes first and the check waits for commit.
  PostgREST commits every request alone, so the client cannot do it in three calls.
  `public.answer_debate()` does it in one.
- **The check is DEFINER and the RPC is INVOKER**, and neither is the trap. The check asks which
  rows exist and must see endorsements, which are own-rows-only. The RPC writes under the caller's
  own policies, so bans, confirmation and the author-cannot-endorse-own rule all still decide. The
  ban count stays nine. The check is in `private`, so there is no new Security Advisor warning.
- **"No opinion" is exempt.** Requiring prose for declining would push people to pick a number,
  and a 5 picked to avoid writing a paragraph is what the off-scale answer exists to prevent.
- **Changing from one score to another stays free**: 2026-08-22's invitation-not-requirement stands.
  **"No opinion" to a score does not.** It is a first position, and exempting it would make the
  rule a two-step bypass. A second constraint trigger with a `WHEN` clause covers that case only.
- **Checked at answering time, not kept as an invariant.** Withdrawing the endorsement or deleting
  the contribution later leaves the rating standing. Keeping it as an invariant would mean
  deleting someone's answer when they delete their words, and the position is part of the record.
- **New answers only.** The triggers fire on insert and on the NULL-to-score update, so a rating
  written before this date is never examined. The test simulates one by disabling the trigger
  around an insert.
- **The form offers contributions at the chosen score first**, then the rest behind a control,
  because "I agree with the position, but not this reason" is often said of a reason written a
  point away. Those copies carry no `id`, so `#comment-<id>` stays unique.
- **The contributions appear twice in the HTML**, in the form and in the section below. The
  alternative was a form spread across the page, where a reader cannot tell what one button saves.
- **The form errs towards asking.** Where it cannot know whether the reader already contributed
  (an endorsement made in another tab; anything on `/debates/view/`), it requires a reason the
  database might not have needed.

## 2026-10-11 — The site rebuilds when its content changes

Until now the export ran on a schedule only. GitHub starts scheduled jobs hours late (the 03:17
run was starting around 10:00 UTC), so a post, an edit, an endorsement, a new display name or a
moderator's hide could wait most of a day to reach the pages other people read. To the person who
had just done it, that looked like the site not working. The export takes about twenty seconds
and the deploy under a minute, so the slow part was only the waiting to be asked.

Now the database asks for the export itself, within a minute of a write (`20261011120000`):

- **A counter, not a call per write.** A statement-level trigger on every table the export reads
  moves `private.export_queue.generation`. `pg_cron` runs `private.dispatch_export()` each minute,
  and that asks GitHub for `export.yml` only if the counter has moved since the last time. So the
  database makes at most one request a minute, and `export.yml`'s concurrency group keeps at most
  one run waiting.
- **A counter, not a timestamp.** `now()` is when a transaction started, so a write that began
  before a dispatch and committed after it would carry an earlier time and never be asked for. The
  dispatcher locks the row first, which waits for any uncommitted increment.
- **`pg_net`, not an Edge Function.** This is the outbound call at request time that the
  2026-08-13 Supabase entry allows for, and making it from Postgres keeps it in the place logic
  lives. Both extensions are on the free plan.
- **The token is in Supabase Vault.** It is a fine-grained GitHub token that can only start
  workflows on this repository, stored by hand (`docs/auth.md`). It is never in a migration, the
  repository or the browser. Without it the dispatcher does nothing, which is also what keeps CI
  from calling GitHub.
- **The nightly run stays**, as the keep-alive the 2026-08-16 entry describes and as the fallback
  if the token lapses. `scripts/export.mjs` reads the last dispatch's HTTP status and puts a warning
  on the run when it was not a success, so a lapsed token shows up there rather than as a site
  that quietly went back to updating once a day.
- **Cost:** one export commit per minute in which something changed. `data/` is a few tens of
  kilobytes; if history size ever matters, the commits can be squashed without losing the dataset.

This amends the 2026-08-13 read/write split entry: content is now minutes stale, not up to a day.
Reads still never reach the database, and every reason given there still holds.

## 2026-10-11 — What you write is set as soon as you post it

Until now a comment or contribution written or edited in the browser was shown as its markdown
source, in monospace, until the next build. That was nightly and, in practice, the next morning.
To the person who had just posted, a formula as `$\pi_1(X)$` read as a broken site. With the site
now rebuilding within minutes of a write, the remaining gap is small enough to close.

- **The build's own pipeline, run in the browser.** `src/lib/render-live.ts` imports
  `renderMarkdown()` from `src/lib/markdown.ts` as it is, with the same sanitising schema and
  KaTeX's `trust: false`, so a comment set in the browser and the same comment set at the next
  build are the same HTML. This reverses the 2026-08-15 entry. Its two objections:
  - "Shipping a parser and KaTeX to every reader": answered by a dynamic import. The renderer is
    a chunk of its own, about 430 KB before compression, fetched only by a page that has
    something to set. An ordinary page view never loads it, which was checked in the built
    output.
  - "Sanitising in the one place an attacker controls": does not apply. Nothing produced is
    stored. Each reader's browser sanitises text the database handed back, with the schema the
    build uses, so an attacker controls only their own copy.
- **Edits start from the source.** The edit box used to be pre-filled from the rendered text, which
  silently rewrote every formula as plain text on save. It now reads the comment's source first.
- **Item pages get the overlay too.** Debate and report pages ask once for comments changed after
  the export they were built from (`updated_at` moves on every edit, deletion, supersession and
  endorsement stamp), then add new ones in their position group and patch edits and deletions in
  place. That covers the minutes before the rebuild lands, and the ten minutes GitHub Pages lets
  a browser cache a page. The reports overlay used to add only.
- **What the overlay does not do.** Other people's endorsement counts, the statistics line, display
  names and hides arrive with the rebuild. Counting endorsements in the browser would need a new
  DEFINER function, a seventh Security Advisor warning, to save about two minutes.
- **View pages hand over.** `/reports/view/` and `/debates/view/` go to the built page once it
  exists, keeping the fragment. The activity feed always links to a view page, and
  `/debates/view/?id=…#comment-…` used to land on "Nobody has written a contribution yet".
- **Not done: an "edited since this page was built" line on a report.** `reports.updated_at` also
  moves when somebody first answers a report, so the line would appear on reports nobody edited.

## 2026-10-12 — Debates are Opinions; one item is a claim

The section is **Opinions**, and one item in it is **a claim**, the word the copy already used for
the statement. The split follows the network precedent, where the collection is `/network/` and a
row is a `network_entries` row of kind `'entry'`. Only the collection says "opinions": the route
`/opinions/`, the nav, headings and page titles. Everything that names one row says "claim":
`public.claims`, `claim_tags`, `claim_id`, the `claim_ratings` view, enum label `'claim'`,
`submit_claim()`, `answer_claim()`, `src/lib/claims.ts`, `ClaimCard.astro`, `data/claims.json`.

- **The schema moved too**, for the reason the 2026-08-17 rename gave: the schema is the corpus's
  public surface, named in CSV headers and in every query against a dump, and two names for one
  table would be a cost paid forever. Migration `20261012120000` changes no behaviour.
- **"Claim" for a row, not "opinion".** `opinion_count` and `no_opinion_count` already count scored
  positions, and "a no-opinion answer on an opinion" reads badly. Both columns keep their names, and
  so does the answer "No opinion, or outside my expertise", which reads naturally on a page called
  Opinions. The about page's "first-hand accounts rather than general opinions" contradicted the
  new section name and now says "general impressions".
- **The old addresses redirect.** `src/pages/debates/` holds only stubs, a meta refresh with an
  inline `location.replace()` that keeps the query and the fragment. So `?position=` and
  `#comment-<id>`, which the activity feed hands out as real addresses, survive the move.
- **`data/` was rewritten by hand once, in this PR.** That is a one-time exception to "written only
  by `scripts/export.mjs`". The deploy builds from committed `data/`, and without the rewrite the
  section would have built empty until the first export after the merge. The check is the next
  export, which should touch nothing but `exportedAt`.
- **`formatVersion` is in the manifest**, at `2`. It is absent before, which means `1`. It numbers
  the layout of `data/` (file and field names, value vocabularies), not the reporting standard,
  which is each report's `schemaVersion`, and it rises when a downstream reader has to change.
  `data/README.md` carries the old-to-new table.
- **The word cannot come back quietly.** The migration ends with an assertion over object names,
  constraints, triggers, policies, functions, types, enum labels, attributes, function bodies and
  object comments, and `028_claims_vocabulary.test.sql` repeats it so a later migration fails CI.
