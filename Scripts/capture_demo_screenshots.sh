#!/bin/zsh
# Capture the README screenshots from Vibe Bar's demo mode.
#
# For every surface below, in both appearances, this launches the packaged
# app against a demo home (see Scripts/demo_home.py and DemoMode.swift),
# waits for the app to report where the surface landed, captures that region
# of the screen at native resolution, and quits the app. The running Vibe Bar
# is not touched: the demo instance is a second process with its own home.
#
#   ./Scripts/build_app.sh release
#   ./Scripts/demo_home.py
#   ./Scripts/capture_demo_screenshots.sh            # → docs/screenshots/
#   ./Scripts/capture_demo_screenshots.sh /tmp/shots popover:overview
#
# Captures land on the sharpest attached display. Leave the mouse alone while
# it runs — the popover is transient and a click would dismiss it.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="${VIBEBAR_APP:-$REPO/.build/Vibe Bar.app}/Contents/MacOS/VibeBar"
DEMO_HOME="${VIBEBAR_DEMO_HOME:-/tmp/vibebar-demo-home}"
OUT="${1:-$REPO/docs/screenshots}"
MARGIN="${MARGIN:-28}"          # points of backdrop kept around a surface
SETTLE="${SETTLE:-1.5}"         # seconds after the report before capturing
MAX_WIDTH="${MAX_WIDTH:-1600}"  # pixels; captures wider than this are resampled
shift $(( $# > 0 ? 1 : 0 ))

# name=surface=appearances. The name is the file stem; a light capture gets a
# -light suffix. Every surface is captured dark; the light twin is kept for
# the surfaces the README shows in both, which keeps the checked-in set small.
SURFACES=(
  "popover-overview=popover:overview=both"
  "popover-openai=popover:openAI=dark"
  "popover-anthropic=popover:claude=dark"
  "popover-google=popover:googleAI=dark"
  "popover-spacexai=popover:grok=dark"
  "popover-misc=popover:misc=dark"
  "popover-machines=popover:machines=dark"
  "mini-regular=mini:regular=both"
  "mini-compact=mini:compact=dark"
  "workbench-usage=workbench:usageStats=both"
  "workbench-sessions=workbench:sessionManager=both"
  "workbench-skills=workbench:skillsManager=both"
  "settings-layout=settings:layout=both"
  "settings-menubar=settings:menuBar=dark"
  "settings-mcp=settings:mcp=dark"
  "settings-remote=settings:remote=dark"
)
if (( $# > 0 )); then
  SURFACES=()
  for wanted in "$@"; do
    SURFACES+=("${wanted//:/-}=$wanted=both")
  done
fi

[[ -x "$APP" ]] || { echo "capture: no app at $APP — run ./Scripts/build_app.sh first" >&2; exit 1; }
[[ -d "$DEMO_HOME/.vibebar" ]] || { echo "capture: no demo home at $DEMO_HOME — run ./Scripts/demo_home.py first" >&2; exit 1; }
mkdir -p "$OUT"

capture_one() {
  local name="$1" surface="$2" appearance="$3"
  local suffix=""
  [[ "$appearance" == "light" ]] && suffix="-light"
  local file="$OUT/$name$suffix.png"
  local log; log="$(mktemp -t vibebar-demo)"

  VIBEBAR_DEMO_HOME="$DEMO_HOME" \
  VIBEBAR_DEMO_APPEARANCE="$appearance" \
  VIBEBAR_DEMO_SURFACE="$surface" \
    "$APP" >"$log" 2>&1 &
  local pid=$!

  local report="" waited=0
  while (( waited < 60 )); do
    if report="$(grep -m1 '^VIBEBAR_DEMO_WINDOWS ' "$log" 2>/dev/null)" && [[ -n "$report" ]]; then
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "capture: $name ($appearance): app exited early" >&2
      cat "$log" >&2
      return 1
    fi
    sleep 0.25
    (( waited += 1 ))
  done
  if [[ -z "$report" ]]; then
    echo "capture: $name ($appearance): no window report after 15s" >&2
    kill "$pid" 2>/dev/null || true
    return 1
  fi

  # Union of the reported windows, padded, clamped to the target screen.
  local region
  region="$(MARGIN="$MARGIN" python3 - "${report#VIBEBAR_DEMO_WINDOWS }" <<'PY' || true
import json, os, sys
report = json.loads(sys.argv[1])
margin = float(os.environ["MARGIN"])
windows = report["windows"]
if not windows:
    sys.exit("no windows reported")
x0 = min(w["x"] for w in windows) - margin
y0 = min(w["y"] for w in windows) - margin
x1 = max(w["x"] + w["width"] for w in windows) + margin
y1 = max(w["y"] + w["height"] for w in windows) + margin
screen = report.get("screen")
if screen:
    x0 = max(x0, screen["x"]); y0 = max(y0, screen["y"])
    x1 = min(x1, screen["x"] + screen["width"]); y1 = min(y1, screen["y"] + screen["height"])
print(f"{x0:.0f},{y0:.0f},{x1 - x0:.0f},{y1 - y0:.0f}")
PY
)"

  if [[ -z "$region" ]]; then
    echo "capture: $name ($appearance): surface did not appear" >&2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$log"
    return 1
  fi

  # Controls render in their inactive style unless the app is frontmost,
  # and an app cannot always activate itself; System Events can do it.
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $pid) to true" >/dev/null 2>&1 || true
  sleep "$SETTLE"
  screencapture -x -R "$region" "$file"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$log"
  # Native 2× is more than a README needs: GitHub shows these at well under
  # 900 CSS pixels, so 1600 keeps them crisp on a Retina display at a third
  # of the bytes.
  local width; width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ {print $2}')"
  if (( width > MAX_WIDTH )); then
    sips --resampleWidth "$MAX_WIDTH" "$file" >/dev/null
  fi
  local size; size="$(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')"
  echo "capture: $name$suffix.png  region=$region  px=$size $(du -k "$file" | cut -f1)KB"
}

# Never leave a demo instance behind, whatever stops the run.
cleanup() { pkill -f "$APP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

failures=0
for appearance in dark light; do
  for entry in "${SURFACES[@]}"; do
    local_name="${entry%%=*}"
    rest="${entry#*=}"
    local_surface="${rest%%=*}"
    wants="${rest#*=}"
    [[ "$appearance" == "light" && "$wants" != "both" ]] && continue
    # One retry: a surface can miss its window if the Mac was busy, and a
    # second launch a moment later is cheaper than a re-run of the whole set.
    capture_one "$local_name" "$local_surface" "$appearance" \
      || capture_one "$local_name" "$local_surface" "$appearance" \
      || (( failures += 1 ))
  done
done
if (( failures > 0 )); then
  echo "capture: $failures surface(s) failed" >&2
  exit 1
fi
# Optional: palette-quantise the set (a third of the bytes, no visible
# change). Skipped, with a note, when Pillow is not installed.
"$REPO/Scripts/optimize_screenshots.py" "$OUT"/*.png
echo "capture: done → $OUT"
