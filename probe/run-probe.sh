#!/usr/bin/env bash
#
# Two questions, one apparatus.
#
#   Q1. When one iOS app calls UIApplication.open() on another app's custom URL scheme,
#       does the system interpose a user confirmation, and does that depend on iOS version?
#
#   Q2. Can a web page deliver the same custom-scheme URL, and does it need JavaScript?
#
# Method. Two trivial apps with no relationship to each other. ProbeA calls open() once.
# ProbeB owns the scheme and appends a marker line to a file inside its own container every
# time it is handed a URL. Nothing in this experiment taps anything, so for every arm the
# marker is the whole measurement:
#
#   marker present  -> the open completed on its own            -> no confirmation
#   marker absent   -> something stopped it before ProbeB ran   -> confirmation or refusal
#
# The marker is a file, not a log line, so the result does not depend on a log stream being
# attached at the right moment or on a predicate matching.
#
# Controls, because an absent marker must never be readable as a platform decision when the
# apparatus was simply broken:
#
#   * app arm: a system-initiated `simctl openurl` must reach ProbeB first.
#   * web arms: the origin server's own request log must show the GET for that arm, proving
#     the browser actually loaded the page that was supposed to do the navigating.
#
# Any arm whose control fails is reported INCONCLUSIVE, never as a platform result.
#
# HISTORY, so nobody repeats it. Earlier revisions wrapped every simctl call in `timeout`,
# which does not exist on macOS, and discarded stderr. `simctl boot` was therefore never
# actually run, the device stayed Shutdown, and four runs self-reported INCONCLUSIVE for a
# reason that had nothing to do with iOS. Do not reintroduce a bare `timeout`, and do not
# send diagnostics to /dev/null.

set -uo pipefail

root_dir="$(cd "$(dirname "$0")" && pwd)"
work_dir="$(mktemp -d)"
run_id="${GITHUB_RUN_ID:-local}-$$"
result_dir="$root_dir/results/$run_id"
mkdir -p "$result_dir/screenshots" "$result_dir/logs"
summary="$result_dir/PROBE-SUMMARY.txt"
: > "$summary"
say() { printf '%s\n' "$*" | tee -a "$summary"; }

runtimes="${PROBE_RUNTIMES:-iOS-18-6 iOS-26-2}"
A_ID="com.example.probea"
B_ID="com.example.probeb"
WEB_PORT="${PROBE_WEB_PORT:-8731}"
SCHEME_BASE="probeb://from-web"

# Portable stand-in for coreutils timeout. macOS does not ship one.
run_to() {
  local t="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$t"; kill -9 "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid"; local rc=$?
  kill "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  return "$rc"
}
sim() { local t="$1"; shift; run_to "$t" xcrun simctl "$@"; }

device_state() {
  xcrun simctl list devices -j 2>/dev/null | UD="$1" python3 -c '
import json,os,sys
d=json.load(sys.stdin); u=os.environ["UD"]
print(next((x["state"] for v in d["devices"].values() for x in v if x["udid"]==u),"unknown"))'
}

read_marker() {
  local c
  c="$(xcrun simctl get_app_container "$1" "$2" data 2>/dev/null)"
  [[ -n "$c" && -f "$c/Documents/probe-marker.txt" ]] && cat "$c/Documents/probe-marker.txt"
  return 0
}
clear_marker() {
  local c
  c="$(xcrun simctl get_app_container "$1" "$2" data 2>/dev/null)"
  [[ -n "$c" ]] && rm -f "$c/Documents/probe-marker.txt"
  return 0
}

# Poll for the marker instead of sleeping a fixed amount. These runners are slow enough that a
# fixed wait turns "the platform refused" and "we did not wait long enough" into the same result,
# which is exactly the confusion this apparatus exists to avoid.
wait_marker() {
  local udid="$1" bundle="$2" secs="$3" i m
  for ((i = 0; i < secs; i += 2)); do
    m="$(read_marker "$udid" "$bundle")"
    if [[ -n "$m" ]]; then printf '%s' "$m"; return 0; fi
    sleep 2
  done
  return 0
}

