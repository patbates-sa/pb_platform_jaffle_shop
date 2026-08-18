# Migrating this project to the dbt platform

Goal: run this project in the dbt platform **without disturbing the working dbt Core
setup**. Nothing in `models/` changes. The local `dbt build --target prod` keeps working
exactly as it does today.

Isolation is total — separate repo, separate platform project, separate schemas:

| | dbt Core (existing) | dbt platform (new) |
|---|---|---|
| GitHub repo | `pb_core_jaffle_shop` | `pb_platform_jaffle_shop` |
| Platform project | *n/a* | `pb_platform_jaffle_shop` |
| Local directory | `~/dbt/pb_core_jaffle_shop` | `~/dbt/pb_platform_jaffle_shop` |
| Prod schema | `pb_analytics.dbt_core_prod` | `pb_analytics.dbt_platform_prod` |
| Dev schema | `pb_analytics.dbt_core_pbates` | `pb_analytics.dbt_platform_pbates` |

> **`dbt_project.yml` stays byte-identical between the two repos**, including
> `name: 'pb_core_jaffle_shop'`. The platform project name is set in the UI and has
> nothing to do with the `name:` key in the file. Renaming it would mean also updating
> `profile:` and the `models: pb_core_jaffle_shop:` config block — and would make every
> future sync from the Core repo conflict on that file.

Schema mapping in full:

| Runs from | Writes to |
|---|---|
| Local dbt Core, `--target dev` | `pb_analytics.dbt_core_pbates` |
| Local dbt Core, `--target prod` | `pb_analytics.dbt_core_prod` |
| **dbt platform, development** | **`pb_analytics.dbt_platform_pbates`** |
| **dbt platform, production job** | **`pb_analytics.dbt_platform_prod`** |

All four read the same `pb_raw` sources. Because the two sides never write to the same
relation, you can build both and diff the results to prove the migration is faithful.

## How the pieces nest

Worth having this straight before clicking anything, because environments can't be
created in isolation:

```
Account
├── Connection (Snowflake)         ← account-level, shared across projects; you have this
├── Git integration (GitHub app)   ← account-level
└── Project  ("pb_platform_jaffle_shop")
    ├── Repository                 ← pb_platform_jaffle_shop, assigned during setup
    ├── Connection profile         ← deployment credentials, project-level
    └── Environments
        ├── Development  (1 max)   → dbt_platform_pbates
        └── Deployment             → Production (1), Staging (1), General (many)
            └── Jobs               → deploy / CI / merge
```

The connection is reusable across projects, so the existing one is fine. What doesn't
exist yet is the **repo** and the **project**.

---

## What does NOT change

Verified against this project — every item below was checked, not assumed:

| Concern | Status |
|---|---|
| Models, sources, tests, YAML | **Unchanged.** The repo *is* the project; there's no import or conversion step |
| `dbt_project.yml` | **Unchanged** |
| `packages.yml` / `package-lock.yml` | **Unchanged** |
| `env_var()` calls in project code | **None exist.** Nothing to rename |
| `{{ target.name }}` branching | **None exists.** No partial-parsing refactor needed |
| `generate_schema_name` override | **None exists.** Default schema behavior applies |
| `.gitignore` | Already contains `target/`, `dbt_packages/`, `logs/` — verified |
| Pre-commit hooks / codegen scripts | **None.** So the Studio IDE is viable; you aren't forced onto the dbt CLI |
| `profiles.yml` | Stays where it is. The platform ignores it — each environment replaces one target |

That's an unusually clean migration, and it's a direct consequence of decisions already
made in this project: sources instead of hardcoded relations, no `target` logic, no
custom schema macros.

---

## Prerequisites

- [ ] dbt platform account with a Snowflake connection configured — **you have this**
- [ ] A **Snowflake key pair** for credentials (see the warning below)
- [ ] GitHub org owner rights, to install the dbt GitHub app
- [ ] dbt **Owner** or **Account Admin** to install the app and create projects
- [ ] The repo pushed to GitHub — **done**

> ### Key pair auth is required
>
> You cannot create new Snowflake credentials with username and password in the dbt
> platform. New development and deployment credentials default to **key pair**
> authentication. Snowflake OAuth is also available for user credentials on
> Enterprise-tier plans.
>
> Your local `profiles.yml` uses a password, so this is the one piece of genuinely new
> setup. Generate a key pair before you start:
>
> ```bash
> openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
> openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
> ```
>
> Register the public key in Snowflake:
>
> ```sql
> alter user <your_user> set rsa_public_key='<contents of rsa_key.pub, no header/footer>';
> ```
>
> Note: specifying a private key via an environment variable (for example
> `{{ env_var('DBT_PRIVATE_KEY') }}`) is **not** supported in the platform.

