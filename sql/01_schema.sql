-- Ride-hailing data model: schema, constraints and indexes.
-- Run:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f sql/01_schema.sql
-- Requires PostgreSQL 13 or newer (gen_random_uuid is built in).

-- ---------------------------------------------------------------- types

CREATE TYPE driver_status   AS ENUM ('pending_approval', 'active', 'suspended');
CREATE TYPE trip_status     AS ENUM ('requested', 'accepted', 'driver_arrived', 'in_progress', 'completed', 'cancelled', 'expired');
CREATE TYPE offer_status    AS ENUM ('offered', 'accepted', 'declined', 'expired');
CREATE TYPE payment_status  AS ENUM ('pending', 'succeeded', 'failed', 'refunded');
CREATE TYPE party           AS ENUM ('rider', 'driver', 'system');

-- ---------------------------------------------------------------- helpers

CREATE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------- users
-- Anyone with an account. Every user can ride; some are also drivers.

CREATE TABLE users (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  phone       text NOT NULL,
  full_name   text NOT NULL,
  email       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz,                       -- soft delete: trips and payments still point here
  CONSTRAINT chk_users_phone_e164 CHECK (phone ~ '^\+[1-9][0-9]{7,14}$'),
  CONSTRAINT chk_users_name_not_blank CHECK (btrim(full_name) <> '')
);
-- A phone number identifies one live account. A deleted account frees its number.
CREATE UNIQUE INDEX uq_users_phone_live ON users (phone) WHERE deleted_at IS NULL;
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------- drivers
-- The driver role of a user. One to one with users.

CREATE TABLE drivers (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  licence_number  text NOT NULL,
  status          driver_status NOT NULL DEFAULT 'pending_approval',
  is_online       boolean NOT NULL DEFAULT false,
  -- Deliberate denormalisation: a running total of the ratings in reviews,
  -- kept in step by a trigger. The average is rating_sum / rating_count.
  rating_sum      integer NOT NULL DEFAULT 0,
  rating_count    integer NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz,
  CONSTRAINT uq_drivers_user UNIQUE (user_id),                 -- one driver profile per user
  CONSTRAINT uq_drivers_licence UNIQUE (licence_number),
  CONSTRAINT chk_drivers_rating_totals CHECK (rating_count >= 0 AND rating_sum BETWEEN rating_count AND rating_count * 5),
  CONSTRAINT chk_drivers_online_only_if_active CHECK (NOT is_online OR (status = 'active' AND deleted_at IS NULL))
);
-- Dispatch asks "who is online right now?". Only those rows are indexed.
CREATE INDEX idx_drivers_online ON drivers (id) WHERE is_online;
CREATE TRIGGER trg_drivers_updated_at BEFORE UPDATE ON drivers FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------- vehicles
-- A driver may register several vehicles and drives one at a time.

CREATE TABLE vehicles (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  driver_id     uuid NOT NULL REFERENCES drivers (id) ON DELETE RESTRICT,
  plate_number  text NOT NULL,
  make          text NOT NULL,
  model         text NOT NULL,
  colour        text NOT NULL,
  year          smallint NOT NULL,
  is_active     boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,
  CONSTRAINT chk_vehicles_year CHECK (year BETWEEN 1990 AND 2100),
  CONSTRAINT chk_vehicles_active_not_deleted CHECK (NOT is_active OR deleted_at IS NULL)
);
CREATE UNIQUE INDEX uq_vehicles_plate_live ON vehicles (plate_number) WHERE deleted_at IS NULL;
-- A driver has at most one active vehicle.
CREATE UNIQUE INDEX uq_vehicles_one_active_per_driver ON vehicles (driver_id) WHERE is_active;
CREATE INDEX idx_vehicles_driver ON vehicles (driver_id);
CREATE TRIGGER trg_vehicles_updated_at BEFORE UPDATE ON vehicles FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------- trips

