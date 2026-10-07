-- Four writes the DATABASE refuses, with no application code involved.
--   psql "$DATABASE_URL" -f sql/04_invalid_inserts.sql     (no ON_ERROR_STOP: the errors are the point)
-- Each attempt is its own transaction, so nothing is left behind.
\pset pager off
\set VERBOSITY default

-- Fixture, inside a transaction that is rolled back at the end: one rider with a
-- trip in progress. Each refused write sits between a SAVEPOINT and a ROLLBACK TO.
BEGIN;
SELECT u.id AS busy_rider FROM users u
WHERE NOT EXISTS (SELECT 1 FROM trips t WHERE t.rider_id = u.id AND t.status IN ('requested','accepted','driver_arrived','in_progress'))
ORDER BY u.phone LIMIT 1 \gset
SELECT d.id AS driver_id, v.id AS vehicle_id FROM drivers d JOIN vehicles v ON v.driver_id = d.id AND v.is_active
WHERE d.is_online AND NOT EXISTS (SELECT 1 FROM trips t WHERE t.driver_id = d.id AND t.status IN ('accepted','driver_arrived','in_progress'))
ORDER BY d.licence_number LIMIT 1 \gset
INSERT INTO trips (rider_id, pickup_lat, pickup_lng, pickup_address, dropoff_lat, dropoff_lng, dropoff_address,
                   base_fare_minor, per_km_minor, per_minute_minor, surge_bp, estimated_fare_minor)
VALUES (:'busy_rider', 6.4281, 3.4219, '12 Awolowo Road, Ikoyi', 6.6018, 3.3515, '45 Allen Avenue, Ikeja', 50000, 15000, 2500, 10000, 370000)
RETURNING id AS in_progress_trip \gset
UPDATE trips SET status = 'accepted', driver_id = :'driver_id', vehicle_id = :'vehicle_id', accepted_at = now(),
       driver_name_snapshot = 'Fixture Driver', vehicle_snapshot = 'Fixture vehicle' WHERE id = :'in_progress_trip';
UPDATE trips SET status = 'driver_arrived', arrived_at = now() WHERE id = :'in_progress_trip';
UPDATE trips SET status = 'in_progress', started_at = now() WHERE id = :'in_progress_trip';
SELECT id AS requested_trip FROM trips WHERE status = 'requested' AND id <> :'in_progress_trip' ORDER BY id LIMIT 1 \gset
SELECT t.id AS paid_trip FROM payments p JOIN trips t ON t.id = p.trip_id WHERE p.status = 'succeeded' ORDER BY t.id LIMIT 1 \gset
\echo 'Fixture: this rider has one trip, in progress:'
SELECT id, status FROM trips WHERE id = :'in_progress_trip';

\echo
\echo '=== 1. A second active trip for a rider who already has one in progress ==='
SAVEPOINT attempt;
INSERT INTO trips (rider_id, pickup_lat, pickup_lng, pickup_address, dropoff_lat, dropoff_lng, dropoff_address,
                   base_fare_minor, per_km_minor, per_minute_minor, surge_bp, estimated_fare_minor)
VALUES (:'busy_rider', 6.45, 3.39, '1 Marina Road', 6.60, 3.35, '2 Allen Avenue', 50000, 15000, 2500, 10000, 200000);
ROLLBACK TO attempt;

\echo
\echo '=== 2. Cancelling a trip that is already in progress (forbidden transition) ==='
SAVEPOINT attempt;
UPDATE trips SET status = 'cancelled', cancelled_at = now(), cancelled_by = 'rider' WHERE id = :'in_progress_trip';
ROLLBACK TO attempt;

\echo
\echo '=== 3. A review on a trip that was never completed ==='
SAVEPOINT attempt;
INSERT INTO reviews (trip_id, author, rating, comment) VALUES (:'requested_trip', 'rider', 5, 'Great ride');
ROLLBACK TO attempt;

\echo
\echo '=== 4. A second successful payment for a trip that is already paid ==='
SAVEPOINT attempt;
INSERT INTO payments (trip_id, amount_minor, currency, provider_reference, status)
VALUES (:'paid_trip', 100000, 'NGN', 'pay-duplicate-attempt', 'succeeded');
ROLLBACK TO attempt;

\echo
\echo '=== Nothing was written ==='
SELECT (SELECT count(*) FROM trips WHERE rider_id = :'busy_rider' AND status IN ('requested','accepted','driver_arrived','in_progress')) AS active_trips_for_rider,
       (SELECT status FROM trips WHERE id = :'in_progress_trip') AS trip_status,
       (SELECT count(*) FROM reviews WHERE trip_id = :'requested_trip') AS reviews_on_requested_trip,
       (SELECT count(*) FROM payments WHERE trip_id = :'paid_trip' AND status = 'succeeded') AS successful_payments;
ROLLBACK;
