#!/usr/bin/env node
/**
 * Load a ROR data dump into private.ror_institutions and private.ror_domains.
 *
 *   node scripts/load-ror.mjs <path-to-ror-data.json> [--dry-run] [--allow-shrink]
 *
 * Run locally, against the production database, using SUPABASE_DB_URL from the
 * environment. See docs/ror.md for where the dump comes from and how often to refresh it.
 *
 * Why this streams rather than reading the file
 * ---------------------------------------------
 * The v2 dump is ~290 MB of JSON for ~132,000 organisations. JSON.parse on that needs
 * something like 2 GB of heap and dies with an unhelpful allocation failure on a laptop.
 * The scanner below walks the top-level array one object at a time, tracking string and
 * escape state so that braces inside values do not confuse it, and never holds more than
 * one record plus a buffer tail. It takes no dependency to do it.
 *
 * Why it reconciles rather than only upserting
 * --------------------------------------------
 * A pure upsert is idempotent but not correct over time: when ROR withdraws a record or
 * drops a domain, the stale row would sit here forever, still handing out badges for an
 * institution that no longer claims that domain. So the load stages everything, upserts,
 * and then deletes what the dump no longer contains. Profiles are unaffected — the
 * institution on a profile is a point-in-time snapshot with no foreign key, exactly so
 * that a data refresh can never rewrite somebody's badge.
 *
 * The whole thing is one transaction. A failure halfway leaves the previous data intact.
 */
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import process from 'node:process';

const ZENODO_CONCEPT_DOI = '10.5281/zenodo.6347574';

const USAGE = `
Load a ROR data dump into the private schema.

  node scripts/load-ror.mjs <path-to-ror-data.json> [options]

Options
  --dry-run        Parse and report. Touches no database and needs no credentials.
  --allow-shrink   Permit a load that would remove more than half the existing rows.
  --batch <n>      Rows per insert statement (default 1000).

Getting the dump
  1. Open https://doi.org/${ZENODO_CONCEPT_DOI}
     That is the Zenodo "concept" DOI and always resolves to the newest release.
  2. Download the .zip for the latest version and unzip it.
  3. Pass the path to the JSON file, for example:
       v2.11-2026-08-03-ror-data.json

     Releases before 2.0 (2025-12-16) shipped two schemas in one zip; in those, the
     file you want is the one ending _schema_v2.json. This script reads schema v2 only.

  The dump is published under CC0 1.0 (public domain dedication), so there is nothing
  to attribute and nothing to agree to. It is deliberately not downloaded automatically
  and never committed: it is 290 MB, it changes on ROR's schedule rather than ours, and
  a copy in the repository would rot silently.

Database
  Set SUPABASE_DB_URL to the connection string before running without --dry-run:

    $env:SUPABASE_DB_URL = "postgresql://..."      # PowerShell
    export SUPABASE_DB_URL="postgresql://..."      # bash
`;

// ── Argument handling ────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const options = { path: null, dryRun: false, allowShrink: false, batchSize: 1000 };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--dry-run') options.dryRun = true;
    else if (arg === '--allow-shrink') options.allowShrink = true;
    else if (arg === '--batch') options.batchSize = Number.parseInt(argv[++i] ?? '', 10);
    else if (arg === '--help' || arg === '-h') return null;
    else if (arg.startsWith('-')) throw new Error(`Unknown option: ${arg}`);
    else if (options.path === null) options.path = arg;
    else throw new Error(`Unexpected extra argument: ${arg}`);
  }

  if (options.path === null) return null;
  if (!Number.isInteger(options.batchSize) || options.batchSize < 1) {
    throw new Error('--batch must be a positive integer');
  }
  return options;
}

// ── Streaming reader ─────────────────────────────────────────────────────────────────

/** A problem with the input rather than a bug. Reported as a sentence, not a stack. */
class DumpError extends Error {}

const isWhitespace = (ch) => ch === ' ' || ch === '\n' || ch === '\r' || ch === '\t';

/**
 * Yield each object of a top-level JSON array without holding the whole file.
 */
