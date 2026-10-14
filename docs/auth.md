# Accounts: how they work, and what has to be set in the dashboard

The code in `src/lib/auth.ts` and `src/pages/account/` is half of the account system. The
other half is configuration in the Supabase dashboard, and none of it is in this
repository — deliberately, because it is where the secrets live.

This document is the checklist for that half, and the runbook for the things that go wrong.

## The shape of it

```
browser ──► Supabase Auth ──► Brevo SMTP ──► inbox
   │              │
   │              └──► Cloudflare (verifies the Turnstile token)
   │
   └──► PostgREST ──► public.profiles, public.deletion_requests
```

There is no application server. The site is static files on GitHub Pages, so every arrow
above starts in a browser. Three consequences that shape everything else:

- **Turnstile is verified by Supabase, not by us.** The secret key goes in the Supabase
  dashboard. There is no verification code in this repository and there must never be.
- **Mail is sent by Supabase, not by us.** The Brevo SMTP credentials go in the Supabase
  dashboard. Swapping mail provider is five fields in a settings page, not a code change.
- **Nothing in this repo can be trusted to enforce anything.** Client validation is
  convenience. The CHECK constraints, the grants, and the RLS policies in
  `supabase/migrations/` are the enforcement.

## Dashboard checklist

Everything below is at <https://supabase.com/dashboard>, project ref `fgnmafmzracdytpfqpel`.

**One item on this list is checked automatically.** `.github/workflows/auth-config.yml`
reads the dashboard's minimum password length through the Management API and fails if it
disagrees with `LIMITS.password.min` in `src/lib/validation.ts`. It runs weekly as well as
on changes to that file, because the dashboard can drift without producing a commit and
there would otherwise be nothing to trigger on. Everything else here is still checked by a
human reading it, and the same mechanism would extend to any of it.

### 1. Authentication → URL Configuration

`Site URL`:

```
https://mathemact.github.io/MathemAct/
```

`Redirect URLs` — **both** entries, or confirmation works in production and fails locally,
which is the most confusing possible way for it to be broken:

```
https://mathemact.github.io/MathemAct/**
http://localhost:4321/MathemAct/**
```

The `/MathemAct/` prefix is not optional. The site is a GitHub Pages *project* site, so it
is served under a path prefix, and `astro dev` reproduces that prefix locally. A redirect
URL registered without it silently fails to match, and the failure looks exactly like a
broken email.

The two paths links actually return to are `/MathemAct/account/?confirmed=1` and
`/MathemAct/account/password/`. They are built at run time from `window.location.origin`,
so a preview deployment or a future custom domain needs its own entry here and no code
change.

### 2. Authentication → Providers → Email

| Setting | Value | Why |
|---|---|---|
| Enable email provider | on | |
| Confirm email | **on** | The institutional badge is derived from a *confirmed* address. Turning this off makes every badge worthless. |
| Secure email change | on | Changing an address re-derives the badge; both addresses should have to agree. |
| Minimum password length | **10** | Must match `LIMITS.password.min` in `src/lib/validation.ts`. `auth-config.yml` fails if they disagree — weekly, and on any change to that file. |
| Prevent use of leaked passwords | **unavailable** | Would check a new password against a breach corpus, which is the one thing a length minimum cannot catch. It is a paid Supabase feature and this project has no budget, so it stays off and the Security Advisor reports `auth_leaked_password_protection` permanently. That warning is part of the accepted baseline of five; see `docs/decisions.md`. Do not go looking for the toggle — it is not a setting somebody forgot. |

### 3. Authentication → Attack Protection → CAPTCHA

| Setting | Value |
|---|---|
| Enable CAPTCHA protection | on |
| Provider | Cloudflare Turnstile |
| Secret key | from the Cloudflare dashboard — **this field is the only place it may ever be** |

The matching **site** key goes in the repository as `PUBLIC_TURNSTILE_SITE_KEY`, and as a
GitHub Actions *variable* rather than a secret. It appears in the widget's markup by
design; hiding it would only hide it from us.

