#!/usr/bin/env node
/**
 * Monthly link checker for public.network_entries.
 *
 *   node scripts/link-check.mjs [--dry-run] [--concurrency N]
 *
 * Reads all published, non-deleted entries from Supabase via a direct connection,
 * sends a HEAD request to each URL, and writes back link_status and link_checked_at.
 *
 * Exits 0 when no entries are unreachable, 1 when at least one is.
 * Writes a JSON summary to stdout on exit so .github/workflows/link-check.yml can
 * create a GitHub issue from it when the exit code is 1.
 *
 * ── Bot tolerance ────────────────────────────────────────────────────────────────────
 *
 * Many academic and commercial sites return 403 or 405 to HEAD requests from cloud IPs
 * without cookies. These responses tell us the server is alive, not that the resource
 * is gone. The rule applied here:
 *
 *   2xx                    → ok
 *   3xx (after redirect)   → redirected (we follow one hop; final 2xx is still redirected)
 *   403, 405, 406, 429     → ok (bot rejection; site is reachable)
 *   404, 410               → unreachable (explicit "this is gone")
 *   5xx, connection error, timeout → unreachable
 *
 * A 301/302 that lands on a 200 is still 'redirected' — the submitter should know the
 * canonical URL has moved and may want to update the entry.
 */
import process from 'node:process';

const USAGE = `
Monthly link checker for MathemAct entries.

  node scripts/link-check.mjs [options]

Options
  --dry-run         Check URLs but do not write results back to the database.
  --concurrency N   How many URLs to check in parallel. Default: 4.

Environment
  SUPABASE_DB_URL   Direct Postgres connection string (same secret as export.yml).
`;

// ── Arguments ─────────────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);

if (argv.includes('--help') || argv.includes('-h')) {
  console.log(USAGE);
  process.exit(0);
}

const options = {
  dryRun: argv.includes('--dry-run'),
  concurrency: Number(valueOf('--concurrency') ?? '4'),
};

function valueOf(flag) {
  const at = argv.indexOf(flag);
  return at === -1 ? undefined : argv[at + 1];
}

// ── Status classification ─────────────────────────────────────────────────────────────

/**
 * Determine link_status from an HTTP status code.
 *
 * 'ok'          — server confirmed the resource exists
 * 'redirected'  — server is alive but the URL has moved
 * 'unreachable' — server or resource is gone (or we could not connect)
 */
function classify(statusCode, wasRedirected) {
  if (statusCode >= 200 && statusCode < 300) {
    return wasRedirected ? 'redirected' : 'ok';
  }

  if (statusCode === 301 || statusCode === 302 || statusCode === 303 ||
      statusCode === 307 || statusCode === 308) {
    return 'redirected';
  }

  // Bot rejection: treat as reachable.
  if (statusCode === 403 || statusCode === 405 || statusCode === 406 || statusCode === 429) {
    return wasRedirected ? 'redirected' : 'ok';
  }

  // Explicit "gone" responses.
  if (statusCode === 404 || statusCode === 410) return 'unreachable';

  // 5xx and anything else unknown.
  return 'unreachable';
}

// ── Checking one URL ─────────────────────────────────────────────────────────────────

const TIMEOUT_MS = 12_000;
const MAX_REDIRECTS = 5;

async function checkUrl(url) {
  let redirectCount = 0;
  let currentUrl = url;

  try {
    while (true) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

      let response;
      try {
        response = await fetch(currentUrl, {
          method: 'HEAD',
          redirect: 'manual',
          signal: controller.signal,
          headers: {
            // A browser-like user agent reduces bot rejections.
            'User-Agent': 'Mozilla/5.0 (compatible; MathemAct-LinkChecker/1.0; +https://github.com/MathemAct/MathemAct)',
          },
        });
      } finally {
        clearTimeout(timer);
      }

      const isRedirect =
        response.status === 301 ||
        response.status === 302 ||
        response.status === 303 ||
        response.status === 307 ||
        response.status === 308;

      if (isRedirect && redirectCount < MAX_REDIRECTS) {
        const location = response.headers.get('location');
        if (location) {
          redirectCount++;
          // Resolve relative redirects against the current URL.
          currentUrl = new URL(location, currentUrl).href;
          continue;
        }
      }

      return { status: classify(response.status, redirectCount > 0), code: response.status };
    }
  } catch (error) {
    if (error.name === 'AbortError') {
      return { status: 'unreachable', code: null, error: 'timeout' };
    }
    return { status: 'unreachable', code: null, error: error.message };
  }
}

