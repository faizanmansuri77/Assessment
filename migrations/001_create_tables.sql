-- 001_create_tables.sql
-- Core schema for the flight/hotel reservation reliability exercise.

CREATE EXTENSION IF NOT EXISTS "pgcrypto"; -- for gen_random_uuid()

CREATE TABLE IF NOT EXISTS hotel_bookings (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    org_id        UUID NOT NULL,
    hotel_id      VARCHAR(100) NOT NULL,
    city          VARCHAR(100) NOT NULL,
    checkin_date  DATE NOT NULL,
    checkout_date DATE NOT NULL,
    amount        NUMERIC(12, 2) NOT NULL,
    status        VARCHAR(50) NOT NULL,
    created_at    TIMESTAMP NOT NULL DEFAULT now(),
    CONSTRAINT chk_checkout_after_checkin CHECK (checkout_date > checkin_date)
);

CREATE TABLE IF NOT EXISTS booking_events (
    id          BIGSERIAL PRIMARY KEY,
    booking_id  UUID NOT NULL REFERENCES hotel_bookings (id) ON DELETE CASCADE,
    event_type  VARCHAR(100) NOT NULL,
    payload     JSONB,
    created_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- Foreign-key lookups on booking_events benefit from an index on booking_id.
CREATE INDEX IF NOT EXISTS idx_booking_events_booking_id
    ON booking_events (booking_id);
