# pb_core_jaffle_shop

A minimal dbt Core project based on the Jaffle Shop training module, built out through
`dim_customers`. Raw data is declared as **sources** in a separate Snowflake database,
following the convention that dbt reads from the landing zone and never writes to it.

## Environments

|  | Reads from | Writes to |
|---|---|---|
| **dev** | `pb_raw` | `pb_analytics.dbt_core_pbates` |
| **prod** | `pb_raw` | `pb_analytics.dbt_core_prod` |

Raw source location is set per-source in the `_*__sources.yml` files, *not* in
`profiles.yml` — so it's identical across environments and lives in version control.

## Lineage

```
pb_raw.jaffle_shop.customers ──► stg_jaffle_shop__customers ──┐
pb_raw.jaffle_shop.orders    ──► stg_jaffle_shop__orders    ──┼──► dim_customers
pb_raw.stripe.payments       ──► stg_stripe__payments       ──┘
```

Two source systems, deliberately: orders and customers come from the application
database, payments come from Stripe. That's what the `stg_<source>__<entity>` naming
is communicating.

## Setup

1. **Install dbt with the Snowflake adapter:**

   ```bash
   python3 -m venv ~/envs/dbt
   source ~/envs/dbt/bin/activate
   pip install dbt-snowflake
   ```

2. **Create the databases, schemas, and raw tables** (needs a role that can create
   databases, e.g. `SYSADMIN`):

   ```bash
   snow sql -f setup/01_create_objects.sql
   ```

3. **Load the raw data:**

   ```bash
   ./setup/02_load_raw_data.sh
   ```

   This stages the CSVs in `setup/data/` and `COPY INTO`s them. Expect 100 customers,
   99 orders, 113 payments.

4. **Configure your dbt connection.** Copy the template and fill it in:

   ```bash
   cp profiles.yml.example profiles.yml     # gitignored; stays local
   export DBT_SNOWFLAKE_ACCOUNT=abc12345.us-east-1
   export DBT_SNOWFLAKE_USER=pat.bates@dbtlabs.com
   export DBT_ENV_SECRET_SNOWFLAKE_PASSWORD='...'
   dbt debug
   ```

   > **Only define this profile in one file.** dbt resolves profiles by
   > precedence — `--profiles-dir`, then `DBT_PROFILES_DIR`, then `~/.dbt/` — and
   > if `pb_core_jaffle_shop` is defined in more than one place, the winner is
   > used silently with no warning. The symptom is confusing: edits appear to do
   > nothing, and `--target prod` quietly builds into the dev schema. If that
   > happens, `dbt debug --target prod` shows which schema actually resolved.

## Run it

```bash
dbt deps                  # installs dbt_utils
dbt build                 # runs models and tests in dependency order
```

Because raw data is now loaded outside dbt, there's no `dbt seed` step.

Check that the landed data is current before building on it:

```bash
dbt source freshness
```

Useful selectors that sources unlock:

```bash
dbt test --select "source:*"              # test raw data only
dbt run  --select source:stripe+          # everything downstream of Stripe
dbt build --select source_status:fresher+ # only what has new data
```

## Production build

`--target prod` switches the output to `pb_analytics.dbt_core_prod`. Nothing else
changes — same sources, same refs, same tests.

```bash
dbt deps
dbt source freshness --target prod        # don't build on stale data
dbt build --target prod
```

Confirm where you're pointed *before* building — the `schema:` line should read
`dbt_core_prod`:

```bash
dbt debug --target prod
```

Notes:

- `--target` goes **after** the subcommand. `dbt --target prod build` is not the same
  thing.
- Use `dbt build`, not `dbt run && dbt test`. `build` interleaves models and tests in
  DAG order, so a failing test stops its downstream children instead of letting bad
  data propagate.
- If a node reports `Reused ... (No new changes on any upstreams)` and you want to
  force it, add `--full-refresh`.
- Running `--target prod` from a laptop is fine for verifying the prod path works, but
  it isn't production. Real runs belong in a scheduler with a service account and key
  pair auth — browser SSO can't run unattended, and a password in a scheduled job is
  worse.

## Inspect the result

```bash
dbt show --select dim_customers --limit 10
```

## Documentation

This project runs on the dbt Fusion engine, where `dbt docs generate` is replaced by
build flags:

```bash
dbt build --write-catalog --write-index --static-analysis strict
dbt login                 # required for column lineage to display
dbt docs serve            # http://localhost:8580
```

What each flag does — they're easy to conflate:

| Flag | Produces | Needed for |
|---|---|---|
| `--write-index` | Parquet index in `target/index/` | `dbt docs serve` — without it, serve has nothing to read |
| `--write-catalog` | `catalog.json` | Catalog and the metadata APIs. Does **not** build the docs site |
| `--static-analysis strict` | column types + lineage from the warehouse | column-level lineage |

Both write flags work on `build`, `run`, `parse`, and `compile`, so one pass is enough.
Use `build` rather than `compile` — `catalog.json` describes the relations your models
actually produced, so on a project that has never been built the catalog comes back
empty.

While `dbt docs serve` is running, a REST API is exposed at `/api/v1/`, including
`/api/v1/nodes/:id/column-lineage`. It's designed to be queried by coding agents and
MCP servers without a browser.

## What's in the data

| Table | Rows | Notes |
|---|---|---|
| `pb_raw.jaffle_shop.customers` | 100 | 49 have never placed an order |
| `pb_raw.jaffle_shop.orders` | 99 | Jan–Sep 2018, 51 distinct customers |
| `pb_raw.stripe.payments` | 113 | 14 orders have two payments; amounts in **cents** |

Three details in the data are what the model logic exists to handle:

- **Amounts are in cents.** `stg_stripe__payments` divides by 100 — recasting belongs
  in staging so nothing downstream has to remember the unit.
- **Orders can have multiple payments**, so payments are summed per order *before*
  joining to orders. Joining directly would fan out the rows and inflate
  `number_of_orders`.
- **`returned` orders have zeroed payment amounts**, so they count toward
  `number_of_orders` but not `lifetime_value`.

## Layout

```
dbt_project.yml
packages.yml
profiles.yml.example
setup/
  01_create_objects.sql        DDL for pb_raw + pb_analytics
  02_load_raw_data.sh          PUT + COPY INTO
  data/                        CSVs — load input, NOT dbt seeds
models/
  staging/
    jaffle_shop/
      _jaffle_shop__sources.yml    source definitions + freshness + tests
      _jaffle_shop__models.yml
      stg_jaffle_shop__customers.sql
      stg_jaffle_shop__orders.sql
    stripe/
      _stripe__sources.yml
      _stripe__models.yml
      stg_stripe__payments.sql
  marts/
    _marts__models.yml
    dim_customers.sql
```

## Conventions this project follows

- **Staging is the only layer that calls `source()`.** Everything downstream uses
  `ref()`. One staging model per source table, no exceptions — so when a third party
  renames a column, exactly one file changes.
- **No direct relation references** (`pb_raw.jaffle_shop.orders`) anywhere in a model.
- **Staging renames and recasts only** — no joins, no business logic. Source-conformed
  in, project-conformed out.
- **Sources, not seeds, for raw data.** Seeds are for small static business-owned
  data (country codes, employee IDs), not for data an EL pipeline lands.

## Where to take it next

- Add `fct_orders` — orders joined to payment totals, pivoted by payment method.
- Add a singular test in `tests/` asserting no customer has negative lifetime value.
- Add a snapshot on `orders`, since `status` changes in place and history is otherwise
  lost.
- Tighten the freshness thresholds once you know the real load cadence.
