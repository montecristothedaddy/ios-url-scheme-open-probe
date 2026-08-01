#!/usr/bin/env bash
#
# Does iOS interpose a user confirmation when one app calls UIApplication.open()
# on another app's custom URL scheme, and does the answer depend on the iOS version?
#
# Method. Two trivial apps. ProbeA calls open() exactly once. ProbeB owns the scheme
# and appends a marker line to a file inside its own container every time it is handed
# a URL. Nothing in this experiment taps anything, so the marker is the whole
# measurement:
#
#   marker present  -> the open completed on its own            -> no confirmation
#   marker absent   -> something stopped it before ProbeB ran   -> confirmation
#
# The marker is a file, not a log line, so the result does not depend on a log stream
# being attached at the right moment or on a predicate matching.
#
# Every runtime first runs a system-initiated `simctl openurl` as a negative control,
# which must always reach ProbeB. If the control fails, that runtime is reported
# INCONCLUSIVE, so a broken apparatus can never be misread as "the platform blocked it".

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

cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

say "=== iOS cross-app URL scheme open probe, run ${run_id} ==="
say "xcode: $(xcodebuild -version 2>/dev/null | head -1)"
say "runtimes requested: ${runtimes}"
say ""

build_app() {
  local name="$1" src="$2" plist="$3"
  local dir="$work_dir/$name.app"
  mkdir -p "$dir"
  xcrun -sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios15.2-simulator" \
    -parse-as-library -O -o "$dir/$name" "$src" > "$result_dir/logs/build-$name.log" 2>&1
  if [[ ! -f "$dir/$name" ]]; then
    say "FATAL build failed for $name"; tail -20 "$result_dir/logs/build-$name.log" | tee -a "$summary"; exit 1
  fi
  cp "$plist" "$dir/Info.plist"
  codesign --force --sign - "$dir" >/dev/null 2>&1 || true
  say "built $name"
}
build_app ProbeA "$root_dir/AppA.swift" "$root_dir/AppA-Info.plist"
build_app ProbeB "$root_dir/AppB.swift" "$root_dir/AppB-Info.plist"
say ""

# Read ProbeB's marker file out of its data container. Empty output means no marker.
read_marker() {
  local udid="$1" bundle="$2"
  local c
  c="$(xcrun simctl get_app_container "$udid" "$bundle" data 2>/dev/null)"
  [[ -n "$c" && -f "$c/Documents/probe-marker.txt" ]] && cat "$c/Documents/probe-marker.txt"
}
clear_marker() {
  local udid="$1" bundle="$2"
  local c
  c="$(xcrun simctl get_app_container "$udid" "$bundle" data 2>/dev/null)"
  [[ -n "$c" ]] && rm -f "$c/Documents/probe-marker.txt"
  return 0
}

overall=0
for rt in $runtimes; do
  say "---------------------------------------------------------------"
  say "RUNTIME $rt"
  rt_id="$(xcrun simctl list runtimes available -j \
    | RT="$rt" python3 -c 'import json,os,sys
d=json.load(sys.stdin); rt=os.environ["RT"]
m=[r["identifier"] for r in d["runtimes"] if rt in r["identifier"] and r.get("isAvailable")]
print(m[-1] if m else "")')"
  if [[ -z "$rt_id" ]]; then say "SKIP $rt not available on this image"; say ""; continue; fi
  say "runtime id: $rt_id"

  udid="$(xcrun simctl create "probe-$rt" "com.apple.CoreSimulator.SimDeviceType.iPhone-16" "$rt_id" 2>/dev/null)"
  if [[ -z "$udid" ]]; then say "SKIP could not create a simulator for $rt"; say ""; continue; fi
  xcrun simctl boot "$udid" >/dev/null 2>&1
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1

  ilog="$result_dir/logs/$rt-simctl.log"
  { echo "== install ProbeA"; xcrun simctl install "$udid" "$work_dir/ProbeA.app" 2>&1
    echo "== install ProbeB"; xcrun simctl install "$udid" "$work_dir/ProbeB.app" 2>&1
  } > "$ilog"

  # ---- negative control: system-initiated open, must always reach ProbeB -------
  { echo "== control openurl"; xcrun simctl openurl "$udid" "probeb://control" 2>&1; } >> "$ilog"
  sleep 8
  control_marker="$(read_marker "$udid" "$B_ID")"
  if [[ -n "$control_marker" ]]; then control_ok=1; else control_ok=0; fi
  say "control_system_openurl_reached_appb=$([[ $control_ok -eq 1 ]] && echo true || echo false)"
  [[ -n "$control_marker" ]] && say "  control marker: $(printf '%s' "$control_marker" | tr '\n' ';')"

  xcrun simctl terminate "$udid" "$B_ID" >/dev/null 2>&1
  sleep 2
  clear_marker "$udid" "$B_ID"

  # ---- the measurement: app-initiated open, nothing taps anything -------------
  { echo "== launch ProbeA"
    xcrun simctl launch --terminate-running-process \
      --setenv PROBE_TARGET_URL "probeb://from-another-app" "$udid" "$A_ID" 2>&1
  } >> "$ilog"
  sleep 15

  xcrun simctl io "$udid" screenshot "$result_dir/screenshots/$rt.png" >/dev/null 2>&1

  sender_marker="$(read_marker "$udid" "$A_ID")"
  recv_marker="$(read_marker "$udid" "$B_ID")"
  say "sender_ran=$([[ -n "$sender_marker" ]] && echo true || echo false)"
  [[ -n "$sender_marker" ]] && say "  sender: $(printf '%s' "$sender_marker" | tr '\n' ';')"
  say "receiver_marker=$([[ -n "$recv_marker" ]] && echo true || echo false)"
  [[ -n "$recv_marker" ]] && say "  receiver: $(printf '%s' "$recv_marker" | tr '\n' ';')"

  if [[ $control_ok -eq 0 ]]; then
    say "RESULT $rt: INCONCLUSIVE. The negative control failed, so this runtime measures nothing."
    say "  simctl diagnostics:"; sed 's/^/    /' "$ilog" | tee -a "$summary"
    overall=1
  elif [[ -z "$sender_marker" ]]; then
    say "RESULT $rt: INCONCLUSIVE. The sender never ran, so nothing was measured."
    say "  simctl diagnostics:"; sed 's/^/    /' "$ilog" | tee -a "$summary"
    overall=1
  elif [[ -n "$recv_marker" ]]; then
    say "RESULT $rt: NO CONFIRMATION. The cross-app open reached the receiver with zero taps."
  else
    say "RESULT $rt: CONFIRMATION INTERPOSED. Control reached the receiver, the app-initiated open did not."
  fi

  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  say ""
done

say "=== probe complete ==="
exit $overall
