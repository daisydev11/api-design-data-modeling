# API contracts

A design, not an implementation: this task is the schema and the contract. Each endpoint below maps to the SQL in `sql/03_queries.sql`, which has been run.

## Conventions

- Base path `/api/v1`. JSON in and out. `Authorization: Bearer <token>`; the token identifies the user, so no endpoint takes a `riderId` or `driverId` from the client.
- Money is always `{ "amountMinor": 585625, "currency": "NGN" }`. Times are ISO 8601 UTC.
- Ids are UUIDs. An id that does not exist and an id that belongs to someone else both return `404`, so the API never confirms that someone else's trip exists.
- Every error has one shape:

```json
{ "error": { "code": "TRIP_ALREADY_ACTIVE", "message": "You already have a trip under way.", "details": {} } }
```

| Status | Used for |
| --- | --- |
| 400 | malformed JSON or query parameter |
| 401 | missing or invalid token |
| 403 | authenticated, wrong role (a rider calling a driver endpoint) |
| 404 | not found, or not yours |
| 409 | the request is valid but conflicts with current state |
| 422 | well-formed but fails validation; `details` lists fields |
| 429 | rate limited, with `Retry-After` |

- **Idempotency.** Every `POST` that creates something or moves money accepts `Idempotency-Key: <uuid>`. The same key with the same body returns the original response and does nothing new. The same key with a different body returns `422 IDEMPOTENCY_KEY_REUSED`. This is what makes a retry on a flaky mobile connection safe.

## 1. Request a trip

`POST /api/v1/trips` (rider) · `Idempotency-Key` required

```json
{ "pickup":  { "lat": 6.4281, "lng": 3.4219, "address": "12 Awolowo Road, Ikoyi" },
  "dropoff": { "lat": 6.6018, "lng": 3.3515, "address": "45 Allen Avenue, Ikeja" } }
```

`201 Created`, `Location: /api/v1/trips/{id}`

```json
{ "data": { "id": "34379ada-ee89-4da5-95c7-4011d1ea8125", "status": "requested",
            "pickup": { "…": "…" }, "dropoff": { "…": "…" },
            "estimatedFare": { "amountMinor": 462500, "currency": "NGN" },
            "surgeMultiplier": 1.25, "requestedAt": "2026-10-07T06:51:59Z" } }
```

The server chooses the tariff and the surge and stores them on the trip. The client never sends a price.

| Error | When |
| --- | --- |
| 422 `VALIDATION_FAILED` | missing field, coordinates out of range, pickup equals drop-off |
| 409 `TRIP_ALREADY_ACTIVE` | the rider has a trip under way. Raised from `uq_trips_one_active_per_rider`, so two simultaneous requests cannot both succeed. `details.tripId` is the active trip |

## 2. Accept a trip

`POST /api/v1/trips/{tripId}/accept` (driver) · no body

`200 OK` with the trip, now `accepted`, including `driver` and `vehicle` snapshots.

Naturally idempotent: if this driver already holds the trip, the same `200` is returned.

| Error | When |
| --- | --- |
| 403 `NOT_A_DRIVER` / `DRIVER_NOT_ACTIVE` | caller has no active driver profile or is offline |
| 404 `TRIP_NOT_FOUND` | no such trip, or it was never offered to this driver |
| 409 `TRIP_ALREADY_TAKEN` | another driver won. Raised from `uq_trip_offers_one_accepted_per_trip` |
| 409 `OFFER_EXPIRED` | the offer window closed |
| 409 `DRIVER_ALREADY_ON_TRIP` | from `uq_trips_one_active_per_driver` |
| 409 `TRIP_NOT_AVAILABLE` | the rider cancelled, or the request expired |

Related, same shape: `GET /api/v1/driver/offers` (open offers), `POST /trips/{id}/arrive`, `POST /trips/{id}/start`, `POST /trips/{id}/cancel` with `{ "reason": "…" }`.

## 3. Complete a trip

`POST /api/v1/trips/{tripId}/complete` (the trip's driver) · `Idempotency-Key` required

```json
{ "distanceMetres": 21400, "durationSeconds": 2340 }
```

`200 OK`

```json
{ "data": { "id": "…", "status": "completed", "distanceMetres": 21400, "durationSeconds": 2340,
            "finalFare": { "amountMinor": 585625, "currency": "NGN" },
            "fareBreakdown": { "baseMinor": 50000, "distanceMinor": 321000, "timeMinor": 97500, "surgeMultiplier": 1.25 },
            "completedAt": "…" } }
```

The server computes the fare from the tariff stored on the trip. The driver's app reports measurements, never an amount.

| Error | When |
| --- | --- |
| 404 `TRIP_NOT_FOUND` | not this driver's trip |
| 409 `INVALID_TRANSITION` | the trip is not `in_progress`. `details: { "from": "accepted", "to": "completed" }`. Comes from the transition trigger |
| 422 `VALIDATION_FAILED` | negative or absurd measurements |

There is no "cancel" for a started trip. An early stop is a completion with the distance actually driven.

## 4. Pay for a trip

`POST /api/v1/trips/{tripId}/payments` (the trip's rider) · `Idempotency-Key` required

```json
{ "paymentMethodId": "pm_3f0c…" }
```

`201 Created`

```json
{ "data": { "id": "…", "tripId": "…", "status": "succeeded",
            "amount": { "amountMinor": 585625, "currency": "NGN" }, "createdAt": "…" } }
```

No amount in the request: it is always the trip's `final_fare_minor`. `status` may be `pending` if the provider confirms later by webhook; the webhook is matched by `provider_reference` and is safe to receive twice.

| Error | When |
| --- | --- |
| 404 `TRIP_NOT_FOUND` | not this rider's trip |
| 409 `TRIP_NOT_COMPLETED` | nothing to pay yet |
| 409 `TRIP_ALREADY_PAID` | from `uq_payments_one_success_per_trip`. A double tap cannot charge twice |
| 402 `PAYMENT_DECLINED` | the provider refused. A `failed` payment row is kept; the rider may try again with a new key |
| 502 `PAYMENT_PROVIDER_UNAVAILABLE` | provider did not answer. Retry with the **same** key |

## 5. Trip history

`GET /api/v1/trips?limit=20&cursor=…&status=completed` (rider)

`200 OK`

```json
{ "data": [ { "id": "…", "status": "completed", "requestedAt": "2026-10-05T16:43:27Z",
              "dropoffAddress": "4 Ikorodu Road",
              "finalFare": { "amountMinor": 558947, "currency": "NGN" },
              "driverName": "Emeka Uche" } ],
  "meta": { "limit": 20, "hasMore": true, "nextCursor": "eyJ…" } }
```

- Cursor pagination on `(requested_at DESC, id DESC)`: stable when a new trip arrives while the rider scrolls, and the cost does not grow with the page number.
- `limit` defaults to 20, is clamped to 100. An unreadable cursor or unknown `status` is `400`.
- List items are a summary. The full trip is `GET /api/v1/trips/{id}`, which can take `?include=payments,reviews`.
- An empty history is `200` with `"data": []`, never `404`.
