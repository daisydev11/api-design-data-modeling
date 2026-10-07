# Two analyses

## Over-fetching: the trip history screen

The history screen shows, per trip: date, destination, fare, driver name, status. A trip, fully expanded (all 30-odd columns plus driver, vehicle, payments and reviews), carries far more.

I measured it on the seeded database, for one rider's 20 most recent trips, as JSON:

| Response | Size for 20 trips |
| --- | --- |
| Full trip with driver, vehicle, payments, reviews | 45,178 bytes |
| The seven fields the screen shows | 4,779 bytes |

About 9.5 times more data than the screen uses, on a mobile connection, on the most-opened list in the app. It also costs four extra joins or lookups per trip on the server.

**Options**

| Approach | For | Against |
| --- | --- | --- |
| REST, one fat representation | simplest | the 45 KB above |
| REST, summary in the list and detail on `GET /trips/{id}`, with `?include=` | small list, cacheable URLs, simple to rate-limit and log | the server decides the shapes; a new screen may need a new field |
| GraphQL | the client asks for exactly its fields; one round trip for nested data | a new server layer, harder caching, query-cost limits needed, N+1 risk in resolvers |

**The same need in GraphQL**

```graphql
query TripHistory($after: String) {
  me {
    trips(first: 20, after: $after) {
      edges { node { id status requestedAt dropoffAddress driverName
                     finalFare { amountMinor currency } } }
      pageInfo { hasNextPage endCursor }
    }
  }
}
```

It would return exactly those seven fields per trip, about the 4.8 KB measured above, and nothing else.

**Decision: REST with a summary list and `include`.** There are two clients (rider app, driver app) built by the same team, and a handful of screens. The over-fetching is fixed by designing the list response for the screen. GraphQL earns its cost when many different clients need many different shapes, which is not this product today. This follows the class guidance: REST for an MVP.

**When I would switch.** Not at a user count. Trip history costs the same per rider at 1,000 users or 1,000,000, because the response is already trimmed. The trigger is the number of *different shapes* clients need: when a third or fourth client (a web dashboard, a partner integration, a support tool) starts asking for its own combination of trip, driver, payment and review fields, and I find myself adding a fourth `include` option or a second purpose-built endpoint for the same data. At that point the server is hand-writing what GraphQL gives for free.

The denormalised `driver_name_snapshot` is what makes the summary a single-table, single-index read.

## Real time: the rider watching their trip

After requesting, the rider needs to see: a driver accepted, the driver's position as they approach, arrival, start, completion.

| Approach | For | Against |
| --- | --- | --- |
| Polling `GET /trips/{id}` every few seconds | works everywhere, nothing new to run | mostly empty responses; either laggy or wasteful; battery |
| Server-Sent Events | one long HTTP response, server pushes; auto-reconnect and `Last-Event-ID` built in; plain HTTP, so auth, proxies and load balancers already work | one direction only; one open connection per watching rider |
| WebSockets | two directions, low overhead per message | own protocol: separate auth, reconnection and scaling to build |

**Decision: SSE for the rider.** The rider only *receives*. Everything the rider *does* (cancel, pay) is an ordinary POST that needs a status code and an idempotency key anyway.

`GET /api/v1/trips/{id}/events` with `Accept: text/event-stream`:

```
id: 3
event: trip.status
data: {"status":"driver_arrived","at":"2026-10-07T06:58:10Z"}

event: driver.location
data: {"lat":6.4302,"lng":3.4188,"at":"2026-10-07T06:58:12Z"}
```

- `trip.status` events carry the `trip_events.id`, so after a dropped connection the client reconnects with `Last-Event-ID` and the server replays what was missed from the table. No status change is lost.
- `driver.location` events are not stored and not replayed: only the latest matters.
- The stream closes when the trip reaches `completed`, `cancelled` or `expired`.
- If SSE is unavailable, the client falls back to polling the same trip endpoint.

**The driver side is different.** The driver app *sends* a position every few seconds. That is where a WebSocket (or batched POSTs) is justified, and positions belong in a fast store such as Redis, not in Postgres rows. Out of scope for this schema, and named in the requirements.

**Limit of this analysis:** the SSE design is on paper. I did not build or load-test it.
