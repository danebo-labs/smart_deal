# Production deployment (Kamal on AWS)

**Web-first** production: one **EC2** (Ubuntu + Docker), **RDS PostgreSQL** (primary + Solid Cache/Queue/Cable DBs), **Kamal** + **kamal-proxy**, **Docker Hub** registry.

**Before first deploy:** complete [README — New engineer onboarding](../README.md#new-engineer-onboarding) (Docker, buildx, `config/deploy.yml`, `.kamal/secrets`, SSH).

Full step-by-step infra may also live in your team's **production deployment runbook** (not committed).

---

## Cold start / cold stop — full sequence (cheat sheet)

This is the **canonical order** to bring the stack up from a fully stopped state (RDS stopped + EC2 stopped + containers down) or to take it down cleanly. Detailed flags, IAM notes, and troubleshooting live in the sections below.

**Run the steps in order.** Do **not** declare `EC2_ID` / `RDS_ID` upfront with placeholders — they are unknown until Steps 2 and 3 resolve them. Only Step 4 exports the real values.

### Step 1 — AWS context (run first, in every new shell)

```bash
export AWS_PROFILE=your-profile        # only if you use named profiles
export AWS_REGION=us-east-1            # match the region of the EC2 + RDS resources
# aws sso login --profile "$AWS_PROFILE"   # only if the profile uses IAM Identity Center
aws sts get-caller-identity            # sanity check — must show the expected Account/User
```

### Step 2 — Discover the EC2 instance ID

List every EC2 instance in the region (Id, state, `Name` tag, public IP) and pick the app host from the output:

```bash
aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Name:Tags[?Key==`Name`].Value|[0],Ip:PublicIpAddress}' \
  --output table
```

Shortcut — if you already know the `Name` tag (e.g. `smart-deal-web`):

```bash
aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=smart-deal-web" \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

Shortcut — derive it from the host listed in `config/deploy.yml` (`servers.web.hosts`):

```bash
APP_IP=$(grep -A1 '^\s*web:' config/deploy.yml | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1)
aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=ip-address,Values=$APP_IP" \
  --query 'Reservations[].Instances[].InstanceId' --output text
```

Copy the `i-…` value — you will export it in **Step 4**.

### Step 3 — Discover the RDS instance ID (standalone PostgreSQL only, NOT Aurora)

The app connects to a **standalone RDS PostgreSQL** instance (engine `postgres`). Aurora variants (`aurora-postgresql`, `aurora-mysql`) belong to clusters and use **different** start/stop commands (`aws rds start-db-cluster`). The query below **filters those out**:

```bash
aws rds describe-db-instances --region "$AWS_REGION" \
  --query "DBInstances[?Engine=='postgres'].{Id:DBInstanceIdentifier,Status:DBInstanceStatus,Endpoint:Endpoint.Address,Class:DBInstanceClass}" \
  --output table
```

Shortcut — derive it from `DB_HOST` in `.env` / `config/deploy.yml`. The **first segment** of an RDS endpoint (`<id>.<random>.<region>.rds.amazonaws.com`) is the instance identifier:

```bash
grep '^DB_HOST=' .env | cut -d= -f2 | cut -d. -f1
# or, from deploy.yml:
# awk '/DB_HOST:/ {print $2}' config/deploy.yml | cut -d. -f1
```

Confirm the candidate is plain Postgres (not Aurora) before using it:

```bash
aws rds describe-db-instances --db-instance-identifier <candidate-id> --region "$AWS_REGION" \
  --query 'DBInstances[0].Engine' --output text
# → expect: postgres   (NOT aurora-postgresql)
```

### Step 4 — Export the real IDs

Now that Steps 2 and 3 returned concrete values, export them once per shell:

```bash
export EC2_ID=i-09db5c5fc53e973b0     # paste the value from Step 2
export RDS_ID=smart-deal-db            # paste the value from Step 3
export APP_HOST=elevator.danebo.ai     # primary tenant host from config/deploy.yml proxy.hosts (used by /up check)
```

Quick status check before proceeding:

```bash
aws ec2 describe-instances --instance-ids "$EC2_ID" --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].State.Name' --output text   # running | stopped | pending | stopping
aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --region "$AWS_REGION" \
  --query 'DBInstances[0].DBInstanceStatus' --output text           # available | stopped | starting | stopping
