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

runtimes="${PROBE_RUNTIMES:-iOS-18-6}"
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

  # Every simctl call is wrapped in a timeout. A hung `boot` or `bootstatus` silently
  # ate a whole job once, and a probe that cannot finish is worse than one that fails.
  sim() { timeout "$1" xcrun simctl "${@:2}"; }

  # Use a device the runner image already created for this runtime rather than
  # creating one. `simctl create` is the step that failed and then hung across two
  # earlier runs, and the image ships a full set of devices per runtime anyway.
  say "  selecting a preinstalled device for $rt_id"
  udid="$(xcrun simctl list devices available -j 2>/dev/null | RT="$rt_id" python3 -c '
import json,os,sys
d=json.load(sys.stdin); rt=os.environ["RT"]
devs=d["devices"].get(rt,[])
pref=[x for x in devs if "iPhone" in x.get("name","")] or devs
print(pref[0]["udid"] if pref else "")')"
  if [[ -z "$udid" ]]; then
    say "SKIP no preinstalled device under $rt_id. Devices present:"
    xcrun simctl list devices available 2>&1 | sed 's/^/    /' | tee -a "$summary"
    say ""; continue
  fi
  say "  device: $udid"
  say "  booting $udid"
  sim 240 boot "$udid" >/dev/null 2>&1
  sim 240 bootstatus "$udid" -b >/dev/null 2>&1
  boot_state="$(xcrun simctl list devices -j 2>/dev/null | UD="$udid" python3 -c 'import json,os,sys
d=json.load(sys.stdin); u=os.environ["UD"]
print(next((x["state"] for v in d["devices"].values() for x in v if x["udid"]==u), "unknown"))')"
  say "  boot state: $boot_state"
  if [[ "$boot_state" != "Booted" ]]; then
    say "RESULT $rt: INCONCLUSIVE. Simulator never reached Booted."
    overall=1
    say ""; continue
  fi

  ilog="$result_dir/logs/$rt-simctl.log"
  say "  installing apps"
  { echo "== install ProbeA"; sim 120 install "$udid" "$work_dir/ProbeA.app" 2>&1
    echo "== install ProbeB"; sim 120 install "$udid" "$work_dir/ProbeB.app" 2>&1
  } > "$ilog"

  # ---- negative control: system-initiated open, must always reach ProbeB -------
  say "  running negative control"
  { echo "== control openurl"; sim 60 openurl "$udid" "probeb://control" 2>&1; } >> "$ilog"
  sleep 8
  control_marker="$(read_marker "$udid" "$B_ID")"
  if [[ -n "$control_marker" ]]; then control_ok=1; else control_ok=0; fi
  say "control_system_openurl_reached_appb=$([[ $control_ok -eq 1 ]] && echo true || echo false)"
  [[ -n "$control_marker" ]] && say "  control marker: $(printf '%s' "$control_marker" | tr '\n' ';')"

  sim 60 terminate "$udid" "$B_ID" >/dev/null 2>&1
  sleep 2
  clear_marker "$udid" "$B_ID"

  # ---- the measurement: app-initiated open, nothing taps anything -------------
  say "  launching sender"
  { echo "== launch ProbeA"
    sim 60 launch --terminate-running-process \
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

  sim 90 shutdown "$udid" >/dev/null 2>&1 || true
  say ""
done

say "=== probe complete ==="
exit $overall
