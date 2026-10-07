-- Seed data. Run after 01_schema.sql on an empty schema:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/02_seed.sql
-- 2,000 users (300 of them drivers), 30,000 past trips with payments and
-- reviews, and a handful of live trips and open offers.

SELECT setseed(0.42);

INSERT INTO users (phone, full_name, email, created_at)
SELECT '+23480' || lpad(g::text, 8, '0'),
       (ARRAY['Adaeze','Tunde','Ngozi','Emeka','Fatima','Chidi','Aisha','Bola','Kemi','Ibrahim','Zainab','Segun','Amara','Yusuf','Folake','Obinna'])[1 + (g % 16)]
         || ' ' || (ARRAY['Okafor','Adeyemi','Bello','Eze','Balogun','Nwosu','Abubakar','Ojo','Okonkwo','Lawal','Uche','Danjuma'])[1 + ((g / 16) % 12)],
       'user' || g || '@example.com',
       now() - (random() * interval '700 days') - interval '30 days'
FROM generate_series(1, 2000) g;

-- The first 300 users are also drivers.
INSERT INTO drivers (user_id, licence_number, status, is_online, created_at)
SELECT id, 'LIC-' || lpad(n::text, 6, '0'), 'active', n <= 80, created_at + interval '1 day'
FROM (SELECT id, created_at, row_number() OVER (ORDER BY phone) AS n FROM users) u
WHERE n <= 300;

INSERT INTO vehicles (driver_id, plate_number, make, model, colour, year, is_active)
SELECT d.id,
       (ARRAY['LAG','ABJ','KAN','PHC'])[1 + (n % 4)] || '-' || lpad(n::text, 3, '0') || '-' || chr((65 + n % 26)::int) || chr((65 + (n / 26) % 26)::int),
       (ARRAY['Toyota','Honda','Hyundai','Kia'])[1 + (n % 4)],
       (ARRAY['Corolla','Civic','Elantra','Rio'])[1 + (n % 4)],
       (ARRAY['silver','black','white','blue','grey'])[1 + (n % 5)],
       2012 + (n % 12), true
FROM (SELECT id, row_number() OVER (ORDER BY licence_number) AS n FROM drivers) d;

-- ---------------------------------------------------------------- history
-- Past trips are loaded already finished, so the "a trip is born requested"
-- trigger is switched off for this one statement and back on straight after.
-- Every other constraint stays on and applies to these rows.
ALTER TABLE trips DISABLE TRIGGER trg_trips_initial_status;

WITH riders AS (SELECT id, row_number() OVER (ORDER BY phone) AS n FROM users),
     drv AS (SELECT d.id, u.full_name, v.id AS vehicle_id, v.make || ' ' || v.model || ', ' || v.colour || ', ' || v.plate_number AS vehicle,
                    row_number() OVER (ORDER BY d.licence_number) AS n
             FROM drivers d JOIN users u ON u.id = d.user_id JOIN vehicles v ON v.driver_id = d.id),
     raw AS (
       SELECT g,
              1 + floor(random() * 2000)::int AS rider_n,
              1 + floor(random() * 300)::int AS driver_n,
              now() - interval '2 hours' - (random() * interval '365 days') AS requested_at,
              1500 + floor(random() * 23500)::int AS distance_m,
              (ARRAY[10000,10000,10000,10000,12500,15000,20000])[1 + floor(random() * 7)::int] AS surge_bp,
              random() < 0.10 AS is_cancelled,
              6.40 + random() * 0.25 AS lat, 3.30 + random() * 0.30 AS lng
       FROM generate_series(1, 30000) g
     ),
     priced AS (
       SELECT raw.*, (distance_m / 1000.0 * 150 + 120)::int AS duration_s,       -- about 24 km/h plus pickup time
              50000 AS base, 15000 AS per_km, 2500 AS per_min
       FROM raw
     )
INSERT INTO trips (rider_id, driver_id, vehicle_id, status, pickup_lat, pickup_lng, pickup_address, dropoff_lat, dropoff_lng, dropoff_address,
                   base_fare_minor, per_km_minor, per_minute_minor, surge_bp, estimated_fare_minor, distance_m, duration_s, final_fare_minor,
                   driver_name_snapshot, vehicle_snapshot, requested_at, accepted_at, arrived_at, started_at, completed_at,
                   cancelled_at, cancelled_by, cancellation_reason, created_at)
