# ROR data

The institutional badge is derived by matching a confirmed email domain against the
**Research Organization Registry**. This is where that data comes from, what it costs, and
what it does not cover.

## Licence

ROR data is released under **[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)**,
a public domain dedication. There is nothing to attribute, no terms to accept, and no
restriction on redistribution — the dump can be loaded, transformed, and included in our
own exports without qualification.

We credit ROR anyway, on the about page and here, because it is a community-run public
good and saying where the data came from is the whole point of a disclosure project.

## Where the dump comes from

Releases live on Zenodo under a **concept DOI** that always resolves to the newest one:

> **<https://doi.org/10.5281/zenodo.6347574>**

Download the `.zip`, unzip it, and pass the JSON file to the loader. Do not commit it: it
is 290 MB unzipped, it changes on ROR's schedule rather than ours, and a copy in the
repository would go stale silently. It is in `.gitignore` by extension — keep it outside
the working tree.

### The release this was built against

| | |
|---|---|
| Version | `v2.11` |
| Published | 2026-08-03 |
| DOI | [10.5281/zenodo.21773148](https://doi.org/10.5281/zenodo.21773148) |
| Archive | `v2.11-2026-08-03-ror-data.zip`, 34 MB |
| JSON | `v2.11-2026-08-03-ror-data.json`, 291 MB |
| Records | 135,710 |

### A naming change worth knowing about

Releases from **1.45 (2024-04-11) to 1.74 (2025-11-24)** shipped both schema versions in
one archive, and the v2 file ends `_schema_v2.json`. From **2.0 (2025-12-16)** onward
there is only schema v2 and the suffix is gone, e.g. `v2.11-2026-08-03-ror-data.json`.

The loader reads schema v2 only. If it reports that the file is not a ROR dump, check
that you unzipped it and passed the `.json` rather than the `.csv`.

## Loading it

```sh
# Parse and report without touching any database. Needs no credentials.
node scripts/load-ror.mjs path/to/v2.11-2026-08-03-ror-data.json --dry-run

# Load for real.
export SUPABASE_DB_URL="postgresql://..."     # $env:SUPABASE_DB_URL in PowerShell
node scripts/load-ror.mjs path/to/v2.11-2026-08-03-ror-data.json
```

The load is one transaction. It stages the whole dump, upserts, and then **deletes rows
the dump no longer contains** — a pure upsert would leave a withdrawn institution handing
out badges forever. If a load would more than halve the table it refuses, on the
assumption that a partial file was passed by mistake; `--allow-shrink` overrides that.

Profiles are untouched by a reload. `profiles.institution_name` and
`institution_country` are a point-in-time snapshot with deliberately no foreign key, so a
data refresh cannot rewrite anyone's badge or fail because someone holds one.

## Refresh quarterly

ROR publishes roughly monthly. **Reload once a quarter**, and after any ROR schema
announcement.

Quarterly rather than monthly because the cost of being slightly behind is small and
bounded — a new institution's staff cannot get a badge until the next load — while the
cost of an unattended automated load against production is not. Someone should be watching
when the institution table is rewritten.

`.github/workflows/ror-verify.yml` runs monthly on a throwaway database: it downloads the
current release, runs the loader against it, and reports what the matcher makes of a list
of real mathematics institutes. That catches a schema change on disposable infrastructure
before anyone runs a real load. It never touches production.

## What gets loaded, and what gets skipped

Only four fields are extracted: the ROR id, the `ror_display` name, the country code and
name from the first location, and every entry in `domains`. Domains are lowercased, a
leading `www.` is stripped, and anything that is not a plausible hostname is dropped.

From v2.11:

```
records read              135,710
institutions loaded       132,706
domains loaded            116,985
  from ROR domains         31,125
  derived from website     85,860

skipped entirely            3,004   (inactive 1,595, withdrawn 1,409)
```

**Every active record becomes an institution row, whether or not it has a domain.** The
two tables are loaded independently on purpose: `private.manual_domains` exists to give a
domain to an institution ROR left without one, and it can only do that if the institution
is there to be named. Loading only institutions that already had a domain made the manual
table unable to serve its own purpose — `mpg.de` matched the Max Planck Society and then
resolved to nothing, so the badge was silently withheld.

## The gap, and the three layers that close it

**ROR's `domains` field is mostly empty.** 101,926 of 135,710 records have none. Broken
down, the number that matters is worse than the headline:

| Type (Europe, Israel, Turkey) | records | with a domain |
|---|---:|---:|
| education | 6,110 | **41.1%** |
| facility | 8,017 | 21.7% |
| funder | 6,824 | 38.0% |
| healthcare | 5,081 | 14.9% |
| company | 16,404 | 8.0% |

**Fewer than half of European universities carry a domain in ROR.** Not obscure ones:
Antwerp, Mannheim, London South Bank, Westminster, St Petersburg, and — pointedly, given
whose declaration this project works under — Leiden.

So a domain now comes from one of three layers.

### 1. `ror_domain` — ROR's curated field

Authoritative, unmodified. 31,125 domains in v2.11.

### 2. `ror_website` — derived by the loader, only when unambiguous

For a record with no curated domain, the host of its own recorded website is used, but
**only if that host is claimed by exactly one record in the entire dump**. Measured on
v2.11, the loader refuses:

| refused | count | why |
|---|---:|---|
| already curated by another record | 752 | would issue a **wrong** badge |
| claimed by 2+ records | 3,196 | ambiguous |
| a public or shared suffix | 9 | `ac.uk`, `github.io`, and friends |
| parent of ≥3 curated domains | 49 | would swallow every child's mail |

and accepts 85,860. That recovers most of the missing European institutions
automatically, with no human curation.

The last guard earns its keep. It caught `min-saude.pt` — the Portuguese health ministry's
domain — about to be attributed to one hospital whose website is a page on it, and
`europa.eu` about to become the European Council. Both would have badged thousands of
people wrongly. Those cases are reported by the loader for a human to decide instead.

An earlier version of this document said we should never derive from the website field,
on the grounds that Leiden's recorded site is `leiden.edu` while its staff write from
`@leidenuniv.nl`. That reasoning was wrong, and worth recording as wrong: a vanity domain
nobody sends mail from produces a **useless** entry, not a harmful one — the badge is
absent either way. The genuinely dangerous cases are the collisions, and those are exactly
what the uniqueness rule detects.

### 3. `manual` — added by hand, with evidence

`private.manual_domains`, for what the other two cannot reach. Each row records who added
it, when, and why, in enough detail for someone else to re-check. This table is the only
one here whose contents are **our** responsibility rather than ROR's, and it should stay
small.

Seeded with the institutions found missing while loading v2.11:

| Domain | Institution | Evidence |
|---|---|---|
| `mpg.de` | Max Planck Society | website in ROR record `01hhn8329` |
| `mis.mpg.de` | MPI for Mathematics in the Sciences | website in ROR record `00ez2he07` |
| `mpim-bonn.mpg.de` | MPI for Mathematics, Bonn | website in ROR record `02dh8ja68` |
| `mfo.de` | Oberwolfach | website in ROR record `001zbj766` |
| `mittag-leffler.se` | Institut Mittag-Leffler | website in ROR record `02z85gz67` |
| `leidenuniv.nl` | Leiden University | published staff addresses at `math.leidenuniv.nl` |

`mpg.de` alone covers every Max Planck institute that has no entry of its own, by
longest-suffix. The Leiden row is the one to re-check against the university directly:
ROR's recorded site is `leiden.edu`, and the mail domain was established from published
staff addresses rather than from ROR.

### Precedence

**Longest suffix wins first**, because a more specific domain names a more specific
institution and that is a question of correctness. **Source breaks ties only at equal
length**, where it is a question of trust: `manual` > `ror_domain` > `ror_website`.

So `mis.mpg.de` beats `mpg.de` regardless of where each came from, and a manual entry
overrides a curated one for the identical domain. The block list still overrides
everything, including a mistaken manual entry — a human error is still an error.

### Provenance is recorded on the badge

`profiles.institution_source` stores which layer issued each badge. It is never displayed:
the badge claims "an address at this institution's domain was confirmed on this date",
which is equally true whichever table supplied the domain. It exists so that if a derived
domain later proves wrong, the badges it issued can be found and revoked rather than
guessed at.

## What this still does not solve

A researcher at an institution ROR has never heard of, or one who works from a personal
address, still gets no badge. No domain-matching scheme fixes that; it needs a request and
review path, where a user states their affiliation and a moderator checks it. That is a
separate piece of work and it needs the moderation tooling to exist first.

Contributing the missing domains upstream to ROR remains worth doing regardless. It helps
everyone rather than only us, and every accepted contribution shrinks layers 2 and 3.
