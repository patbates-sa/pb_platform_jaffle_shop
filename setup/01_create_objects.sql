-- Creates the raw landing zone and the analytics target for this project.
-- Run once, with a role that can create databases (e.g. SYSADMIN):
--   snow sql -f setup/01_create_objects.sql

-- ---------------------------------------------------------------------------
-- Databases and schemas
-- ---------------------------------------------------------------------------
create database if not exists pb_raw
    comment = 'Landing zone for raw, source-conformed data. dbt reads, never writes.';

create schema if not exists pb_raw.jaffle_shop
    comment = 'Replica of the Jaffle Shop application Postgres database.';

create schema if not exists pb_raw.stripe
    comment = 'Payment records synced from the Stripe API.';

create database if not exists pb_analytics
    comment = 'Transformed data built by dbt.';

create schema if not exists pb_analytics.dbt_core_pbates
    comment = 'Personal development schema for pat.bates.';

create schema if not exists pb_analytics.dbt_core_prod
    comment = 'Production schema, built by scheduled dbt runs only.';

-- ---------------------------------------------------------------------------
-- Raw tables
--
-- Column names and types intentionally mirror the source systems, warts and
-- all: `id` rather than `customer_id`, amounts in cents. Renaming and recasting
-- is the staging layer's job, not the loader's.
--
-- _etl_loaded_at stands in for the load timestamp an EL tool would provide,
-- and is what `dbt source freshness` reads.
-- ---------------------------------------------------------------------------
create or replace table pb_raw.jaffle_shop.customers (
    id              integer      not null,
    first_name      varchar(50),
    last_name       varchar(50),
    _etl_loaded_at  timestamp_ntz default current_timestamp()
);

create or replace table pb_raw.jaffle_shop.orders (
    id              integer      not null,
    user_id         integer      not null,
    order_date      date         not null,
    status          varchar(20)  not null,
    _etl_loaded_at  timestamp_ntz default current_timestamp()
);

create or replace table pb_raw.stripe.payments (
    id              integer      not null,
    order_id        integer      not null,
    payment_method  varchar(20)  not null,
    amount          integer      not null,   -- in CENTS, as Stripe reports it
    _etl_loaded_at  timestamp_ntz default current_timestamp()
);

-- ---------------------------------------------------------------------------
-- File format and stages used by the load script
-- ---------------------------------------------------------------------------
create or replace file format pb_raw.public.csv_with_header
    type = csv
    field_delimiter = ','
    skip_header = 1
    field_optionally_enclosed_by = '"'
    empty_field_as_null = true;

create stage if not exists pb_raw.jaffle_shop.load_stage
    file_format = pb_raw.public.csv_with_header;

create stage if not exists pb_raw.stripe.load_stage
    file_format = pb_raw.public.csv_with_header;
