/**
 * A guess at whether someone is signed in, made without loading Supabase.
 *
 * Why a guess rather than the truth
 * --------------------------------
 * The header is on every page, including the ones people come here to read. Asking the
 * real session store would mean shipping the Supabase client — tens of kilobytes of
 * JavaScript and a network round trip — to the home page, in order to decide between the
 * words "Sign in" and "Account". That is precisely the coupling the read/write split in
 * CLAUDE.md exists to prevent: reads are static, and the database is for writes and auth.
 *
 * So the header reads localStorage directly and takes its best guess. Both destinations
 * are real pages that establish the truth for themselves, so being wrong costs a click,
 * never a broken flow. The account pages load the real store; nothing else does.
 *
 * This does mean knowing Supabase's storage key by shape rather than by contract. The
 * match is deliberately loose — any `sb-*-auth-token*` key — because the exact name
 * carries the project ref, and newer clients split a large session across `.0` and `.1`
 * suffixes. A rename upstream degrades this to "always signed out", which is the harmless
 * direction: the header offers a sign-in link, and the sign-in page finds the session and
 * says so.
 */

/** The library's key shape. Loose on purpose; see above. */
const SESSION_KEY = /^sb-.+-auth-token(\.\d+)?$/;

export type SessionHint = 'in' | 'out';

export function readSessionHint(): SessionHint {
  // Storage access throws outright in some privacy modes and under a strict cookie
  // policy, so every path here has to survive it. An unreadable store means "signed out".
  try {
    if (typeof window === 'undefined' || !window.localStorage) return 'out';

    for (let i = 0; i < window.localStorage.length; i += 1) {
      const key = window.localStorage.key(i);
      if (key && SESSION_KEY.test(key) && window.localStorage.getItem(key)) return 'in';
    }
  } catch {
    return 'out';
  }

  return 'out';
}
