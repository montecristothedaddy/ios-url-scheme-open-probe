#!/usr/bin/env bash
#
# Does iOS interpose a user confirmation when one app calls UIApplication.open()
# on another app's custom URL scheme, and does the answer depend on the iOS version?
#
# Method. Two trivial apps. ProbeA calls open() exactly once. ProbeB owns the scheme
# and logs a distinctive marker when it is handed a URL. Nothing in this experiment
# taps anything, so the marker is the whole measurement:
#
#   marker present  -> the open completed on its own            -> no confirmation
#   marker absent   -> something stopped it before ProbeB ran   -> confirmation
#
# A system-initiated `simctl openurl` runs first on every runtime as a negative
# control, so an absent marker can never be blamed on a broken scheme registration
# or on log capture that was not working.

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

cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

say "=== iOS cross-app URL scheme open probe, run ${run_id} ==="
say "xcode: $(xcodebuild -version 2>/dev/null | head -1)"
say "runtimes requested: ${runtimes}"
say ""

# Build both apps once. The simulator SDK slice is shared across runtimes and both
# bundles declare MinimumOSVersion 15.2.
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

  xcrun simctl install "$udid" "$work_dir/ProbeA.app" >/dev/null 2>&1
  xcrun simctl install "$udid" "$work_dir/ProbeB.app" >/dev/null 2>&1

  log="$result_dir/logs/$rt.log"
  xcrun simctl spawn "$udid" log stream --style compact \
    --predicate 'processImagePath CONTAINS "Probe"' > "$log" 2>&1 &
  log_pid=$!
  sleep 3

  # ---- negative control: system-initiated open, must always reach ProbeB -------
  xcrun simctl openurl "$udid" "probeb://control" >/dev/null 2>&1
  sleep 5
  control_hits="$(grep -c "PROBE_B_RECEIVED_URL\|PROBE_B_LAUNCHED" "$log" 2>/dev/null || true)"
  control_hits="${control_hits//[^0-9]/}"; control_hits="${control_hits:-0}"
  say "control_system_openurl_reached_appb=$([[ "$control_hits" -gt 0 ]] && echo true || echo false)"

  xcrun simctl terminate "$udid" com.example.probeb >/dev/null 2>&1
  sleep 2
  : > "$log"
  sleep 1

  # ---- the measurement: app-initiated open, nothing taps anything -------------
  xcrun simctl launch --terminate-running-process \
    --setenv PROBE_TARGET_URL "probeb://from-another-app" \
    "$udid" com.example.probea >/dev/null 2>&1
  sleep 15

  xcrun simctl io "$udid" screenshot "$result_dir/screenshots/$rt.png" >/dev/null 2>&1

  a_open="$(grep -o "PROBE_A open_accepted=[a-z]*" "$log" 2>/dev/null | tail -1 || true)"
  a_can="$(grep -o "PROBE_A canOpenURL=[a-z]*" "$log" 2>/dev/null | tail -1 || true)"
  b_hits="$(grep -c "PROBE_B_RECEIVED_URL\|PROBE_B_LAUNCHED" "$log" 2>/dev/null || true)"
  b_hits="${b_hits//[^0-9]/}"; b_hits="${b_hits:-0}"

  say "sender: ${a_can:-<no canOpenURL line>}"
  say "sender: ${a_open:-<no open_accepted line>}"
  say "receiver_marker_count=$b_hits"
  if [[ "$control_hits" -gt 0 && "$b_hits" -gt 0 ]]; then
    say "RESULT $rt: NO CONFIRMATION. The cross-app open reached the receiver with zero taps."
  elif [[ "$control_hits" -gt 0 ]]; then
    say "RESULT $rt: CONFIRMATION INTERPOSED. Control reached the receiver, the app-initiated open did not."
  else
    say "RESULT $rt: INCONCLUSIVE. The negative control failed, so this runtime measures nothing."
    overall=1
  fi

  kill "$log_pid" 2>/dev/null || true
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  xcrun simctl delete "$udid" >/dev/null 2>&1 || true
  say ""
done

say "=== raw markers seen, per runtime ==="
for f in "$result_dir"/logs/*.log; do
  [[ -e "$f" ]] || continue
  say "--- $(basename "$f")"
  grep -o "PROBE_[A-Z_]*[a-z_=]*" "$f" 2>/dev/null | sort | uniq -c | tee -a "$summary" || true
done
say "=== probe complete ==="
exit $overall
