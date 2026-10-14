/**
 * Every account operation on this site. The forms call these and nothing else.
 *
 * Two rules hold throughout.
 *
 * Nothing throws. Each function returns `{ ok: true }` or `{ ok: false, message }`, where
 * the message is finished prose ready to put in front of a mathematician. A form that has
 * to interpret an error object is a form where the unhandled case renders as "[object
 * Object]", and this audience will screenshot that.
 *
 * No message reveals whether an address has an account. Signing in with a wrong password
 * and signing in to an account that does not exist produce the same words, and signing up
 * with an address already registered produces the same words as signing up with a new one.
 * Supabase is configured to behave this way on its side too — with email confirmation
 * required it returns a decoy user rather than an error — and the interface must not undo
 * that. Members of this community have professional reasons to keep their participation
 * private, and an address-checking oracle would hand that away.
 *
 * Turnstile tokens are passed straight through. They are verified server-side by Supabase
 * Auth, which holds the secret key in its dashboard. There is no verification code in this
 * repository and there must never be: a static site has no server to do it with.
 */
import { arrivalParams, getSupabase, redirectUrl } from './supabase';
import { path } from './paths';

export type Result = { readonly ok: true } | { readonly ok: false; readonly message: string };

const OK: Result = { ok: true };

function fail(message: string): Result {
  return { ok: false, message };
}

/** Where a confirmation link comes back to. */
const AFTER_CONFIRMATION = () => redirectUrl(path('/account/?confirmed=1'));

/** Where a password reset link comes back to. */
const AFTER_RESET = () => redirectUrl(path('/account/password/'));

/**
 * The one message that is not about the user's input. Kept in a constant because it is
 * returned from six places and must not drift into six slightly different sentences.
 */
const UNAVAILABLE =
  'Accounts are unavailable right now. Reading the site is unaffected. Try again in a few minutes.';

// ── Operations ────────────────────────────────────────────────────────────────────────

export interface SignUpInput {
  email: string;
  password: string;
  displayName: string;
  isPseudonym: boolean;
  captchaToken?: string;
}

export async function signUp(input: SignUpInput): Promise<Result> {
  const supabase = getSupabase();
  if (!supabase) return fail(UNAVAILABLE);

  try {
    const { error } = await supabase.auth.signUp({
      email: input.email.trim(),
      password: input.password,
      options: {
        emailRedirectTo: AFTER_CONFIRMATION(),
        captchaToken: input.captchaToken,
        // Read by private.handle_new_user(), which takes these two keys and no others.
        // Anything else put here would be ignored by the trigger and stored on the auth
        // record for no reason, so do not add to it casually.
        data: {
          display_name: input.displayName.trim(),
          is_pseudonym: input.isPseudonym,
        },
      },
    });

    if (error) return fail(describe(error));

    // Deliberately not inspecting `data.user.identities` to detect an existing account.
    // Supabase returns a decoy user precisely so that this cannot be done, and the
    // confirmation-pending page reads the same either way: the person who owns the address
    // gets an email, and nobody else learns anything.
    return OK;
  } catch (error) {
    return fail(describe(error));
  }
}

export async function signIn(
  email: string,
  password: string,
  captchaToken?: string,
): Promise<Result> {
  const supabase = getSupabase();
  if (!supabase) return fail(UNAVAILABLE);

  try {
    const { error } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
      options: { captchaToken },
    });

    return error ? fail(describe(error)) : OK;
  } catch (error) {
    return fail(describe(error));
  }
}

export async function signOut(): Promise<Result> {
  const supabase = getSupabase();
  if (!supabase) return fail(UNAVAILABLE);

  try {
    // Local scope: this browser, not every browser. Someone signing out of a shared
    // machine in a departmental library should not find their laptop signed out too, and
    // a compromised-account response is a password change rather than a sign-out.
    const { error } = await supabase.auth.signOut({ scope: 'local' });
    return error ? fail(describe(error)) : OK;
  } catch (error) {
    return fail(describe(error));
  }
}

export async function resendConfirmation(
  email: string,
  captchaToken?: string,
): Promise<Result> {
  const supabase = getSupabase();
  if (!supabase) return fail(UNAVAILABLE);

  try {
    const { error } = await supabase.auth.resend({
      type: 'signup',
      email: email.trim(),
      options: { emailRedirectTo: AFTER_CONFIRMATION(), captchaToken },
    });

    return error ? fail(describe(error)) : OK;
  } catch (error) {
    return fail(describe(error));
  }
}

export async function requestPasswordReset(
  email: string,
  captchaToken?: string,
): Promise<Result> {
  const supabase = getSupabase();
  if (!supabase) return fail(UNAVAILABLE);

  try {
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
      redirectTo: AFTER_RESET(),
      captchaToken,
    });

    return error ? fail(describe(error)) : OK;
  } catch (error) {
    return fail(describe(error));
  }
}