CREATE TABLE trips (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rider_id              uuid NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  driver_id             uuid REFERENCES drivers (id) ON DELETE RESTRICT,       -- null until a driver accepts
  vehicle_id            uuid REFERENCES vehicles (id) ON DELETE RESTRICT,
  status                trip_status NOT NULL DEFAULT 'requested',

  pickup_lat            double precision NOT NULL,
  pickup_lng            double precision NOT NULL,
  pickup_address        text NOT NULL,
  dropoff_lat           double precision NOT NULL,
  dropoff_lng           double precision NOT NULL,
  dropoff_address       text NOT NULL,

  -- Money: whole minor units (kobo) with the currency beside them. Never a decimal.
  currency              char(3) NOT NULL DEFAULT 'NGN',
  -- Deliberate denormalisation: the tariff in force when the trip was requested.
  base_fare_minor       integer NOT NULL,
  per_km_minor          integer NOT NULL,
  per_minute_minor      integer NOT NULL,
  surge_bp              integer NOT NULL DEFAULT 10000,     -- basis points: 10000 = 1.00x, 15000 = 1.50x
  estimated_fare_minor  integer NOT NULL,
  -- Set when the trip ends.
  distance_m            integer,
  duration_s            integer,
  final_fare_minor      integer,

  -- Deliberate denormalisation: who drove and in what, as it was at the time.
  driver_name_snapshot  text,
  vehicle_snapshot      text,                               -- e.g. "Toyota Corolla, silver, LAG-482-KJ"

  requested_at          timestamptz NOT NULL DEFAULT now(),
  accepted_at           timestamptz,
  arrived_at            timestamptz,
  started_at            timestamptz,
  completed_at          timestamptz,
  cancelled_at          timestamptz,
  cancelled_by          party,
  cancellation_reason   text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),

  -- Lets reviews reference "this trip, and it is completed" (see reviews).
  CONSTRAINT uq_trips_id_status UNIQUE (id, status),

  CONSTRAINT chk_trips_currency CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT chk_trips_money_non_negative CHECK (
    base_fare_minor >= 0 AND per_km_minor >= 0 AND per_minute_minor >= 0 AND estimated_fare_minor >= 0
    AND (final_fare_minor IS NULL OR final_fare_minor >= 0)),
  CONSTRAINT chk_trips_surge CHECK (surge_bp BETWEEN 10000 AND 50000),
  CONSTRAINT chk_trips_coordinates CHECK (
    pickup_lat BETWEEN -90 AND 90 AND dropoff_lat BETWEEN -90 AND 90
    AND pickup_lng BETWEEN -180 AND 180 AND dropoff_lng BETWEEN -180 AND 180),
  -- A trip with no driver is one nobody has accepted; a trip past that point always has one.
  CONSTRAINT chk_trips_driver_matches_status CHECK (
    CASE
      WHEN status IN ('requested', 'expired') THEN driver_id IS NULL
      WHEN status IN ('accepted', 'driver_arrived', 'in_progress', 'completed')
        THEN driver_id IS NOT NULL AND vehicle_id IS NOT NULL AND driver_name_snapshot IS NOT NULL AND vehicle_snapshot IS NOT NULL AND accepted_at IS NOT NULL
      ELSE true                                             -- cancelled: with or without a driver
    END),
  -- A completed trip always has its measurements and its fare. An unfinished one never has a fare.
  CONSTRAINT chk_trips_completed_has_fare CHECK (
    CASE
      WHEN status = 'completed' THEN final_fare_minor IS NOT NULL AND distance_m IS NOT NULL AND duration_s IS NOT NULL AND started_at IS NOT NULL AND completed_at IS NOT NULL
      WHEN status = 'cancelled' THEN completed_at IS NULL    -- final_fare_minor may hold a cancellation fee
      ELSE final_fare_minor IS NULL AND completed_at IS NULL
    END),
  CONSTRAINT chk_trips_cancelled_has_details CHECK ((status = 'cancelled') = (cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL)),
  CONSTRAINT chk_trips_in_progress_has_start CHECK (status <> 'in_progress' OR started_at IS NOT NULL),
  CONSTRAINT chk_trips_times_in_order CHECK (
    (accepted_at  IS NULL OR accepted_at  >= requested_at)
    AND (arrived_at   IS NULL OR arrived_at   >= accepted_at)
    AND (started_at   IS NULL OR started_at   >= accepted_at)
    AND (completed_at IS NULL OR completed_at >= started_at)),
  CONSTRAINT chk_trips_measurements CHECK ((distance_m IS NULL OR distance_m >= 0) AND (duration_s IS NULL OR duration_s >= 0))
);

