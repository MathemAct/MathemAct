/**
 * A guess at how many notifications are waiting, made without loading Supabase.
 *
 * The same trade-off as session-hint.ts and mod-hint.ts, and it is worth restating because
 * this is the one where the temptation to do it properly is strongest. A notification badge
 * wants to be live. Making it live would mean the header asking the database on every page —
 * including /reports/ and /opinions/, which are deliberately free of the auth bundle and must
 * stay that way. That is the read/write split in CLAUDE.md, and a badge is not a good enough
 * reason to spend it.
 *
 * So the count is kept in localStorage and the header draws whatever is there. It is written
 * by the pages that talk to the database anyway — the account pages, and any report or
 * claim page, through the comment thread — and, since 2026-10-11, refreshed by the header
 * itself on every page with one plain-`fetch` check (`refreshActivityHint`, below). It can
 * still be stale and is honest about it: the header only ever offers a way in, and the
 * activity page itself is where the truth is. Being wrong costs a click.
 *
 * The failure direction is "no badge", never "a badge that is not there when you arrive":
 * an unreadable store, a missing key or anything unparseable all read as zero.
 */

const COUNT_KEY = 'mathemact-activity';

export function readActivityHint(): number {
  try {
    if (typeof window === 'undefined' || !window.localStorage) return 0;

    const raw = window.localStorage.getItem(COUNT_KEY);
    if (!raw) return 0;

    const count = Number.parseInt(raw, 10);
    return Number.isFinite(count) && count > 0 ? count : 0;
  } catch {
    return 0;
  }
}

export function setActivityHint(count: number): void {
  try {
    window.localStorage.setItem(COUNT_KEY, String(Math.max(0, Math.trunc(count))));
  } catch {
    // Storage blocked. The badge will not appear; the activity page still works.
  }
}

export function clearActivityHint(): void {
  try {
    window.localStorage.removeItem(COUNT_KEY);
  } catch {}
}

/**
 * Ask the database for the real count, with plain `fetch` and no Supabase client.
 *
 * This is what lets the header's badge follow the reader onto pages that never load the
 * client — every listing, every report and claim page — instead of waiting for the next
 * account or comment-thread visit. It is the same arrangement as the freshness overlay in
 * fresh.ts, for the same reason: the auth bundle stays off reading pages, and one small GET
 * against PostgREST costs next to nothing. Two, here, because the watermark has to be read
 * before the head count can be filtered by it; both are own-rows under RLS, so the signed-in
 * person's own token is all that is needed.
 *
 * It borrows the access token the client left in localStorage and **never refreshes it**.
 * Refreshing rotates the refresh token, and two things doing that against one stored session
 * — this and the real client on another tab — is how somebody gets signed out. So when the
 * token has expired (an hour after the client last ran) this does nothing, and the badge
 * stays as it was until an account or comment-thread page wakes the client. Stale, never
 * wrong in the dangerous direction: the failure is "no update", as everywhere in this file.
 *
 * Throttled, so a reader paging quickly through a listing makes one check, not one per page.
 * Every failure resolves to `null`, meaning "leave the badge alone".
 */

const SESSION_KEY = /^sb-.+-auth-token$/;
const CHECKED_KEY = 'mathemact-activity-checked';
const MIN_INTERVAL_MS = 30_000;
const TIMEOUT_MS = 4000;

interface StoredSession {
  readonly token: string;
  readonly userId: string;
}

function readStoredSession(): StoredSession | null {
  try {
    for (let i = 0; i < window.localStorage.length; i += 1) {
      const key = window.localStorage.key(i);
      if (!key || !SESSION_KEY.test(key)) continue;

      const parsed = JSON.parse(window.localStorage.getItem(key) ?? 'null');
      const token: unknown = parsed?.access_token;
      const userId: unknown = parsed?.user?.id;
      const expiresAt: unknown = parsed?.expires_at;

      if (typeof token !== 'string' || typeof userId !== 'string') return null;
      // Seconds since the epoch, with a margin so a token is not sent as it dies.
      if (typeof expiresAt === 'number' && expiresAt * 1000 < Date.now() + 15_000) return null;

      return { token, userId };
    }
  } catch {
    return null;
  }

  return null;
}

export async function refreshActivityHint(): Promise<number | null> {
  const base = import.meta.env.PUBLIC_SUPABASE_URL;
  const key = import.meta.env.PUBLIC_SUPABASE_ANON_KEY;
  if (typeof window === 'undefined' || !base || !key) return null;

  const session = readStoredSession();
  if (!session) return null;

  try {
    const last = Number(window.localStorage.getItem(CHECKED_KEY));
    if (Number.isFinite(last) && Date.now() - last < MIN_INTERVAL_MS) return null;
    window.localStorage.setItem(CHECKED_KEY, String(Date.now()));
  } catch {
    return null;
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const headers = { apikey: key, Authorization: `Bearer ${session.token}` };

  try {
    const seenResponse = await fetch(
      `${base}/rest/v1/activity_seen?select=seen_at&user_id=eq.${session.userId}`,
      { headers, signal: controller.signal },
    );
    if (!seenResponse.ok) return null;

    const rows: unknown = await seenResponse.json();
    const seenAt = Array.isArray(rows) ? (rows[0] as { seen_at?: string } | undefined)?.seen_at : null;

    let query = `select=id&subject_id=eq.${session.userId}&is_inbound=eq.true`;
    if (seenAt) query += `&created_at=gt.${encodeURIComponent(seenAt)}`;

    const countResponse = await fetch(`${base}/rest/v1/activity?${query}`, {
      method: 'HEAD',
      headers: { ...headers, Prefer: 'count=exact' },
      signal: controller.signal,
    });
    if (!countResponse.ok) return null;

    // "0-0/3", or "*/3" when there is nothing to show. The total is after the slash.
    const total = Number.parseInt(countResponse.headers.get('content-range')?.split('/')[1] ?? '', 10);
    return Number.isFinite(total) && total >= 0 ? total : null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}
