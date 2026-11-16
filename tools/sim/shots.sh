#!/usr/bin/env bash
# Boots an iPhone 13 simulator (the owner's phone), installs the build and takes one picture per line of routes.txt.
# A route line is: <name> <seconds to wait> [launch arguments...]
set -uo pipefail
[ -f build/Build/Products/Debug-iphonesimulator/Wird.app/Wird ] || { echo "the build failed: no app to install"; exit 1; }
APP=build/Build/Products/Debug-iphonesimulator/Wird.app
BID=com.abdullah.wird.reader
OUT=${SHOTS_OUT:-out-sim}
# SHOTS_DEVICE: another device type (the iPad pass takes only the lines whose name starts with "pad-")
DEVTYPE=${SHOTS_DEVICE:-iPhone 13}
DEVNAME=${SHOTS_NAME:-Jalees13}
mkdir -p "$OUT"
RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "import json,sys;r=[x for x in json.load(sys.stdin)['runtimes'] if x.get('isAvailable') and x['platform']=='iOS'];r.sort(key=lambda x:[int(p) for p in x['version'].split('.')]);print(r[-1]['identifier'])")
echo "runtime: $RUNTIME"
DEV=$(xcrun simctl create "$DEVNAME" "$DEVTYPE" "$RUNTIME" 2>/dev/null) || DEV=$(xcrun simctl list devices available -j | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print([x['udid'] for k in d for x in d[k] if 'iPhone' in x['name']][-1])")
echo "device: $DEV"
t0=$(date +%s)
xcrun simctl boot "$DEV"
xcrun simctl bootstatus "$DEV" -b > /dev/null
echo "boot: $(( $(date +%s) - t0 ))s"
xcrun simctl ui "$DEV" appearance dark
xcrun simctl status_bar "$DEV" override --time "11:24" --batteryState charged --batteryLevel 100 --cellularBars 4 2>/dev/null || true
xcrun simctl install "$DEV" "$APP"
# a sample EPUB in the app's Documents folder (the «جليس» folder in Files)
DATA=$(xcrun simctl get_app_container "$DEV" "$BID" data 2>/dev/null) && mkdir -p "$DATA/Documents" && cp tools/sim/sample.epub "$DATA/Documents/" && echo "epub copied"
while read -r name wait args; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue;; esac
  if [ -n "${SHOTS_DEVICE:-}" ]; then case "$name" in pad-*) ;; *) continue;; esac; else case "$name" in pad-*) continue;; esac; fi
  xcrun simctl terminate "$DEV" "$BID" > /dev/null 2>&1 || true
  # shellcheck disable=SC2086
  # the phone's language is Arabic, unless the line names another (an English phone with an Arabic Jalees)
  case " $args " in
    *" -AppleLanguages "*) xcrun simctl launch "$DEV" "$BID" $args > /dev/null || echo "launch failed: $name";;
    *) xcrun simctl launch "$DEV" "$BID" -AppleLanguages "(ar)" -AppleLocale ar_SA $args > /dev/null || echo "launch failed: $name";;
  esac
  sleep "$wait"
  xcrun simctl io "$DEV" screenshot --type=jpeg "$OUT/$name.jpg" > /dev/null 2>&1 && echo "shot: $name"
  # a site's list: where the app's threads are (a frozen app shows its main thread busy, not waiting)
  case "$name" in site-*)
    pid=$(pgrep -f "Wird.app/Wird" | head -1)
    [ -n "$pid" ] && sample "$pid" 3 -file "$OUT/$name.sample.txt" > /dev/null 2>&1 && echo "sampled: $name"
    sleep 5
    xcrun simctl io "$DEV" screenshot --type=jpeg "$OUT/$name-later.jpg" > /dev/null 2>&1 || true;;
  esac
done < tools/sim/routes.txt
# crash reports of the app, if any (the simulator's apps write them on the Mac)
mkdir -p "$OUT/crash"
find "$HOME/Library/Logs/DiagnosticReports" -name "Wird*" -mmin -40 -exec cp {} "$OUT/crash/" \; 2>/dev/null || true
ls "$OUT/crash"
xcrun simctl spawn "$DEV" log show --last 15m --predicate 'process == "Wird"' --style compact 2>/dev/null | grep -iE "jalees" | tail -60 > "$OUT/app.log" || true
ls -la "$OUT"
