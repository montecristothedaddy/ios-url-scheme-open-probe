# iOS cross-app URL scheme open probe

A small experiment: when one iOS app calls `UIApplication.open()` on **another** app's custom
URL scheme, does the system interpose a user confirmation, and does the answer depend on the
iOS version?

## Method

Two trivial apps, no entitlements, no app groups, no relationship to each other:

- **ProbeA** calls `UIApplication.open()` exactly once, on `probeb://...`. It deliberately does
  not declare `LSApplicationQueriesSchemes`, so `canOpenURL` is reported only for the record.
- **ProbeB** owns the `probeb` scheme and logs a distinctive marker when it is handed a URL.

Nothing in the experiment taps anything, so the marker is the whole measurement:

| Observation | Conclusion |
|---|---|
| marker present | the open completed on its own, no confirmation |
| marker absent | something stopped it before ProbeB ran, a confirmation was interposed |

Every runtime first runs a **negative control**: a system-initiated `simctl openurl`, which must
always reach ProbeB. If the control fails, that runtime is reported INCONCLUSIVE rather than
"confirmation", so an absent marker can never be blamed on a broken scheme registration or on
log capture that was not running.

## Running it

Actions tab, "URL scheme open probe", Run workflow. Defaults to `iOS-18-6 iOS-26-2`.
Results and per-runtime screenshots are uploaded as an artifact.
