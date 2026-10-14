/// <reference types="astro/client" />

/**
 * The build-time environment, typed.
 *
 * This merges into Vite's own `ImportMetaEnv` rather than replacing it, so `BASE_URL` and
 * friends stay where they are. What it buys is a real type at the point of use: without
 * it these reads resolve through Vite's `[key: string]: any` index signature and every
 * value is `any`, so a missing key is a silent `undefined` rather than something the
 * compiler makes you handle. (The index signature still swallows an outright typo — it
 * cannot be removed from another package's declaration — but a correctly named read is
 * now `string | undefined`, which is the case that actually needs handling.)
 *
 * Only PUBLIC_ variables belong in this file, and only ones that are public by design.
 * Astro inlines every PUBLIC_ variable into the JavaScript it emits, so adding a secret
 * here would publish it. See .env.example, which lists the three values that must never
 * appear in this repository and says where each of them actually lives.
 *
 * Every one is optional. A checkout with an unfilled .env still builds and still serves
 * the whole site; only the account pages notice, and they say so in words.
 */
interface ImportMetaEnv {
  /** Supabase project URL. An address, and public by design. */
  readonly PUBLIC_SUPABASE_URL?: string;
  /** Supabase anon key. Identifies the anonymous role, not a person; row level security
   *  decides what that role may do. Every Supabase browser client ships this in the open. */
  readonly PUBLIC_SUPABASE_ANON_KEY?: string;
  /** Cloudflare Turnstile **site** key. Appears in the widget's markup by design. The
   *  matching secret key lives in the Supabase dashboard and nowhere else. */
  readonly PUBLIC_TURNSTILE_SITE_KEY?: string;
}
