# Contributing to MathemAct

MathemAct is a small project maintained by one person with volunteer moderators. Most
contributions happen through the site itself — submitting a report, answering a claim,
suggesting an entry — and that is the most valuable thing anyone can do.

This file is for people who want to contribute to the code or the database schema.

## Before you start

Read [CLAUDE.md](CLAUDE.md). It contains the constraints that every decision is built
around — zero budget, static hosting, no secrets in the client, no Google Fonts CDN,
logic in Postgres, and more. A contribution that violates a hard constraint will not be
merged regardless of how well it is written.

## Getting set up locally

```sh
git clone https://github.com/MathemAct/MathemAct
cd MathemAct
npm install
cp .env.example .env          # fill in SUPABASE_URL and SUPABASE_ANON_KEY
npm run dev                   # Astro dev server at http://localhost:4321
```

The site builds from `data/`, which is committed. A fresh clone builds immediately
without a database connection. You will need Supabase credentials only if you are working
on a feature that writes to the database.

## Database

**Never edit a migration that has already been applied.** Migrations are append-only.
If you need to change something, add a new migration in `supabase/migrations/` with the
next timestamp in the filename.

Every migration file starts with a comment saying what it does and why.

Database tests live in `supabase/tests/`. They run in CI on every branch. There is no
container runtime on the development machine, so `supabase start` cannot run locally —
the test run in CI is the one that matters.

```sh
# Apply a migration (requires supabase CLI and project link):
supabase login
supabase link --project-ref <ref>
supabase db push
```

See `docs/decisions.md` for the reasoning behind non-obvious choices.

## Opening a pull request

1. Branch from `main`.
2. Make one coherent change per branch. A PR that adds a feature and refactors unrelated
   code is harder to review.
3. Run `npm run build` before pushing. Fix any TypeScript errors or warnings.
4. If your change touches the database schema, update `supabase/tests/` and verify the
   tests pass in CI before asking for review.
5. Update `docs/decisions.md` if you made a non-obvious choice.

## Moderation

MathemAct can count on a couple of volunteer moderators. They are not gatekeepers for content:
anything users post is published right away, withouth needing a review. However, moderation exists
as a tool to make sure that the content of the website doesn't violate the
[/code-of-conduct/](docs/code-of-conduct.md). 
Users have the possibility to flag content if they deem it inappropriate. A moderator then
decides whether it stays up and writes an explanation that both the author and the flagger read.
For serious and repeated violations, accounts can be banned. Banned users can still access the
site, but in read-only mode, they can't post anything. The content they have already posted stays
up, but each contribution can be flagged and reviewed as any other post and comment can. Banned
users can appeal the decision and a second moderator will review it.
The moderation screen is at `/moderate/`. There is no navigation link to it — it is documented in
`docs/moderation.md`, which is where new moderators are pointed.

## Reporting a bug

Open a GitHub issue. Include enough to reproduce it: what you did, what you expected,
what happened instead. A screenshot helps.

## Contact

For anything that should not be public: matesimpatica@gmail.com
