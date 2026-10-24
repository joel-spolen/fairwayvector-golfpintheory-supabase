# Public Auth setup notes

Redacted summary of the app's public login guide and current callback source.
This is not a record of changes to a dashboard or live-provider testing. Use
separate staging and production projects and confirm their actual identity with
the operator; no real project URL, project reference, key or user ID belongs here.

## Client configuration and redirects

The app accepts only its public project URL and publishable key. It must never
receive service-role, database, SMTP, Google client-secret or Apple signing keys.
Authentication setup alone does not deploy sync or enable data-service routing.

Allowlist the two **exact current app destinations**, without wildcards:

- `golfpintheory://auth/callback` — normal signup confirmation and browser login.
- `golfpintheory://auth/reset-password` — password recovery only.

Only the `golfpintheory` scheme is registered by the current app. The old scheme is
not supported. A mobile Site URL may use the ordinary callback; otherwise retain
an operator-owned HTTPS fallback. The provider-to-Supabase callback is a different
destination: take the target project's HTTPS Auth callback from its dashboard
(the path ends `/auth/v1/callback`). Never put the mobile custom scheme in the
Google/Apple provider-console redirect field.

## Email/password

- Enable Email and intended-cohort signups, keep confirmation enabled, and keep
  anonymous sign-in disabled. Supabase is authoritative for password policy;
  the app recommends at least eight characters for new passwords.
- Current UI is email/password, signup, forgot-password and Google, not the older
  passwordless/magic-link plan. Keep `{{ .ConfirmationURL }}` in **Confirm signup**
  and **Reset Password** templates. Preserve reset `redirect_to` so recovery does
  not become the ordinary callback. Do not hardcode live confirmation links.
- Production needs verified custom SMTP, sender-domain authentication and suitable
  quotas. The built-in sender has test restrictions. Disable email click/link
  tracking. Do not invite customers into the Supabase organization to bypass it.
- Confirmation/reset should open on the requesting installation: PKCE depends
  on its verifier. Cross-device completion needs a separate supported design.
- Test recovery restart, expired/reused links and successful reset followed by
  normal sign-in. Recovery must not open normal account data. Existing social-only
  identities should deliberately establish a password, not create duplicates.

## Google browser PKCE

Use a **Web application** OAuth client for the current browser flow. Register the
target Supabase HTTPS callback exactly, configure consent/branding and test users,
and request only OpenID/email/profile scopes. Put the client ID and secret directly
in Supabase's Google provider settings. Keep nonce checking enabled. Native SDK
clients and unrelated scopes are not prerequisites for this browser flow.
Complete provider publishing/domain requirements before public access.

## Apple

The app documentation describes native Apple work as paused/deferred pending
developer/signing readiness; do not infer launch readiness from backend settings.
Confirm the existing app bundle identity, capability, provisioning and developer
membership before enabling it. Native identity-token login needs the correct
accepted bundle client ID; do not invent or register a replacement app identity.

Browser Apple login is a distinct setup: Services ID grouped with the primary App
ID, correct target Supabase domain/return callback, and securely managed client
secret/signing material. Track secret expiry (at most six months), renew before
expiry, and validate private-relay mail delivery. No private signing key goes in
the app or repository. Do not assume matching email addresses merge identities.

## Acceptance

Before enabling real users, test email signup/confirmation/password/reset, Google
cancellation/success, the approved Apple flow, exact redirect routing, two-device
behavior, logout/account switching and deletion with disposable accounts. Verify
both Edge functions with the target project's actual JWT signing mode; retain
gateway `verify_jwt = true` and independent handler user validation. Do not disable
verification merely to bypass an asymmetric-key gateway incompatibility; resolve
it with a reviewed compatible design before release.
