/**
 * A guess at whether the signed-in user is a moderator, made without loading Supabase.
 *
 * Exactly the same tradeoff as session-hint.ts: the header is on every reading page and
 * must not pull in the Supabase client. So the moderation page writes a flag to
 * localStorage once it has confirmed the role, and the header reads that flag. The real
 * gate is the database — loadRole + RLS — not this hint. If the hint is wrong in either
 * direction the worst that happens is a nav link that disappears or appears; the
 * moderation page is still a 404 until the role query returns.
 */

const MOD_KEY = 'mathemact-mod';

export function readModHint(): boolean {
  try {
    if (typeof window === 'undefined' || !window.localStorage) return false;
    return window.localStorage.getItem(MOD_KEY) === '1';
  } catch {
    return false;
  }
}

export function setModHint(): void {
  try {
    window.localStorage.setItem(MOD_KEY, '1');
  } catch {
    // Storage blocked; the nav hint will not appear but the page gate still works.
  }
}

export function clearModHint(): void {
  try {
    window.localStorage.removeItem(MOD_KEY);
  } catch {}
}
