/**
 * Cloudflare Turnstile: the check that keeps automated signups out.
 *
 * What is and is not here
 * ----------------------
 * This file renders a widget and hands the resulting token to Supabase Auth. It does not
 * verify anything, and there is no code in this repository that does. Verification needs
 * the Turnstile **secret** key, which lives in the Supabase dashboard under Authentication
 * → CAPTCHA and nowhere else; Supabase checks the token with Cloudflare when it processes
 * the signup. A static site has no server to do this with, and inventing one would mean
 * putting a secret somewhere a browser could read it.
 *
 * The **site** key is public by design — it appears in the widget's own markup — and is
 * committed as PUBLIC_TURNSTILE_SITE_KEY.
 *
 * On loading a third-party script
 * -------------------------------
 * This is the only script from another origin the site loads, and it is loaded only on the
 * pages where an account is created or a password is changed. Nothing loads it on a page
 * someone is reading, which is what the privacy notice promises and what "no third-party
 * anything" in CLAUDE.md is protecting. The widget is left visibly branded rather than run
 * in interaction-only mode: an audience this sceptical is better served by seeing that
 * Cloudflare is involved than by a check that happens invisibly.
 *
 * When the key is absent — a checkout with an unfilled .env — nothing is loaded and no
 * token is produced. That is the right failure: Supabase rejects the request if its own
 * CAPTCHA setting is on, and the error mapping in auth.ts turns that into a sentence.
 */

const SITE_KEY = import.meta.env.PUBLIC_TURNSTILE_SITE_KEY ?? '';
const SCRIPT_SRC = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';

export const isTurnstileConfigured = Boolean(SITE_KEY);

interface TurnstileApi {
  render(
    container: HTMLElement,
    options: {
      sitekey: string;
      callback: (token: string) => void;
      'error-callback'?: () => void;
      'expired-callback'?: () => void;
      theme?: 'light' | 'dark' | 'auto';
      language?: string;
    },
  ): string;
  reset(widgetId?: string): void;
  remove(widgetId?: string): void;
}

declare global {
  interface Window {
    turnstile?: TurnstileApi;
  }
}

let loading: Promise<TurnstileApi | null> | null = null;

function loadScript(): Promise<TurnstileApi | null> {
  loading ??= new Promise<TurnstileApi | null>((resolve) => {
    if (window.turnstile) {
      resolve(window.turnstile);
      return;
    }

    const script = document.createElement('script');
    script.src = SCRIPT_SRC;
    script.async = true;
    script.defer = true;
    script.onload = () => resolve(window.turnstile ?? null);
    // Blocked by an extension, a corporate proxy, or an offline browser. Resolving null
    // rather than rejecting keeps this a state the form renders instead of an exception
    // it has to catch.
    script.onerror = () => resolve(null);
    document.head.append(script);
  });

  return loading;
}

export interface TurnstileWidget {
  /**
   * The current token, waiting for the challenge to finish if it has not yet. Resolves to
   * undefined when Turnstile is unconfigured or could not load, which is what
   * `signUp({ captchaToken })` expects for "no token".
   */
  token(): Promise<string | undefined>;
  /** Discard the token and re-run the challenge. A token is single-use: after any failed
   *  submission the next attempt needs a fresh one. */
  reset(): void;
}

/** A widget that produces no token, used when Turnstile is not configured or not reachable. */
const ABSENT: TurnstileWidget = {
  token: async () => undefined,
  reset: () => {},
};

export async function mountTurnstile(container: HTMLElement): Promise<TurnstileWidget> {
  if (!isTurnstileConfigured) return ABSENT;

  const api = await loadScript();
  if (!api) return ABSENT;

  let token: string | undefined;
  let waiting: ((value: string | undefined) => void)[] = [];

  function settle(value: string | undefined): void {
    token = value;
    for (const resolve of waiting) resolve(value);
    waiting = [];
  }

  const widgetId = api.render(container, {
    sitekey: SITE_KEY,
    theme: 'light',
    language: 'en',
    callback: (value) => settle(value),
    // A failed challenge and an expired one are the same thing to a caller: there is no
    // token. Both settle any pending wait so a submit cannot hang on a promise that will
    // never resolve, which is the failure mode people describe as "the button did nothing".
    'error-callback': () => settle(undefined),
    'expired-callback': () => settle(undefined),
  });

  return {
    token: () =>
      token !== undefined
        ? Promise.resolve(token)
        : new Promise<string | undefined>((resolve) => waiting.push(resolve)),

    reset: () => {
      token = undefined;
      api.reset(widgetId);
    },
  };
}