# grep -c prints 0 and exits non-zero when there is no match, so guard the value rather
# than the exit status. An `|| echo 0` here would produce the string "0\n0".
count_get() {
  local n
  n="$(grep -c "GET /$1 " "$web_log" 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

cleanup() {
  [[ -n "${web_pid:-}" ]] && kill "$web_pid" 2>/dev/null
  rm -rf "$work_dir"
}
trap cleanup EXIT

say "=== iOS URL scheme delivery probe, run ${run_id} ==="
say "xcode: $(xcodebuild -version 2>/dev/null | head -1)"
say "runtimes requested: ${runtimes}"
say ""
say "runtimes available on this image:"
xcrun simctl list runtimes available 2>&1 | sed 's/^/  /' | tee -a "$summary"
say ""

# ---- origin server for the web arms -----------------------------------------
web_log="$result_dir/logs/webserver.log"
python3 -u "$root_dir/webserver.py" "$WEB_PORT" "$SCHEME_BASE" > "$web_log" 2>&1 &
web_pid=$!
# This runner is slow to start a fresh python3, and a fixed sleep raced it once.
web_up=0
for _ in $(seq 1 40); do
  if curl -fsS --connect-timeout 2 --max-time 4 "http://127.0.0.1:$WEB_PORT/control" > /dev/null 2>&1; then
    web_up=1; break
  fi
  sleep 2
done
if [[ $web_up -eq 0 ]]; then
  say "FATAL origin server did not come up on port $WEB_PORT"
  say "  server log:"; sed 's/^/    /' "$web_log" | tee -a "$summary"
  say "  listeners:"; (lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | head -20 | sed 's/^/    /') | tee -a "$summary"
  exit 1
fi
say "origin server up on http://127.0.0.1:$WEB_PORT (scheme base ${SCHEME_BASE})"
say ""

# ---- build the two apps, through xcodebuild ----------------------------------
# See project.yml for why these must be real Xcode targets and not hand-assembled bundles.
say "installing xcodegen"
brew install xcodegen >> "$result_dir/logs/xcodegen-install.log" 2>&1
if ! command -v xcodegen >/dev/null 2>&1; then
  say "FATAL xcodegen unavailable"
  tail -20 "$result_dir/logs/xcodegen-install.log" | sed 's/^/  /' | tee -a "$summary"
  exit 1
fi
( cd "$root_dir/.." && xcodegen generate ) > "$result_dir/logs/xcodegen.log" 2>&1
if [[ ! -d "$root_dir/../Probe.xcodeproj" ]]; then
  say "FATAL xcodegen did not produce a project"
  tail -20 "$result_dir/logs/xcodegen.log" | sed 's/^/  /' | tee -a "$summary"
  exit 1
fi

dd="$work_dir/dd"
for t in ProbeA ProbeB; do
  xcodebuild -project "$root_dir/../Probe.xcodeproj" -scheme "$t" \
    -sdk iphonesimulator -configuration Release -derivedDataPath "$dd" build \
    > "$result_dir/logs/build-$t.log" 2>&1
  app="$dd/Build/Products/Release-iphonesimulator/$t.app"
  if [[ ! -d "$app" ]]; then
    say "FATAL build failed for $t"
    tail -25 "$result_dir/logs/build-$t.log" | sed 's/^/  /' | tee -a "$summary"
    exit 1
  fi
  say "built $t"
done
appA="$dd/Build/Products/Release-iphonesimulator/ProbeA.app"
appB="$dd/Build/Products/Release-iphonesimulator/ProbeB.app"
say "receiver URL types as built:"
/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$appB/Info.plist" 2>&1 | sed 's/^/  /' | tee -a "$summary"
say ""

overall=0
for rt in $runtimes; do
  say "---------------------------------------------------------------"
  say "RUNTIME $rt"
  ilog="$result_dir/logs/$rt-simctl.log"
  : > "$ilog"

  rt_id="$(xcrun simctl list runtimes available -j \
    | RT="$rt" python3 -c '
import json,os,sys
d=json.load(sys.stdin); rt=os.environ["RT"]
m=[r["identifier"] for r in d["runtimes"] if rt in r["identifier"] and r.get("isAvailable")]
print(m[-1] if m else "")')"
  if [[ -z "$rt_id" ]]; then say "SKIP $rt not available on this image"; say ""; continue; fi
  say "runtime id: $rt_id"

  udid="$(xcrun simctl list devices available -j 2>/dev/null | RT="$rt_id" python3 -c '
import json,os,sys
d=json.load(sys.stdin); rt=os.environ["RT"]
devs=d["devices"].get(rt,[])
pref=[x for x in devs if "iPhone" in x.get("name","")] or devs
print(pref[0]["udid"] if pref else "")')"
  if [[ -z "$udid" ]]; then
    say "SKIP no preinstalled device under $rt_id"
    xcrun simctl list devices available 2>&1 | sed 's/^/    /' | tee -a "$summary"
    say ""; continue
  fi
  say "  device: $udid  state now: $(device_state "$udid")"

  # ---- boot, and prove it booted --------------------------------------------
  say "  booting"
  { echo "== simctl boot"; sim 240 boot "$udid"; echo "boot rc=$?"; } >> "$ilog" 2>&1
  for _ in $(seq 1 48); do
    [[ "$(device_state "$udid")" == "Booted" ]] && break
    sleep 5
  done
  { echo "== simctl bootstatus"; sim 240 bootstatus "$udid" -b; echo "bootstatus rc=$?"; } >> "$ilog" 2>&1
  boot_state="$(device_state "$udid")"
  say "  boot state: $boot_state"
  if [[ "$boot_state" != "Booted" ]]; then
    say "RESULT $rt: INCONCLUSIVE. Simulator never reached Booted."
    say "  diagnostics:"; sed 's/^/    /' "$ilog" | tee -a "$summary"
    overall=1; say ""; continue
  fi

  say "  installing apps"
  { echo "== install ProbeA"; sim 120 install "$udid" "$appA"; echo "rc=$?"
    echo "== install ProbeB"; sim 120 install "$udid" "$appB"; echo "rc=$?"
  } >> "$ilog" 2>&1

  # Did LaunchServices actually register the scheme? If it did not, an absent marker would be
  # our own packaging fault rather than anything the platform decided.
  { echo "== installed ProbeB Info.plist URL types"
    ib="$(xcrun simctl get_app_container "$udid" "$B_ID" app 2>&1)"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$ib/Info.plist" 2>&1
    echo "== listapps entry for ProbeB"
    xcrun simctl listapps "$udid" 2>/dev/null | grep -B4 -A24 "com.example.probeb" | head -60
  } >> "$ilog" 2>&1

  # Prove the receiver actually runs and can write its marker before anything is measured.
  # Without this, a silently non-starting app is indistinguishable from a platform refusal.
  say "  self-test: launching the receiver directly"
  # `simctl launch` blocks until the app reports launch completion and routinely never
  # returns on these runners, so cap it hard. The marker, not the exit code, is the signal.
  { echo "== direct launch ProbeB"; sim 20 launch "$udid" "$B_ID"; echo "rc=$?"; } >> "$ilog" 2>&1
  b_container="$(xcrun simctl get_app_container "$udid" "$B_ID" data 2>&1)"
  { echo "== ProbeB data container: $b_container"
    ls -la "$b_container" 2>&1
    echo "-- Documents:"; ls -la "$b_container/Documents" 2>&1
  } >> "$ilog" 2>&1
  selftest="$(wait_marker "$udid" "$B_ID" 30)"
  say "  selftest_receiver_wrote_marker=$([[ -n "$selftest" ]] && echo true || echo false)"
  if [[ -z "$selftest" ]]; then
    say "RESULT $rt: INCONCLUSIVE. The receiver does not run or cannot write its marker."
    say "  diagnostics:"; sed 's/^/    /' "$ilog" | tee -a "$summary"
    overall=1; say ""; continue
  fi

  reset_arm() {
    sim 60 terminate "$udid" "$B_ID" >> "$ilog" 2>&1
    sim 60 terminate "$udid" "$A_ID" >> "$ilog" 2>&1
    sim 60 terminate "$udid" "com.apple.mobilesafari" >> "$ilog" 2>&1
    sleep 2
    clear_marker "$udid" "$B_ID"
    clear_marker "$udid" "$A_ID"
  }

  # ---- control: system-initiated open, must always reach ProbeB --------------
  say "  arm 0: negative control, system-initiated openurl"
  reset_arm
  { echo "== control openurl"; sim 60 openurl "$udid" "probeb://control"; echo "rc=$?"; } >> "$ilog" 2>&1
  control_marker="$(wait_marker "$udid" "$B_ID" 40)"
  if [[ -n "$control_marker" ]]; then control_ok=1; else control_ok=0; fi
  xcrun simctl io "$udid" screenshot "$result_dir/screenshots/$rt-arm0-control.png" >/dev/null 2>&1
  say "  control_system_openurl_reached_appb=$([[ $control_ok -eq 1 ]] && echo true || echo false)"
  [[ $control_ok -eq 0 ]] && { say "  NOTE control failed. Every arm below is reported but none of them"
                               say "       is a platform result until the control passes."; overall=1; }

  # Independent apparatus check, and it does not involve our scheme at all: does openurl reach
  # Safari for an http URL? That separates "openurl is broken" from "custom scheme dispatch is
  # refused", which the custom-scheme control alone cannot distinguish.
  say "  arm 0b: openurl control for http, Safari"
  http_before="$(count_get control)"
  { echo "== control openurl http"; sim 60 openurl "$udid" "http://127.0.0.1:$WEB_PORT/control"; echo "rc=$?"; } >> "$ilog" 2>&1
  for _ in $(seq 1 15); do [[ "$(count_get control)" -gt "$http_before" ]] && break; sleep 2; done
  xcrun simctl io "$udid" screenshot "$result_dir/screenshots/$rt-arm0b-http.png" >/dev/null 2>&1
  http_after="$(count_get control)"
  say "  control_openurl_http_reached_safari=$([[ "$http_after" -gt "$http_before" ]] && echo true || echo false)"

  # ---- arm 1: app to app ------------------------------------------------------
  say "  arm 1: app-initiated open from an unrelated installed app"
  reset_arm
  { echo "== launch ProbeA"
    sim 60 launch --terminate-running-process \
      --setenv PROBE_TARGET_URL "probeb://from-another-app" "$udid" "$A_ID"
    echo "rc=$?"
  } >> "$ilog" 2>&1
  sender_marker="$(wait_marker "$udid" "$A_ID" 40)"
  recv_marker="$(wait_marker "$udid" "$B_ID" 25)"
  xcrun simctl io "$udid" screenshot "$result_dir/screenshots/$rt-arm1-app.png" >/dev/null 2>&1
  say "  sender_ran=$([[ -n "$sender_marker" ]] && echo true || echo false)"
  [[ -n "$sender_marker" ]] && say "    sender: $(printf '%s' "$sender_marker" | tr '\n' ';')"
  if [[ -z "$sender_marker" ]]; then
    say "  ARM1 $rt: INCONCLUSIVE. The sender never ran."
    overall=1
  elif [[ -n "$recv_marker" ]]; then
    say "  ARM1 $rt: NO CONFIRMATION. Zero taps, the open reached the receiver."
    say "    receiver: $(printf '%s' "$recv_marker" | tr '\n' ';')"
  else
    say "  ARM1 $rt: CONFIRMATION INTERPOSED. Control reached the receiver, the app open did not."
  fi

  # ---- arms 2..n: web delivery -----------------------------------------------
  # Each arm loads a page in Mobile Safari and lets the page try to reach the scheme.
  # The origin server's request log is the control for each one.
  for arm in r302:no-javascript-302-redirect meta:no-javascript-meta-refresh js:javascript-on-load iframe:javascript-in-subframe link:tap-a-link; do
    route="${arm%%:*}"; label="${arm##*:}"
    say "  web arm /$route ($label)"
    reset_arm
    before="$(count_get "$route")"
    { echo "== openurl http /$route"; sim 60 openurl "$udid" "http://127.0.0.1:$WEB_PORT/$route"; echo "rc=$?"; } >> "$ilog" 2>&1
    recv_marker="$(wait_marker "$udid" "$B_ID" 30)"
    xcrun simctl io "$udid" screenshot "$result_dir/screenshots/$rt-web-$route.png" >/dev/null 2>&1
    after="$(count_get "$route")"
    if [[ "$after" -le "$before" ]]; then
      say "  WEB/$route $rt: INCONCLUSIVE. The browser never fetched the page, so nothing was measured."
      overall=1
    elif [[ -n "$recv_marker" ]]; then
      say "  WEB/$route $rt: DELIVERED with zero taps."
      say "    receiver: $(printf '%s' "$recv_marker" | tr '\n' ';')"
    else
      say "  WEB/$route $rt: page loaded, receiver NOT reached without a tap."
    fi
  done

  say "  shutting down"
  sim 120 shutdown "$udid" >> "$ilog" 2>&1
  say ""
done

say "=== web server request log ==="
grep -E "WEBLOG" "$web_log" | tail -40 | sed 's/^/  /' | tee -a "$summary"
say ""
say "=== probe complete ==="
exit $overall
