#!/usr/bin/env bash
#
# Uploads the CSVs in setup/data/ to internal stages and loads them into pb_raw.
# Run after setup/01_create_objects.sql:
#
#   ./setup/02_load_raw_data.sh
#
# Requires the Snowflake CLI (`snow`) with a configured default connection.
# Uses `snow sql` because PUT is a client-side command — it has to run from a
# Snowflake client, not the web UI.

set -euo pipefail

DATA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/data" && pwd)"

run() {
  echo "→ $1"
  snow sql -q "$1"
}

echo "Loading raw data from ${DATA_DIR}"
echo

# --- jaffle_shop.customers -------------------------------------------------
run "put file://${DATA_DIR}/customers.csv @pb_raw.jaffle_shop.load_stage
     auto_compress=true overwrite=true;"

run "copy into pb_raw.jaffle_shop.customers (id, first_name, last_name)
     from (select \$1, \$2, \$3 from @pb_raw.jaffle_shop.load_stage/customers.csv.gz)
     file_format = (format_name = pb_raw.public.csv_with_header)
     on_error = abort_statement;"

# --- jaffle_shop.orders ----------------------------------------------------
run "put file://${DATA_DIR}/orders.csv @pb_raw.jaffle_shop.load_stage
     auto_compress=true overwrite=true;"

run "copy into pb_raw.jaffle_shop.orders (id, user_id, order_date, status)
     from (select \$1, \$2, \$3, \$4 from @pb_raw.jaffle_shop.load_stage/orders.csv.gz)
     file_format = (format_name = pb_raw.public.csv_with_header)
     on_error = abort_statement;"

# --- stripe.payments -------------------------------------------------------
run "put file://${DATA_DIR}/payments.csv @pb_raw.stripe.load_stage
     auto_compress=true overwrite=true;"

run "copy into pb_raw.stripe.payments (id, order_id, payment_method, amount)
     from (select \$1, \$2, \$3, \$4 from @pb_raw.stripe.load_stage/payments.csv.gz)
     file_format = (format_name = pb_raw.public.csv_with_header)
     on_error = abort_statement;"

echo
echo "Row counts:"
snow sql -q "select 'jaffle_shop.customers' as table_name, count(*) as rows from pb_raw.jaffle_shop.customers
             union all select 'jaffle_shop.orders', count(*) from pb_raw.jaffle_shop.orders
             union all select 'stripe.payments',    count(*) from pb_raw.stripe.payments
             order by 1;"

echo
echo "Expected: customers 100, orders 99, payments 113"