async function* readRecords(filePath) {
  const stream = createReadStream(filePath, { highWaterMark: 1 << 20 });
  const decoder = new TextDecoder('utf-8');

  let buffer = '';
  let cursor = 0;
  let sawArrayStart = false;
  let objectStart = -1;
  let depth = 0;
  let inString = false;
  let escaped = false;

  function* drain() {
    while (cursor < buffer.length) {
      const ch = buffer[cursor];

      // Between records: skip whitespace, commas, and the array brackets.
      if (objectStart === -1) {
        if (!sawArrayStart) {
          if (isWhitespace(ch) || ch === '﻿') {
            cursor++;
            continue;
          }
          if (ch !== '[') {
            throw new DumpError(
              'That file is not a ROR JSON dump: it does not start with a JSON array. ' +
                'If you passed the .csv from the archive, pass the .json instead.',
            );
          }
          sawArrayStart = true;
          cursor++;
          continue;
        }
        if (ch === '{') {
          objectStart = cursor;
          depth = 0;
          inString = false;
          escaped = false;
        } else {
          cursor++;
          continue;
        }
      }

      // Inside a record. Strings are tracked so that a brace in a value cannot end it.
      if (escaped) {
        escaped = false;
        cursor++;
        continue;
      }
      if (inString) {
        if (ch === '\\') escaped = true;
        else if (ch === '"') inString = false;
        cursor++;
        continue;
      }
      if (ch === '"') {
        inString = true;
        cursor++;
        continue;
      }
      if (ch === '{') depth++;
      else if (ch === '}') {
        depth--;
        if (depth === 0) {
          const text = buffer.slice(objectStart, cursor + 1);
          cursor++;
          yield JSON.parse(text);
          buffer = buffer.slice(cursor);
          cursor = 0;
          objectStart = -1;
          continue;
        }
      }
      cursor++;
    }

    // Drop what has been consumed, but only when not part-way through a record.
    if (objectStart === -1 && cursor > 0) {
      buffer = buffer.slice(cursor);
      cursor = 0;
    }
  }

  for await (const chunk of stream) {
    buffer += decoder.decode(chunk, { stream: true });
    yield* drain();
  }
  buffer += decoder.decode();
  yield* drain();
}

// ── Extraction ───────────────────────────────────────────────────────────────────────

const ROR_ID_PATTERN = /^0[0-9a-z]{8}$/;

/** "https://ror.org/052gg0110" -> "052gg0110" */
function extractRorId(id) {
  if (typeof id !== 'string') return null;
  const candidate = id.trim().split('/').pop()?.toLowerCase() ?? '';
  return ROR_ID_PATTERN.test(candidate) ? candidate : null;
}

/**
 * ROR v2 carries several names per record; exactly one is marked `ror_display` and that
 * is the one a badge should show. `label` is the documented fallback.
 */
function extractName(record) {
  const names = Array.isArray(record.names) ? record.names : [];
  const byType = (type) =>
    names.find((n) => Array.isArray(n?.types) && n.types.includes(type) && n.value?.trim());
  const chosen = byType('ror_display') ?? byType('label') ?? names.find((n) => n?.value?.trim());
  return chosen?.value?.trim() ?? null;
}

/** Country lives under the first location's geonames details in v2. */
function extractCountry(record) {
  const locations = Array.isArray(record.locations) ? record.locations : [];
  for (const location of locations) {
    const details = location?.geonames_details;
    const code = details?.country_code?.trim().toUpperCase();
    const name = details?.country_name?.trim();
    if (code && name && /^[A-Z]{2}$/.test(code)) return { code, name };
  }
  return null;
}

/**
 * Lowercase, strip a leading "www.", strip surrounding dots and whitespace.
 *
 * Matches the normalisation private.match_institution() applies to an email domain, and
 * the CHECK constraint on private.ror_domains. A row that does not satisfy it could never
 * match anything, which is a silent failure, so it is dropped here and counted.
 */
