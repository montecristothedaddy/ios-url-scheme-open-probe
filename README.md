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

## Status: apparatus not yet working

As of 2026-08-01 this probe has **not produced a usable measurement**. On the `macos-15` runner the
simulator never reaches `Booted`, on both `iOS-18-6` and `iOS-26-2`, whether the device is created
with `simctl create` or taken from the preinstalled set. Every run therefore reports INCONCLUSIVE,
which is the intended behaviour: the negative control refuses to let a broken apparatus be read as a
platform result.

**Do not read any past run of this repo as evidence that iOS does or does not confirm cross-app URL
scheme opens.** The question is open.

Next thing to try: stop driving the simulator with bare `simctl boot` plus `bootstatus`, and instead
let `xcodebuild test -destination 'platform=iOS Simulator,...'` bring the simulator up, which is the
path that demonstrably works on these runners. That means giving the probe a real Xcode project and
an XCUITest rather than two hand-built `.app` bundles, which is more setup but uses the supported
route.