---

## Step 0 — Create the isolation schemas

```bash
snow sql -f setup/01_create_objects.sql
```

Idempotent (`create schema if not exists`), so it's safe to re-run. This adds
`dbt_platform_prod` and `dbt_platform_pbates` and leaves everything else alone.

**Verify:**

```sql
show schemas in database pb_analytics;
```

You should see four: `dbt_core_pbates`, `dbt_core_prod`, `dbt_platform_pbates`,
`dbt_platform_prod`.

---

## Step 1 — Create the platform repo, seeded from this one

Clone the Core repo into a new directory, keep the original as a named remote, then push
to a brand-new GitHub repo:

```bash
cd ~/dbt
git clone https://github.com/<your-username>/pb_core_jaffle_shop.git pb_platform_jaffle_shop
cd pb_platform_jaffle_shop

# Keep the Core repo reachable as 'core' so you can pull its changes later
git remote rename origin core

# Create the new repo and make it 'origin'
gh repo create pb_platform_jaffle_shop --private --source=. --remote=origin --push
```

Without `gh`, create the empty repo at github.com/new first (no README, no .gitignore),
then:

```bash
git remote add origin https://github.com/<your-username>/pb_platform_jaffle_shop.git
git push -u origin main
```

Cloning rather than copying files preserves the full commit history, so the platform repo
carries the provenance of how the project was built.

**Verify:**

```bash
git remote -v
```

You should see `core` pointing at `pb_core_jaffle_shop` (fetch/push) and `origin` at
`pb_platform_jaffle_shop`.