function normaliseDomain(raw) {
  if (typeof raw !== 'string') return null;
  let domain = raw.trim().toLowerCase();

  // Some records carry a URL rather than a bare host.
  domain = domain.replace(/^[a-z][a-z0-9+.-]*:\/\//, '').split('/')[0] ?? '';
  domain = domain.split('@').pop() ?? '';
  domain = domain.split(':')[0] ?? '';
  domain = domain.replace(/^www\./, '');
  domain = domain.replace(/^\.+/, '').replace(/\.+$/, '');

  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(domain)) {
    return null;
  }
  return domain;
}

/** The website URL a record records for itself, if any. */
function extractWebsite(record) {
  const links = Array.isArray(record.links) ? record.links : [];
  return links.find((l) => l?.type === 'website' && typeof l.value === 'string')?.value ?? null;
}

/**
 * Suffixes that must never become a domain in their own right.
 *
 * A derived domain is only ever as good as the URL it came from, and a record whose
 * website is a page on a shared academic or government site would otherwise contribute
 * that shared host. `ac.uk` as a domain would badge every British academic as whichever
 * record happened to derive it.
 *
 * Curated ROR domains are not filtered through this: a human put those there.
 */
const NEVER_DERIVE = new Set([
  'ac.at', 'ac.be', 'ac.cn', 'ac.cy', 'ac.il', 'ac.in', 'ac.ir', 'ac.jp', 'ac.kr',
  'ac.nz', 'ac.rs', 'ac.th', 'ac.uk', 'ac.za',
  'edu.au', 'edu.br', 'edu.cn', 'edu.co', 'edu.eg', 'edu.gr', 'edu.hk', 'edu.in',
  'edu.mx', 'edu.my', 'edu.pl', 'edu.sa', 'edu.sg', 'edu.tr', 'edu.tw', 'edu.ua',
  'co.jp', 'co.kr', 'co.nz', 'co.uk', 'co.za',
  'com.au', 'com.br', 'com.cn', 'com.mx', 'com.tr',
  'gov.au', 'gov.br', 'gov.cn', 'gov.in', 'gov.uk',
  'org.au', 'org.br', 'org.uk', 'net.au', 'or.jp', 'or.kr', 'go.jp',
  'res.in', 'nic.in', 'gob.mx', 'gob.es',
  // Site builders and code hosts. A record whose website lives on one of these has no
  // domain of its own to contribute.
  'github.io', 'gitlab.io', 'wordpress.com', 'blogspot.com', 'wixsite.com', 'weebly.com',
  'squarespace.com', 'sites.google.com', 'google.com', 'notion.site', 'netlify.app',
  'vercel.app', 'herokuapp.com', 'azurewebsites.net', 'sharepoint.com', 'facebook.com',
  'linkedin.com', 'researchgate.net', 'wikipedia.org',
]);

/**
 * Decide which website-derived hosts are safe to use as match domains.
 *
 * Accepted only when the host is claimed by exactly one record in the whole dump and is
 * not already curated by a different one. Measured against ROR v2.11, that rule refuses
 * 2,400 hosts that a curated record already owns -- the ones that would have produced a
 * *wrong* badge -- and 10,663 shared by two or more records, which are ambiguous. It
 * accepts 85,911, recovering 8,253 of the 9,870 European education and facility records
 * that ROR leaves without a domain.
 *
 * Also refused: a host that is a parent of several curated domains. Adding `mpg.de`
 * because one Max Planck institute's website points there would attribute every other
 * institute's mail to that one record. Those are exactly the cases that deserve a human
 * decision, so they are reported and left for private.manual_domains.
 */
const PARENT_OF_MANY = 3;

function chooseDerivedDomains(curatedByDomain, candidates) {
  const byHost = new Map();
  for (const candidate of candidates) {
    if (!byHost.has(candidate.domain)) byHost.set(candidate.domain, []);
    byHost.get(candidate.domain).push(candidate);
  }

  const curatedDomains = [...curatedByDomain.keys()];
  const accepted = [];
  const refused = { publicSuffix: 0, alreadyCurated: 0, shared: 0, parentOfMany: [] };

  for (const [host, claimants] of byHost) {
    if (NEVER_DERIVE.has(host)) {
      refused.publicSuffix++;
      continue;
    }
    if (curatedByDomain.has(host)) {
      refused.alreadyCurated++;
      continue;
    }
    if (claimants.length > 1) {
      refused.shared++;
      continue;
    }
    const children = curatedDomains.filter((d) => d.endsWith(`.${host}`)).length;
    if (children >= PARENT_OF_MANY) {
      refused.parentOfMany.push({ host, children, name: claimants[0].name });
      continue;
    }
    accepted.push(claimants[0]);
  }

  return { accepted, refused };
}

