with orders as (

    select * from {{ ref('stg_jaffle_shop__orders') }}

),

payments as (

    select * from {{ ref('stg_stripe__payments') }}

),

-- One row per order, with payments pivoted out by method. Payments are at a
-- finer grain than orders, so collapse them here before joining.
order_payments as (

    select
        order_id,

        sum(case when payment_method = 'credit_card'   then amount else 0 end) as credit_card_amount,
        sum(case when payment_method = 'coupon'        then amount else 0 end) as coupon_amount,
        sum(case when payment_method = 'bank_transfer' then amount else 0 end) as bank_transfer_amount,
        sum(case when payment_method = 'gift_card'     then amount else 0 end) as gift_card_amount,

        sum(amount) as total_amount

    from payments
    group by 1

),

final as (

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

)

select * from final