// ── Main ─────────────────────────────────────────────────────────────────────────────

async function main() {
  const dbUrl = process.env.SUPABASE_DB_URL;

  if (!dbUrl) {
    fail(
      'SUPABASE_DB_URL is not set.\n' +
        'In CI it is a repository secret, set in the link-check.yml workflow.',
    );
  }

  const { default: pg } = await import('pg').catch(() => ({ default: null }));
  if (!pg) fail('The "pg" package is missing. Run: npm install');

  const client = new pg.Client({ connectionString: dbUrl });

  try {
    await client.connect();
  } catch (error) {
    fail(`Could not connect: ${error.message}`);
  }

  // Fetch all published, non-deleted entries.
  let rows;
  try {
    const result = await client.query(`
      select id, url, link_status
      from public.network_entries
      where status = 'published' and deleted_at is null
      order by created_at
    `);
    rows = result.rows;
  } catch (error) {
    await client.end().catch(() => {});
    fail(`Query failed: ${error.message}`);
  }

  console.error(`Checking ${rows.length} ${rows.length === 1 ? 'entry' : 'entries'}…\n`);

  const results = [];
  const queue = [...rows];
  const concurrency = Math.max(1, Math.min(options.concurrency, 16));

  // Simple semaphore: run `concurrency` workers in parallel, each pulling from the queue.
  await Promise.all(
    Array.from({ length: concurrency }, async () => {
      while (queue.length > 0) {
        const row = queue.shift();
        if (!row) break;

        const checked = await checkUrl(row.url);
        const previous = row.link_status;

        results.push({
          id: row.id,
          url: row.url,
          previous,
          current: checked.status,
          code: checked.code,
          error: checked.error,
        });

        const change =
          previous === checked.status ? '' : ` (was: ${previous ?? 'null'})`;
        const flag = checked.status === 'unreachable' ? '  ✗' : '  ✓';
        console.error(`${flag} ${checked.status.padEnd(12)} ${row.url}${change}`);
      }
    }),
  );

  const checkedAt = new Date().toISOString();
  const unreachable = results.filter((r) => r.current === 'unreachable');
  const newlyUnreachable = unreachable.filter((r) => r.previous !== 'unreachable');

  // Write results back to the database.
  if (!options.dryRun) {
    try {
      await client.query('begin');

      for (const row of results) {
        await client.query(
          `update public.network_entries
              set link_status    = $1::network_link_status,
                  link_checked_at = $2
            where id = $3`,
          [row.current, checkedAt, row.id],
        );
      }

      await client.query('commit');
    } catch (error) {
      await client.query('rollback').catch(() => {});
      await client.end().catch(() => {});
      fail(`Write failed: ${error.message}`);
    }
  } else {
    console.error('\n--dry-run: nothing written to the database.');
  }

  await client.end();

  // Output a machine-readable summary for the workflow to use.
  const summary = {
    checked: results.length,
    ok: results.filter((r) => r.current === 'ok').length,
    redirected: results.filter((r) => r.current === 'redirected').length,
    unreachable: unreachable.length,
    newlyUnreachable: newlyUnreachable.length,
    checkedAt,
    brokenUrls: unreachable.map((r) => ({ id: r.id, url: r.url, wasNew: r.previous !== 'unreachable' })),
  };

  process.stdout.write(JSON.stringify(summary, null, 2) + '\n');

  if (unreachable.length > 0) {
    console.error(
      `\n${unreachable.length} unreachable link${unreachable.length === 1 ? '' : 's'} ` +
        `(${newlyUnreachable.length} newly broken).`,
    );
    process.exit(1);
  }

  console.error('\nAll links reachable.');
}

function fail(message) {
  console.error(`\nLink check failed.\n\n${message}\n`);
  process.exit(2);
}

await main();
