-- 002_indexes.sql
--
-- Target query to optimize:
--
--   SELECT org_id, status, COUNT(*), SUM(amount)
--   FROM hotel_bookings
--   WHERE city = 'delhi'
--     AND created_at >= NOW() - INTERVAL '30 days'
--   GROUP BY org_id, status;
--
-- Without an index, this forces a sequential scan over the entire
-- hotel_bookings table. The composite covering index below lets Postgres:
--   1) seek straight to rows matching city = 'delhi' (leading column, an
--      equality predicate - the most selective place to start),
--   2) range-scan created_at within that city for the trailing 30-day
--      window (a btree naturally supports range predicates on the
--      second column once the first is pinned to a single value), and
--   3) read org_id, status, and amount directly from the index via the
--      INCLUDE clause, so Postgres never has to visit the heap
--      (an index-only scan), as long as the table is reasonably
--      vacuumed/has an up-to-date visibility map.
--
-- See README.md "Query Optimization" section for the full explanation
-- and EXPLAIN ANALYZE before/after comparison.

CREATE INDEX IF NOT EXISTS idx_hotel_bookings_city_created_at
    ON hotel_bookings (city, created_at)
    INCLUDE (org_id, status, amount);