Turning CAPTCHA on here means Supabase enforces it on sign-up, sign-in, password reset, and
resend. All four pages mount the widget. Turning it on without the site key configured
makes every one of those fail with a captcha error — which `describe()` in `src/lib/auth.ts`
turns into "the check that you are not a bot did not complete", so at least the symptom
points somewhere.

### 4. Authentication → SMTP Settings

Brevo, free plan, 300 emails/day counted per envelope recipient and shared across all send
types. One email per signup and one per password reset is ample for an invited cohort.
**Never send announcements through this channel** — it is the same quota.

| Field | Value |
|---|---|
| Host | `smtp-relay.brevo.com` |
| Port | `587` |
| Username | the Brevo SMTP login |
| Password | the Brevo SMTP key — **only ever in this field** |
| Sender email | must match `SITE.senderEmail` in `src/lib/site.ts` |
| Sender name | must match `SITE.senderName` |

The sender address is printed on the confirmation-pending page so that an unexpected
message is recognisable rather than suspicious. Nothing checks that the two agree; if you
change one, change the other.

Supabase Auth has its own emails-per-hour rate limit, **independent of Brevo's daily cap**,
under Authentication → Rate Limits. Hitting it during testing looks like mail silently not
arriving.

### 5. Authentication → Email Templates

Rewrite all of them before any user testing. The defaults mention Supabase, use the word
"magic", and read like phishing to an audience already inclined to think so. Replacements
are below.

### 6. Vault → the export dispatch token

Not part of accounts, but it lives in the dashboard for the same reason everything above does.
Since `20261011120000` the database asks GitHub to run `.github/workflows/export.yml` within a
minute of any write, so the static pages catch up in minutes rather than overnight. It asks with
this token. **Without it the site still works and updates nightly only**, and every nightly
export run carries a warning saying so.

1. On GitHub, Settings → Developer settings → Fine-grained personal access tokens → Generate new
   token.
   - Resource owner: `MathemAct`. Repository access: **only** `MathemAct/MathemAct`.
   - Repository permissions: **Actions → Read and write**. Nothing else; metadata read is
     added automatically.
   - Expiration: the longest offered. Write the date in the line below.
2. In the Supabase SQL editor, run once, pasting the token in place of the placeholder:

   ```sql
   select vault.create_secret('<token>', 'github_export_dispatch');
   ```

   Never put the token in a migration, a workflow or any file in this repository. To replace an
   expired one, update the existing secret rather than creating a second:

   ```sql
   select vault.update_secret(
     (select id from vault.secrets where name = 'github_export_dispatch'),
     '<new token>');
   ```

3. Check it within two minutes of any write:

   ```sql
   select dispatched_at, last_status from private.export_queue;
   ```

   `last_status` 204 means GitHub accepted the request; an `Export` run appears under Actions.
   401 means the token is wrong or expired, 404 that it cannot see the repository or lacks the
   Actions permission.

Token expires: never.

## Email templates

Paste these into Authentication → Email Templates. Keep them plain: this audience reads
mail in clients that strip formatting, and a message that renders as a wall of broken HTML
is a message that gets deleted.

`{{ .ConfirmationURL }}` is Supabase's placeholder and must be left exactly as written.

### Confirm signup

Subject:

```
Confirm your email address for MathemAct
```

Body:

```html
<p>You (or someone using this address) created an account on MathemAct, a record of how
mathematicians actually use AI tools in their work.</p>

<p><a href="{{ .ConfirmationURL }}">Confirm this email address</a></p>

<p>The link is valid for 24 hours and can be opened on any device. Until it is opened, the
account cannot post anything and is not visible to anyone.</p>

<p>Your address is used to sign you in, and its domain is checked once against the Research
Organization Registry so that an institutional badge can be awarded if it matches. The
address itself is never displayed on the site, never returned by the API, never included in
the public export, and never shown to moderators.</p>

<p>If you did not create this account, ignore this message. Nothing was created that
outlives the link, and no further mail will be sent.</p>

<p>— MathemAct<br>
<a href="https://mathemact.github.io/MathemAct/">mathemact.github.io/MathemAct</a></p>
```

### Reset password

Subject:

```
Set a new password for MathemAct
```

Body:

```html
<p>Someone asked to reset the password for the MathemAct account on this address.</p>

<p><a href="{{ .ConfirmationURL }}">Set a new password</a></p>

<p>The link is valid for 24 hours and can only be used once. Your current password keeps
working until you set a new one.</p>

<p>If this was not you, ignore this message — your password has not been changed, and
nobody can change it without this link.</p>

<p>— MathemAct<br>
<a href="https://mathemact.github.io/MathemAct/">mathemact.github.io/MathemAct</a></p>
```

### Change email address

Subject:

```
Confirm your new email address for MathemAct
```

Body:

```html
<p>You asked to change the email address on your MathemAct account to this one.</p>

<p><a href="{{ .ConfirmationURL }}">Confirm this address</a></p>

<p>Confirming re-derives your institutional badge from the new address. If the new domain
matches a different institution, or none at all, the badge changes to match — it always
describes the address currently on the account.</p>

<p>If this was not you, ignore this message. The address on the account is unchanged.</p>

<p>— MathemAct<br>
<a href="https://mathemact.github.io/MathemAct/">mathemact.github.io/MathemAct</a></p>
```

## Testing a signup end to end

Do this with three addresses, because they fail differently:

1. **A Gmail address.** Ends up Registered with no institutional badge — `gmail.com` is in
   `private.blocked_domains`, so it is refused at the match rather than left to chance.
   Check the spam folder; a new sender to Gmail lands there routinely.
2. **An Outlook or Hotmail address.** Same expected outcome. Microsoft is the strictest of
   the large providers about unfamiliar senders and is where delivery problems show up
   first.
3. **An institutional address.** Should come back with an institution, a country, and a
   month on the profile page. If it does not, the domain is the thing to check — see
   [ror.md](ror.md) and `private.manual_domains`.

For each: confirm the link, land on the profile, check the badge, change the display name,
sign out, sign back in, reset the password, and use the reset link. Then look at the Brevo
log view (Transactional → Logs) — it shows delivered, soft bounce, hard bounce, and
spam-complaint per message, which is the only place a delivery failure is visible at all.

## Things that go wrong

**"The confirmation link does nothing."** Almost always a redirect URL that is not on the
allow-list, and almost always because the `/MathemAct/` prefix was left off. Supabase
redirects to the Site URL instead of the requested one, so the link appears to work and
lands somewhere with no token.

**"No email arrived."** In order of likelihood: it is in spam; Supabase's per-hour rate
limit was hit during testing; the Brevo daily cap was reached; the SMTP credentials are
wrong. The first two are invisible from our side, the last two are in the Brevo log view.

**"Sign-in says the check did not complete."** CAPTCHA is enabled in the dashboard but
`PUBLIC_TURNSTILE_SITE_KEY` is empty in the build, so no token is sent. Either fill in the
variable or turn CAPTCHA off; leaving it half-configured breaks every auth route.

**"The account pages say accounts are not switched on."** `PUBLIC_SUPABASE_URL` or
`PUBLIC_SUPABASE_ANON_KEY` is empty. Locally that is `.env`; in production it is the two
repository *variables* read by `.github/workflows/deploy.yml`.

**"Someone has the wrong institution."** The badge records which of the three domain layers
issued it in `profiles.institution_source`, which is never displayed and exists exactly for
this. Find the domain in `private.manual_domains` or `private.ror_domains`, fix or delete
it, and the badge re-derives the next time that address is confirmed. See [ror.md](ror.md).

## What is deliberately not built

- **No email address is ever shown, anywhere.** Not on a profile, not in the API, not in
  the export, not to a moderator. `public.profiles` has no email column and the pgTAP suite
  asserts that no route to one exists.
- **No account enumeration.** Sign-in errors do not distinguish a wrong password from an
  unknown address, signup does not report that an address is taken, and the password-reset
  confirmation is phrased conditionally. Supabase behaves this way on its side; the
  interface must not undo it.
- **No "verified academic" claim.** A badge says an address at a domain was confirmed to
  work on a date. Not employment, not position, not seniority.
- **No social sign-in, and no ORCID.** See [decisions.md](decisions.md) before proposing
  either.
