## Part A

### RES-101 (2 hours)

#### Cause

Each call to the asynchronous search function in `search_deals_controller.dart` starts a separate request. As the user types into the text box, the request that finishes last overwrites the results of requests that finished earlier. A query containing only part of the user's input, such as a single character, can take longer than the complete query. This causes results for an earlier, incomplete query to overwrite the results for the user's latest input.

#### Solution

Update `search_deals_controller.dart` to include a controller-level variable that tracks the latest query string. Compare this variable with the query string used in `_search`. If they do not match, ignore the results.

### RES-102 (1 hour 30 minutes)

#### Cause

The widget's state in `pickup_countdown.dart` creates a periodic timer that runs repeatedly until `cancel()` is called. When the user navigates back to Home from My orders, Flutter removes the page and disposes the countdown's state. However, the timer continues running and calls `setState()` on the disposed state.

#### Solution

Store the timer in a field on `_PickupCountdownState` and override `dispose()` to call `_timer.cancel()` before `super.dispose()`. This stops the timer from calling `setState()` after the state has been disposed.

### RES-103 (2 hours)

#### Cause

Each time `DealDetailsController` is initialized, it creates a listener on the shared cart's `itemCount` to call `_recheckAvailability()`. When the user returns to the home page, the controller is closed, but the listener remains active. When the user adds an item to the bag, the change in `itemCount` triggers all remaining listeners, including those that reference closed controllers.

#### Solution

Store the `Worker` returned by `ever()` and override `onClose()` in `DealDetailsController` to dispose of the worker when the user leaves the deal page. Also check `isClosed` after the awaited request in `_recheckAvailability()` to prevent an in-flight request from updating the controller after it has closed.

### RES-104 (3 hours)

#### Cause

Duplicate deal cards occur because `refreshDeals()` and `loadMore()` update the same feed and page counter without coordinating their in-flight requests. In the original implementation, `loadMore()` increments `_page` before awaiting the next page. If refresh finishes first, it replaces the feed with page 1 and resets `_page` to 1. The older pagination request then appends its results without advancing the reset counter. The next pagination request fetches page 2 again, creating duplicate cards.

Reproduction test case:

1. Load page 1 of the home feed.
2. Scroll to the bottom to request page 2, keeping that request pending.
3. Pull down to refresh and let the new page 1 request finish first.
4. Let the older page 2 request finish.
5. Scroll to the bottom again.

Before the fix, page 2 is appended twice. Continuing through the catalog can produce 142 cards for 122 unique deals. After the fix, the stale response is ignored, the next load requests page 2, and each deal appears once.

Additional test cases:

| Case | Expected result |
|---|---|
| Pagination finishes before refresh | The successful refresh replaces the old feed, and the next load requests page 2. |
| An old page 3 request fails after refresh succeeds | The refreshed page counter stays at 1, and the footer does not show a failure for the stale request. |
| The current pagination request fails | The footer shows a failure, and retry requests the same page, including when the last page fails. |
| Refresh fails while pagination is pending | Existing deals remain available, and valid pagination results can still be retained without duplicates or skipped pages. |
| Refresh succeeds after the catalog is exhausted | The exhausted footer resets, and pagination can load page 2 again. |

Request order can be controlled with repository test doubles and `Completer` objects. Failure cases require injected errors because the current fake feed endpoint does not throw.

#### Solution

Use `_isRefresh` to prevent overlapping refreshes and block new pagination requests while refresh is running. After a successful refresh, reset `_page` to 1 and `_nextPage` to 2. Compare the pagination state before accepting a response or handling an error so that stale requests cannot update the refreshed feed. Roll back the page counter only when the current pagination request fails, allowing the same page to be retried. Clear loading flags in `finally`, report current failures through the refresh controller, and reset the exhausted footer after a successful refresh.
