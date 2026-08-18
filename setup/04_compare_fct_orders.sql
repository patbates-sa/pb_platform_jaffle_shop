-- =========================================================================
-- Proves the stored procedure and the dbt model produce identical output.
--
-- Run order:
--   1. dbt build --target dev                              (builds the model)
--   2. call pb_analytics.util.build_fct_orders('SPROC_OUT') (builds the proc's table)
--   3. snow sql -f setup/04_compare_fct_orders.sql
--
-- The procedure writes to its own schema here so it doesn't overwrite the
-- table dbt just built — otherwise there'd be nothing left to compare.
-- =========================================================================

create schema if not exists pb_analytics.sproc_out
    comment = 'Output of the stored-procedure build, kept separate for comparison.';

call pb_analytics.util.build_fct_orders('SPROC_OUT');

-- --- 1. Row counts must match -------------------------------------------
select
    (select count(*) from pb_analytics.dbt_core_pbates.fct_orders) as dbt_rows,
    (select count(*) from pb_analytics.sproc_out.fct_orders)       as sproc_rows,
    iff(
        (select count(*) from pb_analytics.dbt_core_pbates.fct_orders)
        = (select count(*) from pb_analytics.sproc_out.fct_orders),
        'PASS', 'FAIL'
    ) as result;

-- --- 2. Symmetric difference must be empty ------------------------------
-- MINUS is one-directional, so check both ways. Any row appearing in one
-- table but not the other shows up here.
with dbt_only as (
    select * from pb_analytics.dbt_core_pbates.fct_orders
    minus
    select * from pb_analytics.sproc_out.fct_orders
),
sproc_only as (
    select * from pb_analytics.sproc_out.fct_orders
    minus
    select * from pb_analytics.dbt_core_pbates.fct_orders
)
select
    (select count(*) from dbt_only)   as in_dbt_not_sproc,
    (select count(*) from sproc_only) as in_sproc_not_dbt,
    iff(
        (select count(*) from dbt_only) = 0
        and (select count(*) from sproc_only) = 0,
        'PASS — outputs are identical', 'FAIL — see rows below'
    ) as result;

-- --- 3. If it failed, show the offending rows ---------------------------
select 'dbt only' as side, * from (
    select * from pb_analytics.dbt_core_pbates.fct_orders
    minus
    select * from pb_analytics.sproc_out.fct_orders
)
union all
select 'sproc only' as side, * from (
    select * from pb_analytics.sproc_out.fct_orders
    minus
    select * from pb_analytics.dbt_core_pbates.fct_orders
)
order by side, order_id;

-- --- 4. Internal consistency: the pivot columns must sum to amount ------
select count(*) as rows_where_pivot_does_not_reconcile
from pb_analytics.sproc_out.fct_orders
where abs(
    (credit_card_amount + coupon_amount + bank_transfer_amount + gift_card_amount)
    - amount
) > 0.001;
