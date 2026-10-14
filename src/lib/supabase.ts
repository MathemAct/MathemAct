/**
 * The browser's Supabase client. The only place in this project that constructs one.
 *
 * Both values below are PUBLIC BY DESIGN and are committed to the repository.
 *
 *   PUBLIC_SUPABASE_URL        an address.
 *   PUBLIC_SUPABASE_ANON_KEY   identifies the *anonymous role*, not a person. It grants
 *                              nothing on its own: row level security decides what that
 *                              role may read and write, and every Supabase browser client
 *                              in existence ships this key in plain sight.
 *
 * The service role key bypasses row level security entirely. It must NEVER appear in this
 * file, in any file under src/, in any `PUBLIC_*` variable, or in the repository. It lives
 * in GitHub Actions secrets and is used only by the nightly export job. The same goes for
 * the Turnstile secret key and the Brevo SMTP key, which live in the Supabase dashboard —
 * a static site has no server, so Supabase does the verifying and the sending on our
 * behalf. If a feature seems to need one of them here, the design is wrong. Stop.
 *
 * Two things about how this module is written
 * -------------------------------------------
 * The client is built lazily, on first use, and never at module scope. Astro evaluates
 * imported modules during the build, and a client constructed then would be built on a
 * machine with no browser, no storage, and no session — and would throw the build over if
 * a key were missing. Nothing here runs until a browser calls `getSupabase()`.
 *
 * `getSupabase()` returns null rather than throwing when the project is not configured.
 * Reading this site must never depend on Supabase being reachable or even set up, so the
 * unconfigured case is an ordinary state the interface knows how to render, not an
 * exception somebody has to remember to catch.
 */
import { createClient, type SupabaseClient } from '@supabase/supabase-js';

// Not named URL: that shadows the global constructor, and the failure — "type 'String'
// has no construct signatures", forty lines further down — takes a minute to place.
const PROJECT_URL = import.meta.env.PUBLIC_SUPABASE_URL ?? '';
const ANON_KEY = import.meta.env.PUBLIC_SUPABASE_ANON_KEY ?? '';

/** Whether the build had both public values. False in a checkout with an unfilled .env. */
export const isConfigured = Boolean(PROJECT_URL && ANON_KEY);

/**
 * The auth parameters that were in the address bar when this module first loaded.
 *
 * Taken here, at module scope, because this is the one point guaranteed to run before any
 * client exists: nothing can call `createClient` without first evaluating this file. The
 * client strips these parameters as it initialises — which is correct, an access token
 * should not sit in the address bar — but it means anything that wants to read the failure
 * out of an expired link is racing it. This snapshot is not.
 *
 * Null during the build, where there is no address bar.
 */
export const arrivalParams: {
  readonly hash: URLSearchParams;
  readonly query: URLSearchParams;
} | null =
  typeof window === 'undefined'
    ? null
    : {
        hash: new URLSearchParams(window.location.hash.replace(/^#/, '')),
        query: new URLSearchParams(window.location.search),
      };

let client: SupabaseClient | null = null;

export function getSupabase(): SupabaseClient | null {
  if (!isConfigured) return null;
  if (typeof window === 'undefined') return null;

  client ??= createClient(PROJECT_URL, ANON_KEY, {
    auth: {
      // Sessions persist in localStorage and refresh in the background. Both are the
      // library defaults; they are written out because turning either off silently turns
      // "stay signed in" into "signed out on every reload".
      persistSession: true,
      autoRefreshToken: true,

      // Email links land on a page carrying the session in the URL fragment, which this
      // picks up and then strips from the address bar.
      detectSessionInUrl: true,

      // Implicit rather than PKCE, and this is a real trade-off.
      //
      // PKCE is more secure: the code in the URL is worthless without a verifier held in
      // the browser that started the flow. That is also exactly why it is wrong here. Our
      // users sign up on a laptop and open the confirmation email on a phone, and under
      // PKCE that fails with an error indistinguishable from a broken link — for an
      // audience already inclined to read an unfamiliar email as phishing.
      //
      // Under implicit flow the tokens arrive in the URL fragment, which is never sent to
      // any server, is stripped from the address bar on arrival, and belongs to a
      // single-use link. The residual exposure is browser history and extensions. Given
      // that the alternative is a confirmation flow that breaks whenever mail is read on
      // a different device, this is the right way round for this site.
      flowType: 'implicit',
    },
  });

  return client;
}

/**
 * Absolute URL for an email link to come back to, e.g. after confirmation or a password
 * reset. Supabase requires an absolute URL and checks it against the redirect allow-list
 * in the dashboard — see docs/auth.md, which lists every URL that has to be registered.
 *
 * Built from `window.location.origin` rather than from a configured site URL so that
 * localhost, a preview, and production each send people back where they came from.
 */
export function redirectUrl(sitePath: string): string {
  return new URL(sitePath, window.location.origin).href;
}
