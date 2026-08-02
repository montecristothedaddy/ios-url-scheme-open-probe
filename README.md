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

## History, so nobody repeats it

Runs before 2026-08-02 produced **no usable measurement** and every one of them self-reported
`INCONCLUSIVE`. The cause was found on 2026-08-02 and it was entirely local to the harness:
every `simctl` call was wrapped in `timeout`, **which macOS does not ship**, and stderr went to
`/dev/null`. So `simctl boot` was never actually executed, `command not found` was invisible, the
device stayed `Shutdown`, and the script correctly refused to call that a result. It was never
evidence about iOS.

**Do not read any run before 2026-08-02 as evidence that iOS does or does not confirm cross-app
URL scheme opens.** Do not reintroduce a bare `timeout`, and do not send simctl diagnostics to
`/dev/null`.
