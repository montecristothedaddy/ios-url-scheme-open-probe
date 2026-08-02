# iOS URL scheme delivery probe

Two questions about platform behaviour, one apparatus:

1. When one iOS app calls `UIApplication.open()` on **another** app's custom URL scheme, does
   the system interpose a user confirmation, and does the answer depend on the iOS version?
2. Can a **web page** deliver the same custom-scheme URL, and does it need JavaScript to do it?

## Method

Two trivial apps, no entitlements, no app groups, no relationship to each other:

- **ProbeA** calls `UIApplication.open()` exactly once, on `probeb://...`. It deliberately does
  not declare `LSApplicationQueriesSchemes`, so `canOpenURL` is reported only for the record.
- **ProbeB** owns the `probeb` scheme and appends a marker line to a file in its own container
  every time it is handed a URL.

Nothing in the experiment taps anything, so for every arm the marker is the whole measurement:

| Observation | Conclusion |
|---|---|
| marker present | the open completed on its own, no confirmation |
| marker absent | something stopped it before ProbeB ran |

### Arms

| Arm | Sender | JavaScript needed |
|---|---|---|
| `arm1` | an unrelated installed app calling `UIApplication.open()` | no |
| `/r302` | a plain HTTP 302 whose `Location` is the custom scheme | **no** |
| `/meta` | `<meta http-equiv="refresh">` to the custom scheme | **no** |
| `/js` | `location.href = ...` on load, no user gesture | yes |
| `/iframe` | same, from inside a 1x1 subframe | yes |
| `/link` | an ordinary anchor, which nothing taps | no |

### Controls

An absent marker must never be readable as a platform decision when the apparatus was simply
broken, so every arm has its own control:

- **app arm:** a system-initiated `simctl openurl` must reach ProbeB first.
- **web arms:** the origin server's own request log must show the GET, which proves the browser
  really loaded the page that was supposed to do the navigating.

A failed control is reported `INCONCLUSIVE`, never as a platform result. The `/link` arm doubles
as a sanity check on the whole rig: the page loads but nothing taps the link, so it should always
report "page loaded, receiver NOT reached without a tap".

## Running it

Actions tab, "URL scheme open probe", Run workflow. Defaults to `iOS-18-6 iOS-26-2`. Results,
per-arm screenshots and the origin server's request log are uploaded as an artifact.

## Results, 2026-08-02

Measured on **iOS 18.6** and **iOS 26.2**, each arm on a freshly restarted device, each with its own
control:

| Arm | Result |
|---|---|
| system `simctl openurl` of the custom scheme | `Open in "ProbeB"?` confirmation, on a clean home screen |
| web page, HTTP 302, **no JavaScript** | `Open in "ProbeB"?` confirmation (18.6 and 26.2) |
| web page, `location.href` on load, no gesture | `Open this page in "ProbeB"?` confirmation (18.6) |
| web page with a link that nothing taps | nothing, the control |
| an unrelated installed app calling `UIApplication.open` | confirmation interposed (26.2) |

Three things follow.

1. The confirmation is **not new in iOS 26**. iOS 18.6 does the same thing, so there is no
   version of iOS in this matrix where a custom-scheme open is silent.
2. A **web page can deliver a custom-scheme URL**, and it does not need JavaScript to do it: a plain
   HTTP redirect is enough.
3. The dialog is presented **by Safari** in the web arms and by SpringBoard in the system arm. A UI
   test that queries only `springboard.buttons["Open"]` will miss the Safari one and wrongly record
   "no confirmation shown". Nothing here was tapped, so whether the confirmation is charged once or
   every time is still open.

## History, so nobody repeats it

Runs before 2026-08-02 produced **no usable measurement** and every one of them self-reported
`INCONCLUSIVE`. Four separate harness defects, none of them anything to do with iOS:

1. Every `simctl` call was wrapped in `timeout`, **which macOS does not ship**, with stderr sent to
   `/dev/null`. `simctl boot` was therefore never executed, `command not found` was invisible, and
   the device stayed `Shutdown`.
2. The receiver was a hand-assembled `.app`. `simctl listapps` showed it installed with **no
   `CFBundleURLTypes`**, so LaunchServices never bound the scheme and `simctl openurl` returned
   success while delivering nothing. Hand-built bundles are fine as senders, not as receivers. The
   apps are now built with `xcodebuild`.
3. An unanswered confirmation **persists indefinitely** and survived into the next arm, so a
   screenshot could not be attributed to the arm that caused it. The device is now restarted between
   arms.
4. `simctl launch` has no `--setenv` flag; app environment is passed by prefixing the host
   environment with `SIMCTL_CHILD_`. Using `--setenv` made simctl read the flag as the device
   argument and the sender never ran.

**Do not read any run before 2026-08-02 as evidence that iOS does or does not confirm cross-app
URL scheme opens.** Do not reintroduce a bare `timeout`, and do not send simctl diagnostics to
`/dev/null`.