SELECT r.id,
       CASE WHEN p.is_cancelled THEN NULL ELSE d.id END,
       CASE WHEN p.is_cancelled THEN NULL ELSE d.vehicle_id END,
       CASE WHEN p.is_cancelled THEN 'cancelled' ELSE 'completed' END::trip_status,
       p.lat, p.lng, (1 + p.g % 180) || ' ' || (ARRAY['Awolowo Road','Admiralty Way','Allen Avenue','Herbert Macaulay Way','Adeola Odeku Street'])[1 + p.g % 5],
       p.lat + 0.05, p.lng + 0.04, (1 + p.g % 90) || ' ' || (ARRAY['Bourdillon Road','Ozumba Mbadiwe Avenue','Opebi Road','Ikorodu Road','Akin Adesola Street'])[1 + p.g % 5],
       p.base, p.per_km, p.per_min, p.surge_bp,
       -- integer arithmetic throughout: metres * kobo-per-km / 1000, seconds * kobo-per-minute / 60, then surge in basis points
       ((p.base + p.distance_m::bigint * p.per_km / 1000 + p.duration_s::bigint * p.per_min / 60) * p.surge_bp / 10000)::int,
       CASE WHEN p.is_cancelled THEN NULL ELSE p.distance_m END,
       CASE WHEN p.is_cancelled THEN NULL ELSE p.duration_s END,
       CASE WHEN p.is_cancelled THEN NULL ELSE ((p.base + p.distance_m::bigint * p.per_km / 1000 + p.duration_s::bigint * p.per_min / 60) * p.surge_bp / 10000)::int END,
       CASE WHEN p.is_cancelled THEN NULL ELSE d.full_name END,
       CASE WHEN p.is_cancelled THEN NULL ELSE d.vehicle END,
       p.requested_at,
       CASE WHEN p.is_cancelled THEN NULL ELSE p.requested_at + interval '40 seconds' END,
       CASE WHEN p.is_cancelled THEN NULL ELSE p.requested_at + interval '6 minutes' END,
       CASE WHEN p.is_cancelled THEN NULL ELSE p.requested_at + interval '8 minutes' END,
       CASE WHEN p.is_cancelled THEN NULL ELSE p.requested_at + interval '8 minutes' + p.duration_s * interval '1 second' END,
       CASE WHEN p.is_cancelled THEN p.requested_at + interval '90 seconds' END,
       CASE WHEN p.is_cancelled THEN 'rider'::party END,
       CASE WHEN p.is_cancelled THEN 'Changed my mind' END,
       p.requested_at
FROM priced p JOIN riders r ON r.n = p.rider_n JOIN drv d ON d.n = p.driver_n;

ALTER TABLE trips ENABLE TRIGGER trg_trips_initial_status;

-- One successful payment per completed trip; about 1 in 20 had a failed attempt first.
INSERT INTO payments (trip_id, amount_minor, currency, status, provider_reference, failure_reason, created_at)
SELECT id, final_fare_minor, currency, 'failed', 'pay-' || replace(id::text, '-', '') || '-1', 'Insufficient funds', completed_at + interval '5 seconds'
FROM trips WHERE status = 'completed' AND random() < 0.05;
INSERT INTO payments (trip_id, amount_minor, currency, status, provider_reference, created_at)
SELECT id, final_fare_minor, currency, 'succeeded', 'pay-' || replace(id::text, '-', '') || '-2', completed_at + interval '20 seconds'
FROM trips WHERE status = 'completed';

-- About 60% of riders rate the driver; the trigger keeps each driver's totals.
INSERT INTO reviews (trip_id, author, rating, comment, created_at)
SELECT id, 'rider', (ARRAY[5,5,5,5,4,4,4,3,2,1])[1 + floor(random() * 10)::int],
       CASE WHEN random() < 0.3 THEN (ARRAY['Smooth ride','Very polite','Clean car','Took a longer route','Arrived quickly'])[1 + floor(random() * 5)::int] END,
       completed_at + interval '3 minutes'
FROM trips WHERE status = 'completed' AND random() < 0.60;

-- Offer history for the 3,000 most recent completed trips: the driver who took it, and two who did not.
WITH recent AS (SELECT id, driver_id, requested_at FROM trips WHERE status = 'completed' ORDER BY requested_at DESC LIMIT 3000),
     others AS (SELECT id, row_number() OVER (ORDER BY licence_number) AS n FROM drivers)
INSERT INTO trip_offers (trip_id, driver_id, status, offered_at, expires_at, responded_at)
SELECT id, driver_id, 'accepted', requested_at + interval '5 seconds', requested_at + interval '35 seconds', requested_at + interval '40 seconds' FROM recent
UNION ALL
SELECT r.id, o.id, CASE WHEN k = 1 THEN 'declined' ELSE 'expired' END::offer_status, r.requested_at + interval '5 seconds', r.requested_at + interval '35 seconds',
       CASE WHEN k = 1 THEN r.requested_at + interval '12 seconds' END
FROM recent r CROSS JOIN generate_series(1, 2) k
JOIN others o ON o.n = 1 + (abs(hashtext(r.id::text || k::text)) % 300)
WHERE o.id <> r.driver_id
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------- live
-- Twenty riders are waiting for a driver right now, each offered to three online drivers.
WITH riders AS (SELECT id, row_number() OVER (ORDER BY phone DESC) AS n FROM users),
     new_trips AS (
       INSERT INTO trips (rider_id, pickup_lat, pickup_lng, pickup_address, dropoff_lat, dropoff_lng, dropoff_address,
                          base_fare_minor, per_km_minor, per_minute_minor, surge_bp, estimated_fare_minor, requested_at)
       SELECT id, 6.45 + n * 0.001, 3.40 + n * 0.001, n || ' Marina Road', 6.52, 3.37, n || ' Allen Avenue', 50000, 15000, 2500, 10000, 185000 + n * 1000, now() - n * interval '2 seconds'
       FROM riders WHERE n <= 20
       RETURNING id, requested_at
     ),
     online AS (SELECT id, row_number() OVER (ORDER BY licence_number) AS n FROM drivers WHERE is_online)
INSERT INTO trip_offers (trip_id, driver_id, offered_at, expires_at)
SELECT t.id, o.id, t.requested_at + interval '1 second', now() + interval '10 minutes'
FROM (SELECT *, row_number() OVER (ORDER BY requested_at) AS n FROM new_trips) t
JOIN online o ON o.n IN (t.n, t.n + 20, t.n + 40);

ANALYZE users, drivers, vehicles, trips, trip_events, trip_offers, payments, reviews;
