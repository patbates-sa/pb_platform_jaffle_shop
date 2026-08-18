-- =========================================================================
-- Stored procedure equivalent of the fct_orders dbt model.
--
--   snow sql -f setup/03_fct_orders_proc.sql
--
-- ONE procedure serves every environment. The target schema is a parameter,
-- not a second copy of the code:
--
--   call pb_analytics.util.build_fct_orders('dbt_core_pbates');   -- dev
--   call pb_analytics.util.build_fct_orders('dbt_core_prod');     -- prod
--
-- Deliberately reads pb_raw directly and inlines the staging renames and the
-- cents-to-dollars recast, so it does NOT depend on dbt having run. That makes
-- it a fair like-for-like comparison against the dbt model rather than a
-- wrapper around dbt's output.
--
-- Verify equivalence with setup/04_compare_fct_orders.sql.
-- =========================================================================

create schema if not exists pb_analytics.util
    comment = 'Utility objects: procedures, helper functions. Not built by dbt.';

create or replace procedure pb_analytics.util.build_fct_orders(target_schema varchar)
returns varchar
language sql
comment = 'Builds <target_schema>.fct_orders from pb_raw. Mirrors the fct_orders dbt model.'
as
$$
declare
    stmt      varchar;
    rows_out  integer;
begin
    -- Reject anything that isn't a plain identifier. The schema name is
    -- concatenated into dynamic SQL below, so this is the injection guard.
    if (not rlike(:target_schema, '^[A-Za-z_][A-Za-z0-9_]*$')) then
        return 'ERROR: invalid schema name: ' || :target_schema;
    end if;

    stmt := '
create or replace table pb_analytics.' || :target_schema || '.fct_orders as

with orders as (

    -- staging: rename only
    select
        id       as order_id,
        user_id  as customer_id,
        order_date,
        status
    from pb_raw.jaffle_shop.orders

),

payments as (

    -- staging: rename, and recast cents to dollars
    select
        id       as payment_id,
        order_id,
        payment_method,
        amount / 100.0 as amount
    from pb_raw.stripe.payments

),

order_payments as (

    select
        order_id,
        sum(case when payment_method = ''credit_card''   then amount else 0 end) as credit_card_amount,
        sum(case when payment_method = ''coupon''        then amount else 0 end) as coupon_amount,
        sum(case when payment_method = ''bank_transfer'' then amount else 0 end) as bank_transfer_amount,
        sum(case when payment_method = ''gift_card''     then amount else 0 end) as gift_card_amount,
        sum(amount) as total_amount
    from payments
    group by 1

)

select
    orders.order_id,
    orders.customer_id,
    orders.order_date,
    orders.status,
    coalesce(order_payments.credit_card_amount, 0)   as credit_card_amount,
    coalesce(order_payments.coupon_amount, 0)        as coupon_amount,
    coalesce(order_payments.bank_transfer_amount, 0) as bank_transfer_amount,
    coalesce(order_payments.gift_card_amount, 0)     as gift_card_amount,
    coalesce(order_payments.total_amount, 0)         as amount
from orders
left join order_payments
    on orders.order_id = order_payments.order_id
';

    execute immediate :stmt;

    -- Row count of the table just built.
    stmt := 'select count(*) from pb_analytics.' || :target_schema || '.fct_orders';
    execute immediate :stmt;
    select $1 into :rows_out from table(result_scan(last_query_id()));

    return 'Built pb_analytics.' || :target_schema || '.fct_orders — '
           || :rows_out || ' rows';
end;
$$;

-- Smoke test against the dev schema.
call pb_analytics.util.build_fct_orders('dbt_core_pbates');