// ── Main ─────────────────────────────────────────────────────────────────────────────

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`${error.message}\n${USAGE}`);
    process.exit(2);
  }
  if (options === null) {
    console.log(USAGE);
    process.exit(1);
  }

  const dbUrl = process.env.SUPABASE_DB_URL;
  if (!options.dryRun && !dbUrl) {
    console.error(
      'SUPABASE_DB_URL is not set, so there is nowhere to write.\n' +
        'Set it, or pass --dry-run to parse the dump without touching a database.\n',
    );
    process.exit(2);
  }

  const fileInfo = await stat(options.path).catch(() => null);
  if (!fileInfo?.isFile()) {
    console.error(`Not a readable file: ${options.path}\n${USAGE}`);
    process.exit(2);
  }

  console.log(`Reading ${options.path} (${(fileInfo.size / 1024 / 1024).toFixed(1)} MB)`);

  const institutions = [];
  const domains = []; // [domain, ror_id, source]
  const curatedByDomain = new Map(); // domain -> ror_id[]
  const derivable = []; // records with no curated domain but a website to try
  const skipped = {
    inactiveOrWithdrawn: 0,
    noName: 0,
    noCountry: 0,
    badRorId: 0,
  };
  let noDomainAndNoWebsite = 0;
  const skippedStatuses = new Map();
  let read = 0;
  let droppedDomains = 0;

  for await (const record of readRecords(options.path)) {
    read++;

    // Only active records. Anything inactive or withdrawn must stop matching.
    const status = typeof record.status === 'string' ? record.status.toLowerCase() : 'unknown';
    if (status !== 'active') {
      skipped.inactiveOrWithdrawn++;
      skippedStatuses.set(status, (skippedStatuses.get(status) ?? 0) + 1);
      continue;
    }

    const rorId = extractRorId(record.id);
    if (!rorId) {
      skipped.badRorId++;
      continue;
    }

    const name = extractName(record);
    if (!name) {
      skipped.noName++;
      continue;
    }

    const country = extractCountry(record);
    if (!country) {
      skipped.noCountry++;
      continue;
    }

    // Every active, well-formed record, whether or not it ends up with a domain.
    //
    // Institutions and domains are loaded independently on purpose. private.manual_domains
    // exists precisely to give a domain to an institution ROR left without one, and it can
    // only do that if the institution is present to be named. Loading only institutions
    // that already had a domain made the manual table unable to serve its own purpose:
    // mpg.de -> Max Planck Society matched, then resolved to nothing, and the badge was
    // silently withheld. The extra rows are a lookup table nobody queries directly.
    institutions.push([rorId, name.slice(0, 500), country.code, country.name]);

    const rawDomains = Array.isArray(record.domains) ? record.domains : [];
    const usable = new Set();
    for (const raw of rawDomains) {
      const domain = normaliseDomain(raw);
      if (domain) usable.add(domain);
      else droppedDomains++;
    }

    if (usable.size > 0) {
      for (const domain of usable) {
        domains.push([domain, rorId, 'ror_domain']);
        if (!curatedByDomain.has(domain)) curatedByDomain.set(domain, []);
        curatedByDomain.get(domain).push(rorId);
      }
      continue;
    }

    // No curated domain. The record's own website may still identify one, but only the
    // whole dump can say whether that host is unambiguously theirs, so the decision waits
    // until everything has been read.
    const derived = normaliseDomain(extractWebsite(record));
    if (derived) derivable.push({ domain: derived, rorId, name });
    else noDomainAndNoWebsite++;
  }

  const { accepted, refused } = chooseDerivedDomains(curatedByDomain, derivable);
  for (const candidate of accepted) {
    domains.push([candidate.domain, candidate.rorId, 'ror_website']);
  }

  // ── Summary ────────────────────────────────────────────────────────────────────────
  const totalSkipped = Object.values(skipped).reduce((a, b) => a + b, 0);
  const statusDetail = [...skippedStatuses.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([status, count]) => `${status} ${count.toLocaleString('en-GB')}`)
    .join(', ');

  const curatedCount = domains.filter((d) => d[2] === 'ror_domain').length;
  const derivedCount = domains.length - curatedCount;
  const n = (v) => v.toLocaleString('en-GB');

  console.log(`
Parsed
  records read              ${n(read)}
  institutions to load      ${n(institutions.length)}
  domains to load           ${n(domains.length)}
    from ROR domains        ${n(curatedCount)}
    derived from website    ${n(derivedCount)}

Skipped entirely (${n(totalSkipped)} records)
  not active                ${n(skipped.inactiveOrWithdrawn)}${statusDetail ? `  (${statusDetail})` : ''}
  no display name           ${n(skipped.noName)}
  no country on any location ${n(skipped.noCountry)}
  unrecognised ROR id       ${n(skipped.badRorId)}

Website hosts refused
  no domain and no website  ${n(noDomainAndNoWebsite)}
  public or shared suffix   ${n(refused.publicSuffix)}
  already curated elsewhere ${n(refused.alreadyCurated)}   <- these would be a WRONG badge
  claimed by 2+ records     ${n(refused.shared)}   <- ambiguous
  parent of curated domains ${n(refused.parentOfMany.length)}   <- for private.manual_domains

  individual domains dropped as malformed: ${n(droppedDomains)}`);

  // The parent-of-many cases are the actionable ones: each is a plausible institution
  // domain that only a human should decide about, because accepting it would attribute
  // every child domain's mail to one record.
  if (refused.parentOfMany.length > 0) {
    const worst = refused.parentOfMany.sort((a, b) => b.children - a.children).slice(0, 15);
    console.log('\nWithheld parent domains, most consequential first:');
    for (const p of worst) {
      console.log(`  ${p.host.padEnd(28)} parent of ${String(p.children).padStart(4)} curated  ${p.name}`);
    }
    console.log('  Add any that are correct to private.manual_domains, with evidence.');
  }

  if (institutions.length === 0) {
    console.error('\nNothing to load. Refusing to continue.');
    process.exit(1);
  }

  if (options.dryRun) {
    console.log('\n--dry-run: no database was contacted.');
    return;
  }

  await load(dbUrl, institutions, domains, options);
}

