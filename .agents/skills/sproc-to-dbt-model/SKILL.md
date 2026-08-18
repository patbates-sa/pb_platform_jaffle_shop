---
name: sproc-to-dbt-model
description: Convert a Snowflake stored procedure into a dbt model in this project. Use whenever the user asks to convert, port, migrate, or rewrite a stored procedure, a proc, or warehouse-side SQL as a dbt model.
---

## When to use

The user names a Snowflake stored procedure and wants it as a dbt model. They will
usually give only the procedure name.

## Workflow

1. **Retrieve the definition.** Procedures are identified by name *and* argument types:

   ```sql
   show procedures like '<PROC_NAME>' in schema <DB>.<SCHEMA>;
   select get_ddl('procedure', '<DB>.<SCHEMA>.<PROC_NAME>(<ARG_TYPES>)');
   ```

   If you cannot execute SQL, ask the user to paste the DDL rather than guessing at
   the logic.

2. **Discard the procedural wrapper.** Only the `SELECT` that produces the output
   table becomes the model. Drop:

   - parameters, variable declarations, input validation
   - `EXECUTE IMMEDIATE` and dynamic SQL string assembly
   - row counts, return values, logging, `BEGIN`/`END`
   - `CREATE OR REPLACE TABLE` — materialization is a dbt config, not SQL

   Un-escape doubled single quotes (`''` → `'`) from any dynamic SQL string.

3. **Map hardcoded relations onto the project.** Before writing anything, list the
   existing models and sources. For each table the procedure reads:

   - if a staging model already covers it → `ref()` that model
   - else if it's declared in a `_*__sources.yml` → `source()`
   - else → add it to the appropriate sources file first

   Never leave a hardcoded `database.schema.table` in a model.

4. **Do not re-implement staging logic.** Column renames, type casts, and unit
   conversions (for example cents → dollars) usually already exist in the `stg_`
   models. Procedures inline them because they have no staging layer. Reference the
   staging model instead of copying the transformation.

5. **Write the model**, then the YAML, then validate.

## Conventions

- Staging: `models/staging/<source>/stg_<source>__<entity>.sql`, materialized as views,
  renames and recasts only — no joins, no business logic.
- Marts: `models/marts/`, materialized as tables, prefixed `fct_` or `dim_`.
- `source()` is called **only** in staging models. Everything downstream uses `ref()`.
  One staging model per source table.
- CTE structure: import CTEs first (one per `ref`/`source`), then logic CTEs, then
  `final`, then `select * from final`.
- Lowercase SQL keywords. Trailing commas. One column per line.
- No hardcoded database or schema names anywhere — that is what the environment's
  target schema is for.
- No `{{ target.name }}` branching. Use environment variables if behavior must differ
  per environment.

## Correctness rules

These are the failure modes that produce a model which runs but returns wrong data.
Check each one explicitly:

- **Grain and fan-out.** If the procedure aggregates a child table before joining
  (payments per order, line items per invoice), preserve that ordering. Joining the
  finer-grained table directly multiplies rows and silently inflates every count and
  sum downstream.
- **Null handling on outer joins.** Preserve `coalesce(..., 0)` and equivalent
  defaults. Dropping them turns "no rows in the child table" into nulls, which then
  propagate.
- **Filters.** Carry over every `where` clause, including ones that look incidental.
  A missing status filter changes totals.
- **Window functions.** Preserve `partition by` / `order by` exactly. Reordering
  changes results even when the query still compiles.
- **Column order and names.** Match the procedure's output so the result can be
  diffed against the original table.

## Then add YAML

In the schema YAML alongside the model:

- A model `description`, and a `description` for every column.
- `unique` + `not_null` on the primary key.
- `relationships` on each foreign key.
- `accepted_values` on any low-cardinality status or category column.

Nest test arguments under `arguments:` — top-level test kwargs are deprecated:

```yaml
data_tests:
  - accepted_values:
      arguments:
        values: ['placed', 'shipped']
  - relationships:
      arguments:
        to: ref('dim_customers')
        field: customer_id
```

## Validate before reporting done

1. `dbt build --select <new_model>` — it must compile, build, and pass tests.
2. Diff against the procedure's own output. Run the procedure into a scratch schema,
   then check the symmetric difference in **both** directions — `MINUS` is
   one-directional, so a single check misses extra rows:

   ```sql
   select count(*) from (
       select * from <dbt_schema>.<model> minus select * from <scratch>.<table>
   );
   select count(*) from (
       select * from <scratch>.<table> minus select * from <dbt_schema>.<model>
   );
   ```

   Both must be zero. Report the row counts and both difference counts.

3. If they differ, do not silently "fix" the model to match. Explain which logic
   diverged and why — the procedure may itself contain a bug worth preserving or
   worth fixing deliberately.

## Report

State: the model path, which tables became `ref()` vs `source()`, any staging logic
you deliberately did not re-implement, the validation results, and anything in the
procedure you could not translate faithfully.
