-- 003_seed_data.sql
--
-- Generates 150 hotel_bookings rows spread across 5 cities, 6 orgs and 5
-- statuses, with created_at timestamps spread over the last 60 days so
-- roughly half fall inside the "last 30 days" window used by the target
-- query. Also generates booking_events for ~40% of bookings.

-- Fixed org UUIDs so results are easy to eyeball/reason about. Note: these
-- are picked via array indexing (below), not a correlated subquery -
-- Postgres evaluates an uncorrelated scalar subquery in a target list only
-- ONCE per statement (as an InitPlan), even with a volatile function like
-- random() inside it, which would silently assign every row the same org.

INSERT INTO hotel_bookings (
    id, org_id, hotel_id, city, checkin_date, checkout_date,
    amount, status, created_at
)
SELECT
    gen_random_uuid(),
    (ARRAY[
        '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222',
        '33333333-3333-3333-3333-333333333333',
        '44444444-4444-4444-4444-444444444444',
        '55555555-5555-5555-5555-555555555555',
        '66666666-6666-6666-6666-666666666666'
    ]::uuid[])[floor(random() * 6) + 1],
    'HTL-' || lpad((floor(random() * 40) + 1)::text, 3, '0'),
    (ARRAY['delhi', 'mumbai', 'bangalore', 'pune', 'chennai'])[floor(random() * 5) + 1],
    checkin,
    checkin + ((floor(random() * 5) + 1) || ' days')::interval,
    round((random() * 25000 + 1500)::numeric, 2),
    (ARRAY['confirmed', 'cancelled', 'pending', 'completed', 'refunded'])[floor(random() * 5) + 1],
    created_at
FROM (
    SELECT
        gs AS i,
        (CURRENT_DATE + ((random() * 60)::int || ' days')::interval)::date AS checkin,
        -- Spread creation timestamps across the last 60 days so both the
        -- "last 30 days" window and older, out-of-window rows are covered.
        now() - ((random() * 60)::int || ' days')::interval
                - ((random() * 24)::int || ' hours')::interval AS created_at
    FROM generate_series(1, 150) AS gs
) sub;

-- booking_events for roughly 40% of bookings (1-3 events each), covering a
-- realistic lifecycle: created -> payment_received -> (optionally) cancelled.
INSERT INTO booking_events (booking_id, event_type, payload, created_at)
SELECT
    b.id,
    e.event_type,
    jsonb_build_object('note', e.event_type || ' for booking ' || b.id),
    b.created_at + (e.ord || ' hours')::interval
FROM hotel_bookings b
CROSS JOIN LATERAL (
    SELECT * FROM (VALUES
        (1, 'created'),
        (2, 'payment_received'),
        (3, 'cancelled')
    ) AS v(ord, event_type)
    WHERE v.ord <= CASE WHEN b.status = 'cancelled' THEN 3 ELSE 2 END
) e
WHERE mod(('x' || substr(md5(b.id::text), 1, 8))::bit(32)::int, 10) < 4; -- ~40% of bookings

-- Sanity check output when run manually (harmless during docker-entrypoint init).
-- SELECT count(*) FROM hotel_bookings;
-- SELECT count(*) FROM booking_events;