async function load(dbUrl, institutions, domains, options) {
  const { default: pg } = await import('pg').catch(() => ({ default: null }));
  if (!pg) {
    console.error('The "pg" package is missing. Run: npm install');
    process.exit(2);
  }

  const client = new pg.Client({ connectionString: dbUrl });
  try {
    await client.connect();
  } catch (error) {
    console.error(`\nCould not connect: ${error.message}`);
    if (/certificate|self.signed|SSL/i.test(error.message)) {
      console.error(
        'That looks like a TLS problem. Append ?sslmode=require to SUPABASE_DB_URL, and ' +
          'prefer the pooler host from the Supabase dashboard, whose certificate chains ' +
          'to a public CA.',
      );
    }
    process.exit(1);
  }

  const started = Date.now();
  try {
    await client.query('begin');

    // Staging tables, dropped with the transaction whichever way it ends. Column
    // definitions only: the real tables keep their constraints as the backstop.
    await client.query(`
      create temp table staging_institutions (like private.ror_institutions) on commit drop;
      create temp table staging_domains (like private.ror_domains) on commit drop;
    `);

    await insertBatched(
      client,
      'staging_institutions (ror_id, name, country_code, country_name)',
      4,
      institutions,
      options.batchSize,
      'institutions',
    );
    await insertBatched(
      client,
      'staging_domains (domain, ror_id, source)',
      3,
      domains,
      options.batchSize,
      'domains',
    );

    // Refuse to gut the tables by accident, which is what happens if someone points this
    // at a filtered or truncated file. Deliberately checked after staging so the numbers
    // in the message are real.
    const { rows: before } = await client.query(`
      select (select count(*) from private.ror_institutions) as institutions,
             (select count(*) from private.ror_domains) as domains
    `);
    const existing = Number(before[0].institutions);
    if (!options.allowShrink && existing > 0 && institutions.length < existing * 0.5) {
      throw new Error(
        `This load has ${institutions.length.toLocaleString('en-GB')} institutions but the table ` +
          `already holds ${existing.toLocaleString('en-GB')}. That is more than a halving, which ` +
          'usually means a partial or wrong file. Re-run with --allow-shrink if it is ' +
          'genuinely intended.',
      );
    }

    await client.query(`
      insert into private.ror_institutions (ror_id, name, country_code, country_name)
      select ror_id, name, country_code, country_name from staging_institutions
      on conflict (ror_id) do update
        set name         = excluded.name,
            country_code = excluded.country_code,
            country_name = excluded.country_name
    `);

    // Domains first: the cascade from a deleted institution would take them anyway, but
    // removing them explicitly keeps the reported counts honest.
    const removedDomains = await client.query(`
      delete from private.ror_domains d
       where not exists (
         select 1 from staging_domains s where s.domain = d.domain and s.ror_id = d.ror_id
       )
    `);
    const removedInstitutions = await client.query(`
      delete from private.ror_institutions i
       where not exists (select 1 from staging_institutions s where s.ror_id = i.ror_id)
    `);

    await client.query(`
      insert into private.ror_domains (domain, ror_id, source)
      select domain, ror_id, source from staging_domains
      on conflict (domain, ror_id) do update set source = excluded.source
    `);

    await client.query('commit');

    const { rows: after } = await client.query(`
      select (select count(*) from private.ror_institutions) as institutions,
             (select count(*) from private.ror_domains) as domains
    `);

    console.log(`
Loaded in ${((Date.now() - started) / 1000).toFixed(1)}s
  institutions in table     ${Number(after[0].institutions).toLocaleString('en-GB')}
  domains in table          ${Number(after[0].domains).toLocaleString('en-GB')}
  rows removed as no longer in the dump: ${removedInstitutions.rowCount.toLocaleString('en-GB')} institutions, ${removedDomains.rowCount.toLocaleString('en-GB')} domains`);
  } catch (error) {
    await client.query('rollback').catch(() => {});
    console.error(`\nRolled back. Nothing changed.\n${error.message}`);
    process.exitCode = 1;
  } finally {
    await client.end();
  }
}