-- A rider cannot have two trips under way at once.
CREATE UNIQUE INDEX uq_trips_one_active_per_rider ON trips (rider_id)
  WHERE status IN ('requested', 'accepted', 'driver_arrived', 'in_progress');
-- A driver cannot be on two trips at once.
CREATE UNIQUE INDEX uq_trips_one_active_per_driver ON trips (driver_id)
  WHERE status IN ('accepted', 'driver_arrived', 'in_progress');
-- Rider's trip history, newest first.
CREATE INDEX idx_trips_rider_requested_at ON trips (rider_id, requested_at DESC);
-- Driver's completed trips in a period (earnings, history).
CREATE INDEX idx_trips_driver_completed_at ON trips (driver_id, completed_at DESC) WHERE status = 'completed';

CREATE TRIGGER trg_trips_updated_at BEFORE UPDATE ON trips FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- THE STATE MACHINE. The database refuses any status change not listed here,
-- whichever code, script or person attempts it.
CREATE FUNCTION trips_enforce_transition() RETURNS trigger AS $$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;
  IF (OLD.status, NEW.status) IN (
    ('requested',      'accepted'),        -- a driver takes it
    ('requested',      'cancelled'),       -- the rider changes their mind
    ('requested',      'expired'),         -- nobody accepted in time
    ('accepted',       'driver_arrived'),
    ('accepted',       'cancelled'),
    ('accepted',       'requested'),       -- the driver drops out: back to dispatch
    ('driver_arrived', 'in_progress'),
    ('driver_arrived', 'cancelled'),       -- including a rider who never shows up
    ('in_progress',    'completed')        -- the ONLY way out of a started trip
  ) THEN
    RETURN NEW;
  END IF;
  RAISE EXCEPTION 'Illegal trip status transition: % -> %', OLD.status, NEW.status
    USING ERRCODE = 'check_violation', CONSTRAINT = 'trg_trips_enforce_transition';
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_trips_enforce_transition BEFORE UPDATE OF status ON trips FOR EACH ROW EXECUTE FUNCTION trips_enforce_transition();

-- A trip is always born 'requested'. (The seed disables this one trigger to load history.)
CREATE FUNCTION trips_initial_status() RETURNS trigger AS $$
BEGIN
  IF NEW.status <> 'requested' THEN
    RAISE EXCEPTION 'A trip must be created with status requested, not %', NEW.status
      USING ERRCODE = 'check_violation', CONSTRAINT = 'trg_trips_initial_status';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_trips_initial_status BEFORE INSERT ON trips FOR EACH ROW EXECUTE FUNCTION trips_initial_status();

-- ---------------------------------------------------------------- trip_events
-- Append-only history of every status a trip has held. trips.status is the
-- current value; this is how it got there.

