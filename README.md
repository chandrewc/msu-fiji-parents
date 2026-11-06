# Sigma Mu Parents Portal

Separate parent portal adapted from chandrewc/msu-fiji-database at source commit 0470733c7a75db8517c49b78ea9a3beb4fa4d7c2. Preserves the latest source CSS, responsive layouts, colors, typography, cards, and buttons. No data was copied.

- Website: https://parents.msufiji.com/
- Supabase: dpnarcfneykthucexbuq (Sigma Mu Parents Portal)
- Static GitHub Pages: main branch, repository root; CNAME parents.msufiji.com.
- Entry point: index.html; application: portal/app.js.
- Initial database definition: portal/schema.sql. Apply only to an empty separate parents project.
- Automatic newsletter email delivery is absent/disabled.

## Permissions

All accounts register and complete a parent profile, then require manual administrator approval. A separate Supabase Auth project means Brother Network accounts confer no parent access. Student and registration contact information live in parent_private. Directory contacts are deliberately separate optional fields. Anonymous users cannot read parent tables or newsletters.

Full administrators can delegate requests, parent management, newsletters, announcements, relations, and activity tools. Only the super administrator can change full-admin roles. Protected accounts and the acting administrator cannot be deactivated or demoted through the portal. Administrative changes are logged by database triggers.

Bootstrap the first administrator only after that person has independently registered in the new portal and their identity is verified. A project operator can set that new parent's role to super_admin, protected=true, approved=true. Never transfer Brother Network auth IDs or auto-approve the first signup.

## Authentication setup

Configure Supabase Auth Site URL and the redirect allowlist to https://parents.msufiji.com/. Set up a separate Google web OAuth client in the existing Cloud project, origin https://parents.msufiji.com and callback https://dpnarcfneykthucexbuq.supabase.co/auth/v1/callback. Put the Google client secret only in Supabase Auth provider settings. Auth emails should identify Sigma Mu Parents Portal and link to the parents address. Supply production SMTP before opening unrestricted email registrations.

## Parents Fund activation

The chapter's existing live account is acct_1UVhQu0LKcs9BAsZ. Existing public Parents Fund/Persistence Fund giving remains untouched. This portal must have its own restricted key and webhook, stored only in this new project's server secrets:

- STRIPE_PARENTS_LIVE_KEY (separate restricted LIVE key; Checkout read/write, Products/Prices write as required by Checkout, PaymentIntents read, account read)
- STRIPE_PARENTS_WEBHOOK_SECRET (new endpoint's signing secret)
- STRIPE_PARENTS_LIVE_ACCOUNT_ID=acct_1UVhQu0LKcs9BAsZ
- STRIPE_PARENTS_CHECKOUT_ENABLED=false until verification is complete

New endpoint: https://dpnarcfneykthucexbuq.supabase.co/functions/v1/stripe-donation-webhook
Events: checkout.session.completed, checkout.session.async_payment_succeeded, checkout.session.async_payment_failed, checkout.session.expired, charge.refunded.
Version: 2026-09-30.endive. JWT verification is disabled only at the function gateway; checkout validates Supabase Auth and current database approval itself, and the webhook validates Stripe signatures on the raw body.

Both session and PaymentIntent carry fund=parents, portal=parents, donation_id, member_id. The ledger enforces fund=parents, portal=parents, livemode=true. No test fallback exists. Webhook processing remains available when new checkout is disabled. CRM includes active approved parents only, offline gifts and confirmed online gifts net of refunds; online transactions cannot be manually deleted from CRM.

Before enabling: verify account identity and charges_enabled, restricted-key Checkout permissions, endpoint signature validation, an actual Stripe-delivered signed event, duplicate/out-of-order delivery, delayed success/failure, expiration and refunds. Verify own-history RLS and that no other fund's events are accepted. Use a dedicated isolated Stripe sandbox for simulated payments; do not enable test checkout for ordinary parents. A protected super administrator can use Admin → Parent Relations & Donations → Verify live payment setup (no charge). This creates a $1 live session, immediately expires it, and waits for the actual signed Stripe expiry event. Verification records are excluded from donation histories and CRM totals. Successful verification sets the database gate automatically. Only after all other checks pass, set STRIPE_PARENTS_CHECKOUT_ENABLED=true.

## Validation

Run the transaction-only database scenarios in portal/access-tests.sql through the project SQL executor; they roll back all fixtures. Run portal/payment-tests.mjs with Node. Final browser checks must cover Google callback, email confirmation/recovery, profile completion, approval, publishing/edit/deletion, delegated controls, deactivate/reactivate, CRM/export, and mobile. No live payment should be charged as part of configuration verification.

## Authentication email sender

The existing chapter sender uses Resend. The new project's prepared SMTP settings are sender noreply@msufiji.com, sender name Sigma Mu Parents Portal, host smtp.resend.com, port 465, and username resend. The SMTP password is a Resend API key (re_), entered directly into Supabase Auth SMTP settings. It is not a Stripe key. The original project's settings were read only and left unchanged.

After SMTP is saved, apply the subjects and HTML in portal/auth-email-templates.json in Supabase Authentication → Emails. The Site URL and return allowlist are already https://parents.msufiji.com/. Email confirmation and password recovery still need delivery tests through the new SMTP configuration. Automatic newsletter emails remain disabled independently of authentication mail.