/**
 * Multi-row INSERT in chunks. Postgres caps a statement at 65535 bound parameters, so the
 * batch size is a row count and the cap is checked against the column count.
 */
async function insertBatched(client, target, columns, rows, batchSize, label) {
  const maxRows = Math.floor(65535 / columns);
  const size = Math.min(batchSize, maxRows);

  for (let offset = 0; offset < rows.length; offset += size) {
    const chunk = rows.slice(offset, offset + size);
    const values = chunk
      .map((_, r) => `(${Array.from({ length: columns }, (_, c) => `$${r * columns + c + 1}`).join(',')})`)
      .join(',');
    await client.query(`insert into ${target} values ${values}`, chunk.flat());

    // Only when someone is watching. A carriage return does not overwrite in a CI log,
    // so this would otherwise emit sixty near-identical lines into the run output.
    if (process.stdout.isTTY) {
      const done = Math.min(offset + size, rows.length);
      process.stdout.write(
        `\r  staging ${label}: ${done.toLocaleString('en-GB')} / ${rows.length.toLocaleString('en-GB')}`,
      );
    }
  }
  if (process.stdout.isTTY) process.stdout.write('\n');
  else console.log(`  staged ${rows.length.toLocaleString('en-GB')} ${label}`);
}

try {
  await main();
} catch (error) {
  // A malformed input is the user's problem and deserves a sentence. Anything else is
  // our problem and deserves a stack.
  if (error instanceof DumpError) {
    console.error(`\n${error.message}`);
    process.exit(1);
  }
  throw error;
}
