with source as (

    select * from {{ source('stripe', 'payments') }}

),

renamed as (

    select
        id           as payment_id,
        order_id,
        payment_method,

        -- Stripe reports amounts in cents; recast to dollars here so every
        -- downstream model works in a single unit.
        amount / 100.0 as amount

    from source

)

select * from renamed
