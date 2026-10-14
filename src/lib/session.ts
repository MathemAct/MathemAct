/**
 * The session store: one place that knows whether somebody is signed in, and tells anyone
 * who asked when that changes.
 *
 * Four states, not two. "Signed out" and "we cannot tell you" are different facts and
 * conflating them produces the worst possible interface — a sign-in form that rejects a
 * correct password because the project is misconfigured, or a profile page that quietly
 * claims you have no account because a network was down. Every account page renders
 * `unavailable` as its own thing, with its own words.
 *
 * There is no email address in this store, and no getter for one. The signed-in person's
 * address is in the JWT and could trivially be surfaced here, which is the reason to say
 * plainly that it must not be: the moment it is available, it gets rendered somewhere, and
 * "never displayed, never returned by the API, never exported, never shown to moderators"
 * stops being true. Where a page genuinely has to name the address a link was sent to —
 * the confirmation-pending page — it carries it in that browser's own sessionStorage, put
 * there by the form the person just typed it into.
 *
 * Nothing here runs at build time. The store is inert until `startSession()` is called
 * from a browser, and only the account pages call it: the header uses the much cheaper
 * guess in session-hint.ts instead, so reading the site never loads the auth client.
 */
import { getSupabase, isConfigured } from './supabase';

export type SessionState =
  /** Before the first answer. Render nothing that would flip a moment later. */
  | { readonly status: 'loading' }
  | { readonly status: 'signed-in'; readonly userId: string }
  | { readonly status: 'signed-out' }
  /**
   * Accounts cannot work right now. `unconfigured` is a deployment without the public
   * Supabase values — the state this repository is in before the keys are filled in.
   * `unreachable` is a network or service failure. Both are shown to the reader as a
   * statement of fact rather than as a form that will not work.
   */
  | { readonly status: 'unavailable'; readonly reason: 'unconfigured' | 'unreachable' };

type Listener = (state: SessionState) => void;

let state: SessionState = { status: 'loading' };
const listeners = new Set<Listener>();
let started: Promise<void> | null = null;

export function getSessionState(): SessionState {
  return state;
}

/**
 * Listen for changes. The listener is called immediately with the current state, so a
 * caller never has to handle "subscribed before the first value" as a separate case.
 * Returns an unsubscribe function.
 */
export function subscribeToSession(listener: Listener): () => void {
  listeners.add(listener);
  listener(state);
  return () => listeners.delete(listener);
}

function publish(next: SessionState): void {
  // Suppress identical states. Token refresh fires roughly hourly and produces a fresh
  // session object with the same user; re-rendering a profile form under someone's cursor
  // because a token rotated would be a strange thing to do to them.
  if (
    next.status === state.status &&
    (next.status !== 'signed-in' ||
      (state.status === 'signed-in' && next.userId === state.userId))
  ) {
    return;
  }

  state = next;
  for (const listener of listeners) listener(state);
}

/**
 * Start the store. Idempotent: call it from every page that needs a session and it will
 * initialise once. Never rejects — a failure becomes an `unavailable` state, because a
 * page that throws during setup shows a blank panel and no explanation.
 */
export function startSession(): Promise<void> {
  started ??= initialise();
  return started;
}

async function initialise(): Promise<void> {
  if (!isConfigured) {
    publish({ status: 'unavailable', reason: 'unconfigured' });
    return;
  }

  const supabase = getSupabase();
  if (!supabase) {
    publish({ status: 'unavailable', reason: 'unconfigured' });
    return;
  }

  // Registered before the first read, so a session arriving from a URL fragment — an email
  // confirmation or a password reset link — is picked up rather than raced past.
  //
  // Every event is handled through the same path. SIGNED_IN, SIGNED_OUT, TOKEN_REFRESHED,
  // USER_UPDATED, PASSWORD_RECOVERY and INITIAL_SESSION all reduce to the same question:
  // is there a session now? Switching on the event name instead is how a store ends up
  // showing a stale user after a refresh fails, because the one event nobody handled was
  // the one that mattered.
  supabase.auth.onAuthStateChange((_event, session) => {
    publish(
      session?.user
        ? { status: 'signed-in', userId: session.user.id }
        : { status: 'signed-out' },
    );
  });

  try {
    const { data, error } = await supabase.auth.getSession();

    if (error) {
      publish({ status: 'unavailable', reason: 'unreachable' });
      return;
    }

    publish(
      data.session?.user
        ? { status: 'signed-in', userId: data.session.user.id }
        : { status: 'signed-out' },
    );
  } catch {
    // Thrown rather than returned: storage blocked by a cookie policy, or the fetch itself
    // failing. Either way accounts do not work here and the page should say so.
    publish({ status: 'unavailable', reason: 'unreachable' });
  }
}