```

### Step 5a — Cold start (bring production UP)

Run from the **operator laptop**, **from the project root** (where `Gemfile` lives). `config/deploy.yml` and `.kamal/secrets` must already exist locally.

```bash
# 1) Start RDS first — the DB must be 'available' before Rails boots
aws rds start-db-instance --db-instance-identifier "$RDS_ID" --region "$AWS_REGION"
aws rds wait db-instance-available --db-instance-identifier "$RDS_ID" --region "$AWS_REGION"

# 2) Start EC2
aws ec2 start-instances --instance-ids "$EC2_ID" --region "$AWS_REGION"
aws ec2 wait instance-running --instance-ids "$EC2_ID" --region "$AWS_REGION"
sleep 75   # let Docker / cloud-init settle (~60–90 s)

# 3) Boot the app via Kamal (from repo root, NOT $HOME)
bundle exec kamal deploy
# If no code/config changed and you only want the existing image back up:
# bundle exec kamal app boot

# 4) Verify — must see THREE containers: kamal-proxy, smart-deal-web-<sha>, smart-deal-worker-<sha>
bundle exec kamal app details
curl -sf "https://$APP_HOST/up" && echo OK
```

If `/up` returns `404` or `ERR_SSL_PROTOCOL_ERROR`, only `kamal-proxy` is up — re-run `bundle exec kamal deploy`. See [EC2 stop / start](#ec2-stop--start--avoid-ssl-404-and-half-dead-proxy) and [Troubleshooting](#troubleshooting-quick-map).

### Step 5b — Cold stop (bring production DOWN)

**Reverse order of cold start.** Stopping EC2 while `kamal-proxy` still manages traffic leaves a "half‑dead" proxy on next boot — always stop the app cleanly first. Uses the same env vars exported in Step 4.

```bash
# 1) Stop app containers cleanly (from repo root, so Kamal reads config/deploy.yml)
bundle exec kamal app stop
bundle exec kamal app details   # confirm web + worker are 'stopped' (kamal-proxy stays up — that is fine)

# 2) Stop EC2
aws ec2 stop-instances --instance-ids "$EC2_ID" --region "$AWS_REGION"
aws ec2 wait instance-stopped --instance-ids "$EC2_ID" --region "$AWS_REGION"

# 3) Stop RDS last (so the app never tries to write to a missing DB)
aws rds stop-db-instance --db-instance-identifier "$RDS_ID" --region "$AWS_REGION"
aws rds wait db-instance-stopped --db-instance-identifier "$RDS_ID" --region "$AWS_REGION"

# 4) Verify both are down
aws ec2 describe-instances --instance-ids "$EC2_ID" --region "$AWS_REGION" \
  --query 'Reservations[0].Instances[0].State.Name' --output text   # → stopped
aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --region "$AWS_REGION" \
  --query 'DBInstances[0].DBInstanceStatus' --output text           # → stopped
