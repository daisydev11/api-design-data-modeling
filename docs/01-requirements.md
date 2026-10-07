# Requirements

**Product:** a ride-hailing service for one city. A rider asks for a car from A to B, a nearby driver accepts, drives them, and the rider pays the fare.

## Who uses it

| Actor | What they are |
| --- | --- |
| Rider | A person with an account who requests and pays for trips |
| Driver | A user with an approved driver profile and one active vehicle |
| System (dispatch) | Offers a requested trip to nearby drivers, and expires what nobody takes |

## The five most important actions

1. **A rider requests a trip** from a pickup to a drop-off, and sees an estimated fare.
2. **A driver accepts a trip** that was offered to them. Only one driver can win.
3. **A driver completes a trip**, which fixes the final fare from distance and time.
4. **A rider pays** for the completed trip.
5. **A rider views their trip history**, newest first.

Supporting actions (modelled, not the focus): a rider or driver cancels before the trip starts, each side reviews a completed trip, a driver goes online or offline.

## Rules the data must obey

- A rider has at most one trip under way at a time. So does a driver.
- A trip is accepted by exactly one driver.
- A trip moves only through the allowed statuses (see the state machine). A started trip can only end as completed.
- The fare of a finished trip never changes, even when prices, the driver's name or the car change later.
- A trip is paid for successfully at most once.
- Only a completed trip can be reviewed, once by each side.
- Trips, payments and reviews are financial history and are never hard-deleted.

## Out of scope

Live location storage, route calculation, surge calculation, driver payouts, promotions, multiple cities and currencies in one deployment. The schema stores the *results* of these (coordinates, a surge multiplier, a currency code) and not the machinery.

## Scale assumed

Tens of thousands of trips per month in one city. The seed loads 2,000 users, 300 drivers and 30,020 trips so that query plans mean something.
