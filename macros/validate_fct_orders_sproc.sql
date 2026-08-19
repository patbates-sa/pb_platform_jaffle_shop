{% macro validate_fct_orders_sproc() %}

    {% set scratch_schema = 'DBT_SPROC_FCT_ORDERS_COMPARE' %}

    {% do run_query('create schema if not exists pb_analytics.' ~ scratch_schema) %}
    {% do run_query("call pb_analytics.util.build_fct_orders('" ~ scratch_schema ~ "')") %}

    {% set comparison_sql %}
        select
            (select count(*) from {{ ref('fct_orders') }}) as dbt_rows,
            (select count(*) from pb_analytics.{{ scratch_schema }}.fct_orders) as sproc_rows,
            (
                select count(*)
                from (
                    select * from {{ ref('fct_orders') }}
                    minus
                    select * from pb_analytics.{{ scratch_schema }}.fct_orders
                )
            ) as dbt_minus_sproc,
            (
                select count(*)
                from (
                    select * from pb_analytics.{{ scratch_schema }}.fct_orders
                    minus
                    select * from {{ ref('fct_orders') }}
                )
            ) as sproc_minus_dbt
    {% endset %}

    {% set comparison = run_query(comparison_sql) %}

    {% if execute %}
        {% set result = comparison.rows[0] %}
        {{ log(
            'FCT_ORDERS_VALIDATION dbt_rows=' ~ result[0]
            ~ ' sproc_rows=' ~ result[1]
            ~ ' dbt_minus_sproc=' ~ result[2]
            ~ ' sproc_minus_dbt=' ~ result[3],
            info=true
        ) }}
    {% endif %}

    {% do run_query('drop schema if exists pb_analytics.' ~ scratch_schema ~ ' cascade') %}

{% endmacro %}