```

> **AWS auto‑start:** stopped RDS instances are auto‑started by AWS after ~7 days. Plan longer idle windows accordingly. See [Stopping an RDS DB instance temporarily](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html).
>
> **Skip step 1 only if EC2 is already unreachable** (already stopped, network broken). `bundle exec kamal app stop` will hang trying to SSH; in that case go straight to step 2.

### Tenant hosts (host → Account)

Rails serves **only** these hosts (see `config/account_hosts.rb` + `config/deploy.yml` `proxy.hosts`):

| Host | Account slug |
|------|--------------|
| `danebo.ai` | `danebo-legacy` (temporary until landing) |
| `www.danebo.ai` | `danebo-legacy` (temporary until landing) |
| `elevator.danebo.ai` | `danebo-legacy` |
| `ascensoresclimb.danebo.ai` | `elevadores-climb` |

`danebo.ai` / `www.danebo.ai` still serve this Rails app until the marketing landing is ready; then drop them from `proxy.hosts` + `AccountHosts`. `chat.danebo.ai` is retired.

Cross-account login is rejected (sign-out + flash). Mailer canonical host: `elevator.danebo.ai`.

#### Route 53 cutover

DNS is managed in **Route 53** hosted zone `danebo.ai` (no IaC in-repo). EC2 public IP example: `54.163.248.39` — confirm against `config/deploy.yml` / live instance.

**Create/update** (A, TTL 300 recommended during cutover):

| Record | Value | Purpose |
|--------|-------|---------|
| `elevator.danebo.ai` | EC2 public IP | Tenant `danebo-legacy` |
| `ascensoresclimb.danebo.ai` | EC2 public IP | Tenant `elevadores-climb` |

**Keep pointing at this EC2 for now:** `danebo.ai`, `www.danebo.ai` (app until landing), plus the two tenant hosts above.

**Retire / do not point at this EC2:** `chat.danebo.ai`.

Order:

1. Create the tenant A records in R53; wait for propagation (`dig +short elevator.danebo.ai`).
2. Set `proxy.hosts` in local `config/deploy.yml` to apex/www + the two tenant hosts.
3. `bundle exec kamal deploy` (Let's Encrypt certs for new names).
4. `curl -vk https://elevator.danebo.ai/up` and `curl -vk https://ascensoresclimb.danebo.ai/up`.
5. Remove or repoint `chat.danebo.ai`.

Confirm account `elevadores-climb` exists in prod (`bin/rails db:seed` via `kamal app exec --reuse` if needed).

#### Local development (Ascensores Climb)

`localhost` maps to `danebo-legacy`. To exercise the Climb tenant locally, add to `/etc/hosts`:

```
127.0.0.1 ascensoresclimb.danebo.ai elevator.danebo.ai
```

Then open `http://ascensoresclimb.danebo.ai:3000` (or via `bin/dev`).

### Hot deploy (RDS + EC2 already running)

The normal workflow — **do not** stop infra:

```bash
git push                       # from your branch
bundle exec kamal deploy       # from repo root
bundle exec kamal app logs --roles=web -f
```

---

### Kamal production (AWS)