export async function updatePassword(password: string): Promise<Result> {
  const supabase = getSupabase();
  if (!supabase) return fail(UNAVAILABLE);

  try {
    const { error } = await supabase.auth.updateUser({ password });
    return error ? fail(describe(error)) : OK;
  } catch (error) {
    return fail(describe(error));
  }
}

// ── Errors arriving in the URL ────────────────────────────────────────────────────────

/**
 * An expired or already-used email link comes back as parameters on the landing page
 * rather than as a failed call, so the failure has to be read out of the address bar
 * rather than out of a rejected promise.
 *
 * It reads the snapshot taken in supabase.ts at module load rather than the live address,
 * because the Supabase client strips those parameters as it initialises and reading them
 * afterwards is a race — one that a page wins in development and loses on a slow phone,
 * which is the worst possible way for it to be wrong.
 *
 * Only an error is consumed and cleared from the address bar. A fragment carrying real
 * tokens is left exactly as found, for the client to pick up; clearing that here would
 * sign someone out at the moment they arrived.
 */
export function readAuthErrorFromUrl(): string | null {
  if (!arrivalParams) return null;

  const { hash, query } = arrivalParams;

  const code = hash.get('error_code') ?? query.get('error_code');
  const error = hash.get('error') ?? query.get('error');
  if (!code && !error) return null;

  const description = hash.get('error_description') ?? query.get('error_description');

  // The address bar keeps the error otherwise, and a reload after a successful retry
  // would show it again over the top of a page that is now working.
  if (typeof window !== 'undefined' && window.location.hash) {
    window.history.replaceState({}, '', window.location.pathname + window.location.search);
  }

  if (code === 'otp_expired') {
    return 'That link has expired. Request a new one below — links are valid for 24 hours.';
  }

  if (error === 'access_denied') {
    return 'That link has already been used, or it is no longer valid. Request a new one below.';
  }

  return description
    ? `${description.replace(/\+/g, ' ')}. Request a new link below.`
    : 'That link did not work. Request a new one below.';
}

// ── Turning a failure into a sentence ─────────────────────────────────────────────────

/**
 * Supabase's own messages are written for developers: "Invalid login credentials", "For
 * security purposes, you can only request this after 47 seconds". They are accurate and
 * they are not what a person needs to read at the moment something did not work.
 *
 * Matched on `code` first, which is stable, then on the message text, which is not but is
 * all older errors carry. Anything unrecognised falls through to a message that at least
 * says what to do next rather than restating the failure.
 */
function describe(error: unknown): string {
  const code = typeof error === 'object' && error !== null && 'code' in error
    ? String((error as { code?: unknown }).code ?? '')
    : '';

  const message = error instanceof Error ? error.message : String(error ?? '');
  const lower = message.toLowerCase();

  switch (code) {
    case 'invalid_credentials':
      return 'That email address and password do not match an account. Check both, and reset the password if you need to.';

    case 'email_not_confirmed':
      return 'This account still needs its email address confirmed. Open the link in the confirmation email, or ask for a new one.';

    case 'weak_password':
      return 'Choose a longer password. A passphrase of a few unrelated words works well.';

    case 'same_password':
      return 'That is the password already on the account. Choose a different one.';

    case 'over_email_send_rate_limit':
      return 'Several emails have gone to this address already. Wait a few minutes before asking for another — the earlier ones are still valid.';

    case 'over_request_rate_limit':
      return 'Too many attempts from this connection. Wait a minute and try again.';

    case 'captcha_failed':
      return 'The check that you are not a bot did not complete. Reload the page and try again.';

    case 'signup_disabled':
      return 'New accounts are closed at the moment.';

    case 'session_not_found':
    case 'refresh_token_not_found':
      return 'This session has ended. Sign in again to continue.';

    case 'validation_failed':
      return 'Something in the form was not accepted. Check the email address and try again.';
  }

  // Retryable fetch failures and anything else that never reached Supabase at all.
  if (
    lower.includes('failed to fetch') ||
    lower.includes('fetch failed') ||
    lower.includes('networkerror') ||
    lower.includes('load failed')
  ) {
    return 'Could not reach the server. Check your connection and try again — nothing was changed.';
  }

  if (lower.includes('captcha')) {
    return 'The check that you are not a bot did not complete. Reload the page and try again.';
  }

  if (lower.includes('rate limit') || lower.includes('for security purposes')) {
    return 'That was attempted too recently. Wait a minute and try again.';
  }

  if (lower.includes('password')) {
    return 'That password was not accepted. Choose a longer one — a passphrase of a few unrelated words works well.';
  }

  return 'That did not work. Try again, and if it keeps failing the details are worth reporting.';
}