> ### The tradeoff you're accepting
>
> Two repos means the code can drift. That's fine — desirable, even, while you're
> validating — but it's a real cost, so sync deliberately rather than by accident. See
> [Keeping the two repos in sync](#keeping-the-two-repos-in-sync) below.

---

## Step 2 — Connect GitHub at the account level

**Account settings** → **Integrations** → connect GitHub.

Use the **native GitHub integration**, not "import by Git URL." The native integration
is what enables:

- CI builds triggered when pull requests open
- Automatic teardown of temporary CI schemas (this relies on provider webhooks, so URL
  imports leak schemas)
- Run statuses reported back onto the PR
- Merge jobs, which need push events

Installing the app requires GitHub **organization owner** rights. Then link your personal
GitHub profile: account name → **Account settings** → **Personal profile** → **Linked
accounts** → **Link** next to GitHub.

> The repository name must match the case in the GitHub URL exactly.

Doing this before project creation means the repo is selectable from a dropdown during
setup, rather than interrupting it halfway through.

---

## Step 3 — Create the platform project

**Account settings** (click your account name in the left side menu) → **+ New Project**.

1. Enter a **Project name**: `pb_platform_jaffle_shop`
2. Click **Continue**.
3. Under **Configure your development environment**, open the **Connection** dropdown and
   select your existing Snowflake connection. Connections are account-level and shared,
   so there's nothing new to create here.
4. Set up the **repository**: choose GitHub and pick **`pb_platform_jaffle_shop`** — the
   new repo, not the Core one.

> Double-check the repo selection. Pointing this project at `pb_core_jaffle_shop` would
> couple the platform to the repo you're trying to leave alone, and CI jobs would start
> opening checks on your Core pull requests.

**Verify:** the project appears in **Account settings** → **Projects**, showing your
Snowflake connection and the `pb_platform_jaffle_shop` repository.

---

## Step 4 — Create the development environment

Doing development before production lets you confirm the project parses and compiles
before you point anything at a production schema.

**Orchestration** → **Environments** → **+ Create Environment**.

> Older docs pages label this **Deploy** → **Environments**. Same place.

| Field | Value |
|---|---|
| Environment name | `Development` |
| Environment type | Development |
| dbt version | **Match your local version first** — see below |

Only one development environment is allowed per project.

Then set your personal credentials at
`https://YOUR_ACCESS_URL/settings/profile#credentials` → select this project →
**Edit** → under **User credentials**, enter your key pair and set the schema to:

```
dbt_platform_pbates
```

Each developer gets their own schema here — this is the direct replacement for
per-developer `profiles.yml` targets. Use credentials specific to you, never the
production ones.

> ### Pin the dbt version before you migrate
>
> Run `dbt --version` locally and set environments to match. Migrate, validate, and only
> *then* move to a release track as a separate change. This keeps "did the platform
> migration work?" and "did a version upgrade break something?" from being the same
> question.
>
> Note that **Fusion Stable** is now the default for new deployment environments on
> eligible tiers — so if you're on Fusion locally, that may already line up.

**Verify:** click **Test connection**, then open the Studio IDE and run:

```
dbt compile
dbt show --select dim_customers --limit 5
```

If that compiles, the whole project is valid in the platform. Nothing was written to
production and nothing was scheduled.

---

## Step 5 — Create the production environment

**Orchestration** → **Environments** → **Create Environment**.

| Field | Value |
|---|---|
| Environment name | `Production (platform)` |
| Environment type | Deployment |
| Set deployment type | Production |
| dbt version | Same as Step 4 |
| Custom branch | leave off (uses `main`) |

Under **Deployment connection** (Snowflake exposes exactly three fields here):

| Field | Value |
|---|---|
| Role | `TRANSFORMER` |
| Database | `pb_analytics` |
| Warehouse | `TRANSFORMING` |

The **schema** is *not* set here — it comes from the connection profile in Step 6.

Mark this as the project's production environment. Catalog and cross-project references
both depend on there being one.

---

## Step 6 — Set deployment credentials via a connection profile

Deployment credentials are managed through **connection profiles**, created at the
project level and assigned to deployment environments.

**Orchestration** → **Environments** → your production environment → **Settings** →
**Edit** → scroll to **Connection profiles** → swap icon → **Add new profile** →
**Create profile**.

In the profile: pick your Snowflake connection, then configure **Deployment credentials**
with your key pair (**Private Key** and **Private Key Passphrase**) and set the target
schema to:

```
dbt_platform_prod
```

**This is the setting that keeps your Core prod tables safe.** If it says
`dbt_core_prod`, platform jobs will overwrite what your local runs build.

> Profile names must be unique across all projects in the account, start with a letter,
> end with a letter or number, and contain only letters, numbers, dashes, or
> underscores — no consecutive dashes or underscores.
>
> Profiles don't apply to development environments; those use the individual user
> credentials from Step 4.

**Verify:** click **Test connection**.

---

## Step 7 — Create the deploy job

On the production environment page: **Create job** → **Deploy job**.

| Setting | Value |
|---|---|
| Job name | `Daily build` |
| Commands | `dbt build` |
| Run source freshness | ✅ enabled — runs `dbt source freshness` first |
| Generate docs on run | ✅ (not applicable to Fusion jobs) |
| Triggers | Leave unscheduled while validating |

Scheduling notes for when you do turn it on:

- **All schedules run in UTC.** No local timezone, no daylight saving adjustment.
- Timing options are **Intervals**, **Specific hours**, or **Cron schedule**.
- Don't put a `state:modified` selector on a scheduled job — it can complete
  successfully having built zero models when nothing changed. Reserve it for CI and
  merge jobs.

### Cut over gradually

Don't run the whole DAG on the first attempt. Start with a slice:

```
dbt build --select stg_stripe__payments
```

Confirm the table lands in `pb_analytics.dbt_platform_prod` and nowhere else, then widen:

```
dbt build --select staging
dbt build
```

**Verify** after a full run:

```sql
select count(*) as platform_rows from pb_analytics.dbt_platform_prod.dim_customers;
select count(*) as core_rows     from pb_analytics.dbt_core_prod.dim_customers;
```

Both should be 100. For a stronger check, confirm the two are identical:

```sql
select count(*) as differences from (
    select * from pb_analytics.dbt_platform_prod.dim_customers
    minus
    select * from pb_analytics.dbt_core_prod.dim_customers
);
```

Zero differences means the platform reproduces your Core output exactly. That's the
migration proven, with your original tables still sitting there untouched.

---

## Step 8 — Add a CI job

Worth doing even before you rely on the platform for production, since this project has
no CI today.

**Create job** → **Continuous integration job**. Default command:

```
dbt build --select state:modified+
```

- **Triggered by pull requests** is on by default.
- **Compare changes against** defaults to your Production environment.
- CI builds into temporary schemas prefixed `dbt_cloud_pr_`, dropped automatically after
  the PR closes.

> **Prerequisite:** state comparison only works when there's a deferred environment with
> a successful run to compare against. Complete Step 7 first, or CI will have no
> baseline. If you see schema errors referencing a *previous* PR, you're deferring to
> self instead of to a production job.

dbt Labs recommends putting CI jobs in their own deployment environment connected to a
staging database, for better isolation from production builds. Optional here given the
project's size.

**Verify:** open a trivial PR (add a comment to a model) and confirm the CI check runs
and builds only the modified model plus its children.

---

## Step 9 — Catalog

Requires Starter, Enterprise, or Enterprise+, a production or staging deployment
environment, and **at least one successful job run**. CI job runs do not update Catalog.

For full metadata, one job must run `dbt build`, `dbt docs generate`, and
`dbt source freshness` **together in the same job**. Specifically:

| To see | Must run |
|---|---|
| Model lineage, details, results | `dbt run` or `dbt build` |
| Columns and statistics | `dbt docs generate` |
| Test results | `dbt test` or `dbt build` |
| Source freshness results | `dbt source freshness` |

`dbt compile` alone will not update model metadata. Column-level lineage needs *both*
`dbt docs generate` **and** an Enterprise-tier plan.

> If an environment has no job runs for 3 months, its metadata is purged. Schedule
> something at least quarterly.

---

## Environment variables

Nothing to migrate — this project has no `env_var()` calls in its code. The variables in
`profiles.yml` are only read by local dbt Core, and all already carry the `DBT_` prefix.

For future reference, the platform requires every variable to be prefixed `DBT_`,
`DBT_ENV_SECRET_`, or `DBT_ENV_CUSTOM_ENV_`. Keys are uppercased and case-sensitive, and
must match `env_var('...')` in code exactly. Use `DBT_ENV_SECRET_` for anything that
should be scrubbed from logs and obfuscated in the UI.

Precedence, lowest to highest:

1. The `default` argument to `env_var()` in code
2. Project-wide default
3. Environment level
4. Job override, or a developer's personal override

Set project defaults and per-environment values at **Orchestration** → **Environments**
→ **Environment variables**. Job overrides live in the job's **Advanced settings**.
Personal overrides live in **Account settings** → **Credentials** → your project.

> Without a project-level default for every variable, dbt raises
> `Env var required but not provided`.

---

## Keeping the two repos in sync

Because `git remote rename origin core` kept the Core repo attached, pulling changes
forward is a two-command operation from the platform repo:

```bash
cd ~/dbt/pb_platform_jaffle_shop
git fetch core
git merge core/main
git push
```

Changes flow **Core → platform**, not the other way. Pick one repo as the source of
truth for model code and stick to it — bidirectional syncing between two repos with
divergent history is how you end up resolving the same conflict repeatedly.

To see what has drifted before merging:

```bash
git fetch core
git diff HEAD core/main -- models/ dbt_project.yml packages.yml
```

An empty diff on those paths means the two projects are still transformation-identical,
which is what makes the `MINUS` comparison in Step 7 meaningful.

Files that are *expected* to differ eventually: `MIGRATION.md` (only relevant to the
platform side), and `profiles.yml.example` if you drop it from the platform repo — the
platform doesn't read `profiles.yml`, so it's dead weight there. Neither affects model
output.

---

## Rolling back

Nothing to undo in the Core repo — it was never modified. To abandon the migration:
delete the platform jobs, environments, and project, delete the
`pb_platform_jaffle_shop` repo, and optionally
`drop schema pb_analytics.dbt_platform_prod`. Your Core setup is untouched throughout,
which is the whole point of the separate-repo approach.

Deleting an environment automatically deletes its jobs — move them first if you want to
keep them.

---

## After you're confident

- Move environments from a pinned dbt version to a **release track** so upgrades are
  handled for you.
- Switch the platform schemas to `dbt_core_prod` (or rename), and retire local
  `--target prod` runs. Long-lived hybrid setups are workable as a temporary on-ramp but
  are discouraged as a permanent arrangement.
- If you keep an external orchestrator, swap `dbt-core` execution for a platform job
  triggered through the Administrative API rather than rebuilding your DAG:

  ```
  POST https://{base_url}/api/v2/accounts/{account_id}/jobs/{job_id}/run/
  Authorization: Token {api_key}
  ```

- Enable **partial parsing** and **Git repo caching** in **Account settings**.
- Consider a **Staging** environment if you later want a validation layer between
  development and production.

---

## Reference

- [Move from dbt Core to the dbt platform: Get started](https://docs.getdbt.com/guides/core-migration-1)
- [What you need to know](https://docs.getdbt.com/guides/core-migration-2) · [Optimization tips](https://docs.getdbt.com/guides/core-migration-3)
- [dbt platform configuration checklist](https://docs.getdbt.com/docs/configuration-checklist)
- [Deployment environments](https://docs.getdbt.com/docs/deploy/deploy-environments) · [About profiles](https://docs.getdbt.com/docs/platform/about-profiles)
- [Connect Snowflake](https://docs.getdbt.com/docs/platform/connect-data-platform/connect-snowflake) · [Connect GitHub](https://docs.getdbt.com/docs/platform/git/connect-github)
- [Deploy jobs](https://docs.getdbt.com/docs/deploy/deploy-jobs) · [CI jobs](https://docs.getdbt.com/docs/deploy/ci-jobs) · [Merge jobs](https://docs.getdbt.com/docs/deploy/merge-jobs)
- [Environment variables](https://docs.getdbt.com/docs/build/environment-variables) · [Extended attributes](https://docs.getdbt.com/docs/dbt-platform-environments#extended-attributes)
- [Discover data with Catalog](https://docs.getdbt.com/docs/explore/explore-projects)
