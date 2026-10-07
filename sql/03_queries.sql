-- The five important actions as SQL, run end to end for one real trip, and the
-- query plans for the two heaviest.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/03_queries.sql
-- Everything runs in one transaction that is rolled back, so it can be run again.

\pset pager off
BEGIN;

-- Pick a rider with no trip under way, and an online driver with none.
SELECT u.id AS rider_id FROM users u
WHERE NOT EXISTS (SELECT 1 FROM trips t WHERE t.rider_id = u.id AND t.status IN ('requested','accepted','driver_arrived','in_progress'))
ORDER BY u.phone LIMIT 1 \gset
SELECT d.id AS driver_id FROM drivers d
WHERE d.is_online AND NOT EXISTS (SELECT 1 FROM trips t WHERE t.driver_id = d.id AND t.status IN ('accepted','driver_arrived','in_progress'))
ORDER BY d.licence_number LIMIT 1 \gset

\echo
\echo '=== ACTION 1: a rider requests a trip ==='
INSERT INTO trips (rider_id, pickup_lat, pickup_lng, pickup_address, dropoff_lat, dropoff_lng, dropoff_address,
                   base_fare_minor, per_km_minor, per_minute_minor, surge_bp, estimated_fare_minor)
VALUES (:'rider_id', 6.4281, 3.4219, '12 Awolowo Road, Ikoyi', 6.6018, 3.3515, '45 Allen Avenue, Ikeja', 50000, 15000, 2500, 12500, 462500)
RETURNING id AS trip_id, status, estimated_fare_minor, currency \gset
SELECT :'trip_id' AS trip_id, :'status' AS status, :estimated_fare_minor AS estimated_fare_minor;
-- Dispatch offers it to drivers (here, the one we picked).
INSERT INTO trip_offers (trip_id, driver_id, expires_at) VALUES (:'trip_id', :'driver_id', now() + interval '30 seconds');

\echo
\echo '=== ACTION 2: the driver looks at their open offers, and accepts one ==='
SELECT o.trip_id, t.pickup_address, t.dropoff_address, t.estimated_fare_minor, t.currency, o.expires_at
FROM trip_offers o JOIN trips t ON t.id = o.trip_id
WHERE o.driver_id = :'driver_id' AND o.status = 'offered' AND o.expires_at > now()
ORDER BY o.offered_at DESC LIMIT 20;

-- Accept: the offer first (only one 'accepted' per trip can exist), then the trip.
UPDATE trip_offers SET status = 'accepted', responded_at = now()
WHERE trip_id = :'trip_id' AND driver_id = :'driver_id' AND status = 'offered' AND expires_at > now();
UPDATE trips t SET status = 'accepted', driver_id = d.id, vehicle_id = v.id, accepted_at = now(),
       driver_name_snapshot = u.full_name, vehicle_snapshot = v.make || ' ' || v.model || ', ' || v.colour || ', ' || v.plate_number
FROM drivers d JOIN users u ON u.id = d.user_id JOIN vehicles v ON v.driver_id = d.id AND v.is_active
WHERE t.id = :'trip_id' AND t.status = 'requested' AND d.id = :'driver_id'
RETURNING t.status, t.driver_name_snapshot, t.vehicle_snapshot;

\echo
\echo '=== ACTION 3: the driver arrives, starts, and completes the trip (the fare is fixed here) ==='
UPDATE trips SET status = 'driver_arrived', arrived_at = now() WHERE id = :'trip_id' AND status = 'accepted';
UPDATE trips SET status = 'in_progress', started_at = now() WHERE id = :'trip_id' AND status = 'driver_arrived';
-- 21,400 m in 2,340 s. Fare from the tariff stored ON THE TRIP, in integer kobo.
UPDATE trips SET status = 'completed', completed_at = now() + interval '39 minutes', distance_m = 21400, duration_s = 2340,
       final_fare_minor = ((base_fare_minor + 21400::bigint * per_km_minor / 1000 + 2340::bigint * per_minute_minor / 60) * surge_bp / 10000)::int
WHERE id = :'trip_id' AND status = 'in_progress'
RETURNING status, distance_m, duration_s, base_fare_minor, per_km_minor, per_minute_minor, surge_bp, final_fare_minor, currency;

\echo 'The status history the trigger recorded:'
SELECT from_status, to_status FROM trip_events WHERE trip_id = :'trip_id' ORDER BY id;

\echo
\echo '=== ACTION 4: the rider pays ==='
INSERT INTO payments (trip_id, amount_minor, currency, provider_reference)
SELECT id, final_fare_minor, currency, 'pay-' || replace(id::text, '-', '') || '-1' FROM trips WHERE id = :'trip_id'
RETURNING id AS payment_id, amount_minor, currency, status \gset
UPDATE payments SET status = 'succeeded' WHERE id = :'payment_id' AND status = 'pending' RETURNING status, amount_minor, currency;

\echo
\echo '=== ACTION 5: the rider views their trip history (first page) ==='
SELECT t.id, t.requested_at::timestamp(0), t.status, t.dropoff_address, t.final_fare_minor, t.currency, t.driver_name_snapshot
FROM trips t WHERE t.rider_id = :'rider_id'
ORDER BY t.requested_at DESC, t.id DESC LIMIT 5;

\echo
\echo '=== QUERY PLAN, heaviest query 1: rider trip history (30,021 trips in the table) ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT t.id, t.requested_at, t.status, t.dropoff_address, t.final_fare_minor, t.currency, t.driver_name_snapshot
FROM trips t WHERE t.rider_id = :'rider_id'
ORDER BY t.requested_at DESC, t.id DESC LIMIT 20;

\echo
\echo '=== QUERY PLAN, heaviest query 2: a driver''s open offers with trip details (9,023 offers in the table) ==='
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT o.trip_id, t.pickup_address, t.dropoff_address, t.estimated_fare_minor, t.currency, o.expires_at
FROM trip_offers o JOIN trips t ON t.id = o.trip_id
WHERE o.driver_id = (SELECT driver_id FROM trip_offers WHERE status = 'offered' LIMIT 1) AND o.status = 'offered' AND o.expires_at > now()
ORDER BY o.offered_at DESC LIMIT 20;

\echo
\echo '=== For comparison: the same history query with its index removed ==='
DROP INDEX idx_trips_rider_requested_at;
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT t.id, t.requested_at, t.status, t.dropoff_address, t.final_fare_minor, t.currency, t.driver_name_snapshot
FROM trips t WHERE t.rider_id = :'rider_id'
ORDER BY t.requested_at DESC, t.id DESC LIMIT 20;

ROLLBACK;