CREATE TABLE trip_events (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- internal only, never exposed
  trip_id      uuid NOT NULL REFERENCES trips (id) ON DELETE RESTRICT,
  from_status  trip_status,
  to_status    trip_status NOT NULL,
  occurred_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_trip_events_trip ON trip_events (trip_id, occurred_at);

CREATE FUNCTION trips_record_event() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO trip_events (trip_id, from_status, to_status) VALUES (NEW.id, NULL, NEW.status);
  ELSIF NEW.status <> OLD.status THEN
    INSERT INTO trip_events (trip_id, from_status, to_status) VALUES (NEW.id, OLD.status, NEW.status);
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_trips_record_event AFTER INSERT OR UPDATE OF status ON trips FOR EACH ROW EXECUTE FUNCTION trips_record_event();

CREATE FUNCTION forbid_change() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION '% is append-only: % is not allowed', TG_TABLE_NAME, TG_OP USING ERRCODE = 'check_violation';
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_trip_events_append_only BEFORE UPDATE OR DELETE ON trip_events FOR EACH ROW EXECUTE FUNCTION forbid_change();

-- ---------------------------------------------------------------- trip_offers
-- The many-to-many between trips and drivers: one trip is offered to several
-- drivers, and a driver receives offers for many trips. A join table with
-- data and rules of its own.

CREATE TABLE trip_offers (
  trip_id       uuid NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
  driver_id     uuid NOT NULL REFERENCES drivers (id) ON DELETE CASCADE,
  status        offer_status NOT NULL DEFAULT 'offered',
  offered_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz NOT NULL,
  responded_at  timestamptz,
  CONSTRAINT pk_trip_offers PRIMARY KEY (trip_id, driver_id),          -- a trip is offered to a driver once
  CONSTRAINT chk_trip_offers_expiry CHECK (expires_at > offered_at),
  CONSTRAINT chk_trip_offers_response CHECK ((status IN ('accepted', 'declined')) = (responded_at IS NOT NULL))
);
-- Only one driver can win a trip, however many accept at the same instant.
CREATE UNIQUE INDEX uq_trip_offers_one_accepted_per_trip ON trip_offers (trip_id) WHERE status = 'accepted';
-- A driver's open offers, newest first.
CREATE INDEX idx_trip_offers_driver_open ON trip_offers (driver_id, offered_at DESC) WHERE status = 'offered';

-- ---------------------------------------------------------------- payments
-- Every attempt to charge for a trip. Several may fail; at most one succeeds.

CREATE TABLE payments (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id             uuid NOT NULL REFERENCES trips (id) ON DELETE RESTRICT,
  amount_minor        integer NOT NULL,
  currency            char(3) NOT NULL,
  status              payment_status NOT NULL DEFAULT 'pending',
  provider_reference  text NOT NULL,                    -- ours, sent to the provider; the idempotency key
  failure_reason      text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_payments_provider_reference UNIQUE (provider_reference),
  CONSTRAINT chk_payments_amount_positive CHECK (amount_minor > 0),
  CONSTRAINT chk_payments_currency CHECK (currency ~ '^[A-Z]{3}$'),
  CONSTRAINT chk_payments_failure_reason CHECK (status <> 'failed' OR failure_reason IS NOT NULL)
);
-- A trip is paid for once.
CREATE UNIQUE INDEX uq_payments_one_success_per_trip ON payments (trip_id) WHERE status = 'succeeded';
CREATE INDEX idx_payments_trip ON payments (trip_id, created_at);
CREATE TRIGGER trg_payments_updated_at BEFORE UPDATE ON payments FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------- reviews
-- After a completed trip, the rider may rate the driver and the driver the rider.

CREATE TABLE reviews (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trip_id      uuid NOT NULL,
  -- Always 'completed'. Together with trip_id it references trips (id, status),
  -- so a review can only point at a trip whose status IS completed.
  trip_status  trip_status NOT NULL DEFAULT 'completed',
  author       party NOT NULL,
  rating       smallint NOT NULL,
  comment      text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  deleted_at   timestamptz,                             -- soft delete, for moderation
  CONSTRAINT chk_reviews_trip_completed CHECK (trip_status = 'completed'),
  CONSTRAINT fk_reviews_completed_trip FOREIGN KEY (trip_id, trip_status) REFERENCES trips (id, status) ON DELETE RESTRICT,
  CONSTRAINT uq_reviews_one_per_side UNIQUE (trip_id, author),          -- each side reviews a trip once
  CONSTRAINT chk_reviews_author CHECK (author IN ('rider', 'driver')),
  CONSTRAINT chk_reviews_rating CHECK (rating BETWEEN 1 AND 5)
);
CREATE TRIGGER trg_reviews_updated_at BEFORE UPDATE ON reviews FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Keeps drivers.rating_sum / rating_count equal to the rider-written reviews.
CREATE FUNCTION reviews_update_driver_rating() RETURNS trigger AS $$
BEGIN
  IF NEW.author = 'rider' THEN
    UPDATE drivers d SET rating_sum = d.rating_sum + NEW.rating, rating_count = d.rating_count + 1
    FROM trips t WHERE t.id = NEW.trip_id AND d.id = t.driver_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_reviews_update_driver_rating AFTER INSERT ON reviews FOR EACH ROW EXECUTE FUNCTION reviews_update_driver_rating();
