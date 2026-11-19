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
