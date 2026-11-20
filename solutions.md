# Solutions

Earlier ticket diagnoses, F-1/F-2 decisions, AI usage, and design-question answers
are preserved in [solution.md](solution.md). This file adds the F-3 write-up at
the filename requested by the assessment.

## F-3 — Stock reservations with optimistic UI

### Implementation and alternatives

The bag previously changed local quantities without calling the reservation
endpoints. Checkout already accepted a reservation ID, but the bag never supplied
one. `CartService` now owns reservations for the full app session, with an
injected `OrderRepo` and the existing shared clock.

Each added unit immediately appears in the bag, count, and total, then requests
its own one-unit hold. Pending units show “Reserving…” and prevent checkout.
Confirmation replaces the pending unit while keeping its unique operation token.
A failed reservation removes only that unit and shows a plain-language notice.
Removing a pending unit cancels the local intent: a late successful response is
released, and a late failure does not affect a replacement addition. Bag lines
and their unit lists are immutable, including the checkout snapshot.

There is no reservation adjustment endpoint. I chose one hold per unit, grouped
into one visible bag line. Replacing a full-line hold on every quantity change
would either release valid stock before securing a replacement or temporarily
reserve overlapping quantities. Per-unit holds avoid that gap and preserve the
original expiry of existing units. The tradeoff is more reservation requests.
The checkout endpoint accepts repeated deal IDs; the repository submits one
entry per unit and validates nonempty, unique reservation IDs, deal identity,
and quantity before sending anything.

Decrement cancels a pending addition first, otherwise releasing the earliest
confirmed hold and retaining longer-lived holds. Remove and clear release all
confirmed units. Flash-sale expiry releases holds too. Failed release calls
receive at most three attempts, with one- and two-second retry delays, using
the shared clock rather than separate countdown timers. Retry work stops once
the hold has expired or the service closes. Shutdown and late responses receive
best-effort cleanup; the server deadline is the fallback if cleanup cannot reach
the server.

### Expiry behavior

At or after its deadline, an expired unit leaves the bag, the total changes,
and a visible notice explains the change. Other valid units remain. There is no
automatic renewal: the user must deliberately add the deal again. Automatic
renewal could continually monopolize scarce stock and imply availability that
has not actually been confirmed.

Each line shows its earliest confirmed hold deadline; multiple holds are labeled
“Next hold expires in”. Remaining time comes from the API timestamp and the
injectable clock, not a decremented counter. Pending units have no invented
five-minute deadline. The existing countdown widget rebuilds only its text.
Expiry reconciliation runs without a mounted bag screen, on app resume, and
immediately before checkout. If preflight removes anything, checkout stops so
the user can review the new bag and total.

### Checkout and expiry during payment

The cart service acquires an app-wide lock and captures immutable submitted
items before starting checkout. Every mutation path checks the lock; opening
another cart controller cannot start a second request. Only fully confirmed
units can be submitted.

While checkout is pending, local expiry can remove displayed units, but submitted
reservation IDs are not released until the response arrives. If the bag becomes
empty during this time, it shows “Confirming your order…” rather than an ordinary
empty state. The server result remains authoritative: a successful order is
confirmed even if the client countdown crossed zero while awaiting the response.
Success removes submitted units and cleans up remaining holds; the simulator
does not consume reservation records automatically.

A `410` says that an ID is expired or unknown but does not identify which ID.
The conservative response is to invalidate all submitted holds, release them,
and ask the user to add the deals again. This sacrifices some potentially valid
holds to avoid repeatedly submitting an unknown invalid ID. It neither retries
payment nor silently reserves a changed order. Other checkout failures preserve
valid holds and reconcile expired ones. The known gateway-timeout response
explains that the card was not charged; unexpected failures advise checking
My orders before retrying. The app-wide lock is always reset in `finally`, even
if the originating controller was closed.

### Validation and limits

`test/stock_reservation_test.dart` drives the real repository with controlled
API responses and an injectable clock. It covers immediate feedback, out-of-order
responses, partial rollback, cancellation and re-addition, quantity limits,
release cleanup and bounded retries, exact expiry, resume, flash-sale interaction,
malformed/expired responses, immutable snapshots, checkout IDs and quantities,
mid-checkout expiry, `410`, other failures, route changes, button availability,
and countdown rebuild scope. Existing flash-sale and details tests now explicitly
inject immediate reservation fixtures; their original behavior assertions remain.
The startup test also verifies that the cart uses the registered order repository.

Validation on Flutter 3.27.0: all 105 tests passed, including 27 new reservation
tests; `dart analyze lib test` reported no issues; `git diff --check` passed.

The protected backend and seed data are unchanged. The simulator does not deduct
active reservations from available stock or validate their deal/quantity during
checkout. The client enforces its own hold-to-unit consistency but cannot fix
cross-client stock enforcement. Persistence across app termination, clock-skew
correction, and payment idempotency need server/storage contracts absent from
this assessment. These are not simulated by inventing client guarantees.
Widget tests check countdown rebuilds and a 360-pixel layout; this is not a
claim of a physical-device DevTools profile.

### AI usage and time

Codex analyzed the API contract and existing F-1 interaction, implemented F-3,
and wrote controlled-response tests. Two concrete incorrect test suggestions
were caught and corrected: registering session cleanup only in `addTearDown`
ran after Flutter's pending-timer invariant, so service disposal now runs inside
the widget-test body; and casting `find.byTooltip` to an `IconButton` selected
the inner `Tooltip`, so the assertion now selects the actual button by type and
tooltip property. Neither failure was suppressed or used to weaken assertions.

Time spent: approximately 25 minutes for implementation, tests, and this write-up,
in addition to the earlier read-only analysis. With another day, I would profile
the complete bag flow on a physical device and explore server-backed reservation
adjustment, clock synchronization, and idempotent checkout contracts.

No commit was created, as requested.