If you are **onboarding a laptop for the first time**, read **[New engineer onboarding](../README.md#new-engineer-onboarding)** first (Docker, buildx, `.kamal/secrets`, SSH keys).

End-to-end notes from shipping **web-first** production on **one EC2** (Ubuntu + Docker), **RDS PostgreSQL** (primary + separate DBs for Solid Cache / Queue / Cable), **Kamal** + **kamal-proxy** (Traefik, Let’s Encrypt), and **Docker Hub** as the image registry. Full step-by-step infra lives in **`~/.claude/plans/production-deployment-runbook.md`** (or your local copy of the production runbook) on the operator’s machine; this section captures **critical constraints**, **architecture**, **commands**, and **troubleshooting** so the repo stays the source of truth.

#### Secrets and Kamal (credentials)

**Do not commit or push:** `config/master.key`, `.env`, **`.kamal/secrets`**, or **`config/deploy.yml`** (those last two are listed in `.gitignore`). The repo only ships **[`config/deploy.yml.example`](../config/deploy.yml.example)** as a template.

| Surface | What to use |
|---------|-------------|
| **Local dev** | **`.env`** (from [`.env.sample`](../.env.sample)) for Postgres (`DB_*`, `CLIENT_DB_*`) and optional AWS keys. Never commit `.env`. |
| **`config/credentials.yml.enc`** | Encrypted secrets for Rails (`bin/rails credentials:edit`); requires **`config/master.key`** locally. Fine to commit the `.enc` file; **never** commit `master.key`. |
| **Kamal (laptop / CI)** | Create **`config/deploy.yml`** with `cp config/deploy.yml.example config/deploy.yml` and edit hosts, Docker image name, registry username, and non-secret `env.clear` values (region, bucket names, KB IDs, DB names). |
| **`.kamal/secrets`** | Dotenv-style file at the **project root** (same level as `Gemfile`). Kamal reads it when you deploy; it must define every name listed under `secret:` and `registry.password` in `deploy.yml`, for example: `RAILS_MASTER_KEY=...`, `DB_PASSWORD=...`, `ANTHROPIC_API_KEY=...`, `APPSIGNAL_PUSH_API_KEY=...`, `KAMAL_REGISTRY_PASSWORD=...` (use a **Docker Hub access token**, not your main password, if possible). |
| **Production AWS auth** | Prefer an **IAM instance profile** on EC2 for Bedrock/S3. Avoid putting `AWS_SECRET_ACCESS_KEY` in `deploy.yml` or in `.kamal/secrets` unless you have no instance role. |
| **Docker Hub** | Only `KAMAL_REGISTRY_PASSWORD` (or CI secret) needs the registry token; the image name and username live in `deploy.yml` (still no password in the YAML file itself). |

If a real **`config/deploy.yml`** with production hosts or IDs was ever pushed to a **public** remote, treat it as a disclosure: rotate **`DB_PASSWORD`**, review **security groups**, and consider **new KB/S3 exposure** only if you pasted secrets (IDs alone are not credentials but ease reconnaissance).

#### Critical infrastructure

| Topic | Requirement |
|-------|---------------|
| **EC2 size** | **At least `t3.medium` (4 GiB RAM)** for `web` + `worker` + `kamal-proxy` + Docker/OS headroom. `t3.micro` (~1 GiB) causes Puma/worker **OOM** (`Exited (137)`), SSH TLS “banner” hangs, and crashloops. `t3.small` is tight; `medium` is the practical floor for MVO. |
| **RDS (Postgres)** | **Primary** app DB **plus** three auxiliary DBs for Solid Stack (`*_cache`, `*_queue`, `*_cable`) — see [`config/database.yml`](../config/database.yml). Create them from the EC2 host with `psql` (RDS is private; laptop cannot connect). **Text-to-SQL** uses a **separate** `client_db` connection (`CLIENT_DB_*` in the same file): provision another database (or cluster) for the client’s business data and set those env vars in Kamal — the committed [`config/deploy.yml.example`](../config/deploy.yml.example) only lists the four Rails multi-db names; add `CLIENT_DB_*` to your real `deploy.yml` when HYBRID / database queries are enabled. |
| **IAM role on EC2** | Instance profile must allow Bedrock invoke/retrieve, KB ingestion read, S3 KB buckets, SSM read for secrets. For **`BEDROCK_MODEL_ID`** values with prefix **`global.`** or **`us.`** (inference profile), IAM **must** include **`bedrock:GetInferenceProfile`** (and **Bedrock model access** enabled in console). Missing it surfaces as app **`502`** on `/rag/ask` with `Not authorized to call GetInferenceProfile`. **`us.`** Haiku profiles invoke the foundation model in **`us-east-2`** — attach **`bedrock:InvokeModel`** on `arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0` (see [`docs/bedrock-iam-policy.json`](bedrock-iam-policy.json)). |
| **`kamal-proxy`** | **Do not remove.** It terminates TLS and routes to the app. Only `web` + `worker` + `kamal-proxy` should run in steady state. |
| **Run Kamal from the repo** | Always `cd` into the **project root** (where the `Gemfile` lives). Ensure **`config/deploy.yml`** exists (`cp config/deploy.yml.example config/deploy.yml` first). Running `bundle exec kamal` from `$HOME` fails with “Could not locate Gemfile” or the wrong config path. |

#### Architecture (production)

| Piece | Role |
|-------|------|
| **`config/deploy.yml`** | **Not in git** — copy from [`config/deploy.yml.example`](../config/deploy.yml.example). Kamal: `servers.web`, `servers.worker`, `proxy` (`host`, `app_port: 80`), registry, `env`, `ssh`. Memory/CPU limits are set per role. Production secrets include `ANTHROPIC_API_KEY` for web/bulk uploads and `APPSIGNAL_PUSH_API_KEY` for production monitoring. |
| **Single `worker` container** | One process runs `bundle exec rake solid_queue:start` and loads **`config/queue.yml`**, which registers **three lanes**: `default` (4 threads, `polling_interval: 1`), `ingestion` (1 thread, `polling_interval: 2`), and **`bulk_ingestion`** (2 threads, `polling_interval: 2`) for **`ProcessBulkUploadJob`**, **`SubmitClaudeBatchJob`**, **`PollClaudeBatchJob`**, **`IngestBatchResultsJob`**, **`PollBulkBedrockIngestionJob`**. Long polls stay off the `default` lane **without** extra worker containers. |
| **Solid Queue polling vs Aurora warmup** | Worker **`polling_interval`** only controls how often Solid Queue **polls the queue DB** (RDS `solid_queue_*` tables). It does **not** wake the Bedrock KB vector store. **Aurora / KB warmup** is **`WarmBedrockKbJob`** (throttled retrieve against the KB), enqueued from **`HomeController#index`** and **`Users::SessionsController#after_sign_in_path_for`**. |
| **Metrics footer** | Updated when **`TrackBedrockQueryJob`** runs (after a real Bedrock path) and broadcasts Turbo Streams; there is **no** browser polling. Slower Solid Queue polling delays the footer slightly; it does not affect answer latency. |
| **Default KB list rows** | **Not** hardcoded in the UI. **`RecentKbDocumentsQuery`** reads **`kb_documents`**. Seed rows come from **`db/seeds.rb`** (`KB_DOCUMENT_SEEDS`); real uploads add rows via **`QueryOrchestratorService#ensure_kb_document_for`**. |

#### Production config map (committed templates)

This is the **in-repo** picture operators extend when building `config/deploy.yml` (the example is not a full production env — hosts, KB IDs, buckets, and `CLIENT_DB_*` are placeholders).

| File | What production derives from it |
|------|----------------------------------|
| [`config/deploy.yml.example`](../config/deploy.yml.example) | **Kamal:** `service: smart-deal`, **one host** runs both **`web`** (Puma, `memory`/`cpus` limits) and **`worker`** (`bundle exec rake solid_queue:start`). **`proxy`:** TLS, public host, `app_port: 80` to Puma. **Registry:** Docker Hub (`KAMAL_REGISTRY_PASSWORD` in `.kamal/secrets`). **`env.clear`:** `RAILS_ENV`, logging/static flags, `RAILS_MAX_THREADS`, `AWS_REGION`, `DB_HOST` / `DB_USERNAME` / `DB_NAME` / `DB_{CACHE,QUEUE,CABLE}_NAME`, Bedrock KB + bulk data source + model IDs, `KNOWLEDGE_BASE_S3_BUCKET`, `INGESTION_REENQUEUE`, `AWS_HTTP_READ_TIMEOUT`, `QUERY_ROUTING_ENABLED`, `SHARED_SESSION_ENABLED`. **`secret`:** `RAILS_MASTER_KEY`, `DB_PASSWORD`, `ANTHROPIC_API_KEY`, `APPSIGNAL_PUSH_API_KEY`. **SSH** user + key path. |
| [`config/database.yml`](../config/database.yml) | **Rails 8 multi-database:** `primary`, `cache`, `queue`, `cable` (all PostgreSQL in production; separate DB **names** on RDS). **Connection pool:** `RAILS_MAX_THREADS + 2`. **`client_db`:** PostgreSQL in dev/prod via `CLIENT_DB_*`; SQLite file only in **test**. |
| [`config/queue.yml`](../config/queue.yml) | **Solid Queue** production inherits **three worker definitions:** `default`, `ingestion`, and **`bulk_ingestion`** — one OS process inside the Kamal **worker** container. |
| [`config/routes.rb`](../config/routes.rb) | **`MissionControl::Jobs`** mounted at **`/jobs`** in non-test envs (HTTP auth via credentials — see pre-deploy checklist). **`resources :bulk_uploads`** — `new`, `create`, `show` (signed-in bulk ZIP flow). Health: **`/up`**. Twilio webhook remains commented out. |

#### EC2 stop / start — avoid SSL 404 and “half-dead” proxy

Stopping the instance **without** bringing the app up cleanly can leave **`kamal-proxy` running** (restored state) while **`smart-deal-web` / `smart-deal-worker` are stopped** → HTTP `404` from the proxy on `/up`, `ERR_SSL_PROTOCOL_ERROR` / TLS handshake errors (`unknown server name`), or empty `service`/`target` in proxy logs.

**Recommended:**

1. Before stop (optional but cleaner): from repo, `bundle exec kamal app stop`.
2. `aws ec2 stop-instances --instance-ids i-…` (see [AWS EC2 from your laptop](#aws-ec2-from-your-laptop-cli)).
3. After start: `aws ec2 wait instance-running --instance-ids i-…`, wait **60–90 s** for Docker.
4. From repo: **`bundle exec kamal deploy`** (preferred) or `bundle exec kamal app boot` — then confirm **`docker ps`** shows **three** containers: `kamal-proxy`, `smart-deal-web-<sha>`, `smart-deal-worker-<sha>` (same image tag).

**Do not** assume `curl https://…/up` after boot without checking containers.

#### AWS EC2 from your laptop (CLI)

Use the **AWS CLI** from your machine when you want to power-cycle the VM **without** opening the AWS console (same IAM permissions you use for the account/region as in the console: typically `ec2:StartInstances`, `StopInstances`, `RebootInstances`, `DescribeInstances`).

**Profile and region** (adjust to your setup):

```bash
export AWS_PROFILE=your-profile   # if you use named profiles
export AWS_REGION=us-east-1       # match the instance region
# If this profile uses IAM Identity Center (SSO):
# aws sso login --profile your-profile
```

**Resolve instance IDs** — replace the tag filter with your naming convention (or use the EC2 console **Instance ID** column):

```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Name:Tags[?Key==`Name`].Value|[0],Ip:PublicIpAddress}' \
  --output table
```

**Start** (instance was `stopped` — billing for compute stops while stopped; **Elastic IP** may incur charges if associated):

```bash
aws ec2 start-instances --instance-ids i-0123456789abcdef0
# Multiple hosts in one call — separate IDs with spaces:
# aws ec2 start-instances --instance-ids i-aaa i-bbb
aws ec2 wait instance-running --instance-ids i-0123456789abcdef0
```

Then wait **60–90 s** for Docker and run **`bundle exec kamal deploy`** or **`bundle exec kamal app boot`** from the repo root; verify **`docker ps`** on the host.

**Stop** (schedule downtime / save cost):

```bash
# Optional first — graceful stop of app containers (from repo root):
bundle exec kamal app stop

aws ec2 stop-instances --instance-ids i-0123456789abcdef0
# Optional: wait until fully stopped (useful in scripts)
aws ec2 wait instance-stopped --instance-ids i-0123456789abcdef0
```

To bring the **same** containers back after **`kamal app stop`** (no new image yet): **`bundle exec kamal app start`** from the repo root. Prefer **`kamal deploy`** when you need a fresh build or config roll-forward.

**Reboot** (guest OS restart; **ephemeral state only** — volumes persist). Useful after kernel patches or a wedged host; Docker/containers **may** come back depending on restart policy — **always verify**:

```bash
aws ec2 reboot-instances --instance-ids i-0123456789abcdef0
```

After reboot, SSH in and run **`docker ps`**; if **web/worker** are missing while **`kamal-proxy`** is up, run **`bundle exec kamal deploy`** from the laptop (same recovery as stop/start).

**Hotfix / normal deploy** — you usually **do not** stop EC2:

1. Commit and push from your branch.
2. **`cd`** to the **project root** (where the `Gemfile` lives); ensure **`config/deploy.yml`** and **`.kamal/secrets`** exist.
3. **`bundle exec kamal deploy`** — builds (unless you change build settings), pushes the image, restarts containers.

Use **`bundle exec kamal console`** when you need **Rails console** against production without SSH. For a **maintenance window** where you halt compute: **`kamal app stop`** → **`aws ec2 stop-instances`** (order as above).

#### AWS RDS PostgreSQL — stop / start

To **stop** the application Postgres instance (saves RDS compute when the stack is down; adjust `--db-instance-identifier` if yours differs). IAM needs `rds:StopDBInstance` / `rds:StartDBInstance` (and `DescribeDBInstances` for status). You can run these from **your laptop** with the AWS CLI (same profile/region pattern as [EC2 above](#aws-ec2-from-your-laptop-cli)) or from **AWS CloudShell** in the console (pre-authenticated to the account; paste the commands there).

**Stop:**

```bash
aws rds stop-db-instance --db-instance-identifier smart-deal-db --region us-east-1
```

**Start:**

```bash
aws rds start-db-instance --db-instance-identifier smart-deal-db --region us-east-1
```

After **start**, wait until the instance status is **`available`** before starting EC2 / Kamal or expecting DB connections. RDS stopped instances are subject to AWS auto-start rules (see [Stopping an RDS DB instance temporarily](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html)); plan longer idle windows accordingly.

#### Indispensable commands (operator laptop)

From **`/path/to/smart_deal`**:

```bash
bundle exec kamal config
bundle exec kamal deploy
bundle exec kamal app details
bundle exec kamal app logs --roles=web -f
bundle exec kamal app logs --roles=worker -f
bundle exec kamal proxy logs -n 200
```

**Rails console** (uses `--reuse` per `deploy.yml` aliases):

```bash
bundle exec kamal console
```

**DB console** (Postgres inside the web container):

```bash
bundle exec kamal dbc
```

**One-off command** (prefer `--reuse` to avoid a cold pull when `web` is healthy):

```bash
bundle exec kamal app exec --reuse 'bin/rails runner "puts KbDocument.count"'
```

Migrations (four databases):

```bash
bundle exec kamal app exec --reuse "bin/rails db:migrate"
bundle exec kamal app exec --reuse "bin/rails db:migrate:cache"
bundle exec kamal app exec --reuse "bin/rails db:migrate:queue"
bundle exec kamal app exec --reuse "bin/rails db:migrate:cable"
```

**Validate `config/queue.yml` with Ruby 3.4+** (YAML merge keys need aliases):

```bash
ruby -ryaml -e 'p YAML.load_file("config/queue.yml", aliases: true).dig("production", "workers").size'
# expect 3 worker lane definitions
```

#### SSH + Docker on the server

```bash
ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@<EC2_IP>
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
docker stats --no-stream
free -m
sudo ss -tlnp | grep -E ':80|:443'
docker logs kamal-proxy --tail 100
```

**Orphan containers:** if you **rename** Kamal roles (e.g. two workers → one), old containers (`smart-deal-worker_*` old names) may keep running until **`docker rm -f …`**. Kamal does not always delete roles it no longer manages.

#### Connect to RDS PostgreSQL

RDS is **private** — connect **from the EC2** box (after `postgresql-client` is installed), not from the laptop:

```bash
# On EC2 — use real host/password from SSM or your runbook
export PGHOST=<rds-endpoint>
export PGUSER=app_user
export PGPASSWORD='<secret>'
psql -d smart_deal_production -c '\conninfo'
```

Or one-liner from laptop via SSH:

```bash
ssh -i ~/.ssh/smart-deal-deploy.pem ubuntu@<EC2_IP> \
  "PGPASSWORD='...' psql -h <rds-endpoint> -U app_user -d smart_deal_production -c 'SELECT 1'"
```

#### Troubleshooting (quick map)

| Symptom | Likely cause | What to check |
|---------|----------------|---------------|
| **`502`** on `/rag/ask`, log: **`GetInferenceProfile`** / not authorized | EC2 role missing **`bedrock:GetInferenceProfile`** and/or Bedrock **model access** off for Haiku profile | IAM policy + Bedrock console; on EC2: `aws bedrock get-inference-profile --inference-profile-identifier <id> --region us-east-1` |
| **`ERR_SSL_PROTOCOL_ERROR`** / HTTP **`404`** on `/up` for `elevator.danebo.ai` | Only **`kamal-proxy`** up; **web/worker** down after instance stop/start | `docker ps`; then `kamal deploy` from repo root |
| **`Exited (137)`** on web | **OOM** (instance too small or memory limit too low) | `free -m`; `dmesg \| grep -i oom`; resize EC2 or lower `deploy.yml` memory **carefully** |
| **`app boot` / unhealthy web with `:latest`** | Stale or wrong **`latest`** image on registry vs known-good **git SHA** tag | Prefer **`kamal deploy`** (builds/pushes current SHA) |
| **`unknown server name`** in proxy logs | Client without SNI, scanners — often noise; if **your** browser fails, fix router/cert state first | `curl -vk https://elevator.danebo.ai/up` |
| **Duplicate workers processing** | Old **orphan** containers after role change | `docker ps -a`; remove stopped/old names |
| **`kamal app exec` hangs on `docker login`** | Exec without **`--reuse`** pulls a fresh image | Use **`--reuse`** when `web` is running |
