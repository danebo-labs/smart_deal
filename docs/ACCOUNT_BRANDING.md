# Account branding (host → tenant)

**Status:** Stage 1 — static assets per account slug. Live for `elevadores-climb` on `ascensoresclimb.danebo.ai` (commit `942199a`).

**Audience:** engineers onboarding a branded tenant or verifying deploy.

---

## What it does

Each request host resolves to an `Account` (see [PRODUCTION.md — Tenant hosts](PRODUCTION.md#tenant-hosts-host--account)). When `accounts.branded` is `true`, the signed-in web app and Devise auth surfaces show that account's logo, favicon, apple-touch icon, page title, and footer — instead of the default Danebo assets.

| Surface | Branded tenant | Default (`branded: false`) |
|---------|----------------|----------------------------|
| `<title>`, `application-name` | `display_name` (e.g. Ascensores Climb) | Danebo |
| Favicon / apple-touch | `accounts/<slug>/favicon.png`, `/brands/<slug>/icon-180.png` | `favicon.png`, `/icon-180.png` |
| Nav logo, KB sidebar, auth panels | `accounts/<slug>/logo.png` (horizontal wordmark) | `logo_mobile.png` / `logo_desktop2.jpg` |
| Text wordmark `danebo` + `.ai` | Hidden (logo carries the name) | Shown next to logo |
| Footer | `© 2026 <display_name>` | `© 2026 danebo.ai` |

**Out of scope (MVP):** per-account color themes, admin logo upload UI, Active Storage / S3 for brand assets, PWA manifest, per-account i18n for auth marketing copy (`auth.brand.*` stays Danebo text).

---

## Request flow

```text
Host (ascensoresclimb.danebo.ai)
  → AccountHosts (config/account_hosts.rb)
  → AccountHostResolver → Account (slug: elevadores-climb)
  → ApplicationController#current_account (memoized, 1 DB query)
  → AccountBranding.for(account) via helper account_branding
  → layouts / auth partials / KB card / footer
```

No extra DB queries beyond the `Account` row already loaded for host resolution. `AccountBranding` reads only `slug`, `display_name`, and `branded`.

Login and session scoping are unchanged: `user.account_id` must match the host account (`Users::SessionsController`, `ApplicationController#ensure_user_belongs_to_host_account!`).

---

## Data model

| Column | Type | Notes |
|--------|------|-------|
| `slug` | string, NOT NULL, unique | Stable key; used in asset paths and `AccountHosts` |
| `display_name` | string, NOT NULL | Human label (title, footer, `logo_alt`). Defaults to `slug` if blank on create |
| `branded` | boolean, default `false` | `true` → use assets under `accounts/<slug>/`; `false` → Danebo defaults |

Seeds / fixtures:

| Slug | `display_name` | `branded` | Host |
|------|----------------|-----------|------|
| `danebo-legacy` | Danebo | `false` | `elevator.danebo.ai`, apex/www (temporary) |
| `elevadores-climb` | Ascensores Climb | `true` | `ascensoresclimb.danebo.ai` |

Migration: `db/migrate/20260710010942_add_display_name_and_branded_to_accounts.rb` (backfills known slugs in SQL).

---

## Static assets (convention)

Assets are **committed to the repo** and baked into the Docker image at build time (Propshaft + `public/`). No runtime upload.

| Asset | Path | Size / notes |
|-------|------|--------------|
| Logo (wordmark) | `app/assets/images/accounts/<slug>/logo.png` | 2× source width; transparent PNG |
| Favicon | `app/assets/images/accounts/<slug>/favicon.png` | 32×32; wordmark padded on square canvas |
| Apple touch | `public/brands/<slug>/icon-180.png` | 180×180; same padding |

Default Danebo assets (unchanged):

- `app/assets/images/favicon.png`, `logo_mobile.png`, `logo_desktop2.jpg`
- `public/icon-180.png`

### Generate assets for a new tenant

One-shot dev/ops script (requires `vips` / `ruby-vips`):

```bash
bundle exec ruby script/generate_account_brand_assets.rb /path/to/wordmark.png <slug>
```

Example (Climb):

```bash
bundle exec ruby script/generate_account_brand_assets.rb \
  ~/Downloads/climb-190x64-org.avif elevadores-climb
```

Commit the three output files, then set `branded: true` and `display_name` on the account (seeds or console).

Horizontal wordmarks need wider logo classes in views (`w-auto max-w-*`, not square `w-7 h-7`). Branded auth/KB surfaces already branch on `account_branding.branded?`.

---

## Code map

| Piece | Location |
|-------|----------|
| Host → slug map | `config/account_hosts.rb` |
| DB resolution | `app/services/account_host_resolver.rb` |
| Brand resolver | `app/services/account_branding.rb` |
| View helper | `app/helpers/application_helper.rb` (`account_branding`) |
| Layouts | `app/views/layouts/application.html.erb`, `devise.html.erb` |
| Auth brand | `app/views/devise/shared/_auth_brand_panel.html.erb`, `_auth_mobile_brand.html.erb` |
| KB sidebar header | `app/views/home/_kb_docs_card.html.erb` |
| Footer | `app/views/shared/_app_footer.html.erb` |

Tests: `test/services/account_branding_test.rb`, `test/integration/account_branding_test.rb`.

---

## Deploy (production)

Normal `kamal deploy` covers both schema and assets:

1. **Migration** — `bin/docker-entrypoint` runs `bin/rails db:prepare` when the **web** container starts (`./bin/rails server`). The migration backfills `display_name` / `branded` for existing accounts; no separate `db:seed` required for branding fields.
2. **Assets** — PNGs under `app/assets/images/accounts/` and `public/brands/` are `COPY`’d into the image and precompiled (`Dockerfile` → `assets:precompile`). No manual upload to the server.

Verify after deploy:

```bash
curl -vk https://ascensoresclimb.danebo.ai/up
# Browser: favicon, title "Ascensores Climb", Climb logo in nav — no "danebo.ai" wordmark
```

Worker containers (`solid_queue:start`) do **not** run `db:prepare`; only web boot migrates.

---

## Local development

`localhost` → `danebo-legacy` (default Danebo branding).

To test Climb locally, add to `/etc/hosts`:

```text
127.0.0.1 ascensoresclimb.danebo.ai elevator.danebo.ai
```

Open `http://ascensoresclimb.danebo.ai:3000` and sign in as a user on the `elevadores-climb` account (`users(:two)` in fixtures).

---

## Onboarding a new branded tenant (checklist)

1. Create `Account` with unique `slug`, `display_name`, `branded: true`.
2. Add host → slug in `config/account_hosts.rb` (`PRODUCTION` + `DEVELOPMENT`).
3. Add hostname to `config/deploy.yml` `proxy.hosts` (SSL).
4. Route 53 A record → EC2 (see [PRODUCTION.md](PRODUCTION.md#route-53-cutover)).
5. Generate and commit brand assets (`script/generate_account_brand_assets.rb`).
6. `kamal deploy`.
7. Create users with `account_id` pointing at the new account.

Related: tenant isolation roadmap — [MULTI_TENANT_ARCHITECTURE.md](MULTI_TENANT_ARCHITECTURE.md).
