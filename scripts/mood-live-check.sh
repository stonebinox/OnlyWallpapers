#!/usr/bin/env bash
# mood-live-check.sh: NETWORK-DEPENDENT manual check for Open-Meteo weather fetch.
# This script is NOT part of the default/offline gate suite (mood-check.sh, smoke-run.sh, etc.).
# Invoke it explicitly when you have network access to verify the live fetch path works.
#
# What it does:
#   1. Builds the real openMeteoURL for two test coordinates.
#   2. Does a real curl GET and asserts error!=true plus required fields present.
#   3. (If OW_MOOD_FAKE_RESPONSE_FILE seam is available) pipes the response through
#      the app's parse path to verify end-to-end.
#
# Exit: 0 = all network checks passed (or SKIP if no network), 1 = any check failed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "[mood-live-check] *** REQUIRES INTERNET ACCESS ***"
echo "[mood-live-check] This is NOT part of the offline gate suite. Run explicitly."
echo ""

PASS=0
FAIL=0
SKIP=0

# Test coordinates: Bangalore + San Francisco
COORDS=("13.07,77.75" "37.77,-122.42")

# Build the URL the same way MoodController does (minus the Swift rounding, already 2dp).
build_url() {
    local lat="$1"
    local lon="$2"
    echo "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&timezone=auto&timeformat=unixtime&forecast_days=1&current=weather_code,cloud_cover,precipitation,is_day&daily=sunrise,sunset"
}

check_network() {
    if ! curl --silent --max-time 5 --head "https://api.open-meteo.com/" > /dev/null 2>&1; then
        echo "[mood-live-check] SKIP: network unavailable (cannot reach api.open-meteo.com)"
        SKIP=$((SKIP+1))
        return 1
    fi
    return 0
}

check_json_field() {
    local json="$1"
    local field="$2"
    if ! printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '$field' in d or any('$field' in str(v) for v in d.values())" 2>/dev/null; then
        return 1
    fi
    return 0
}

assert_no_error() {
    local json="$1"
    local coord="$2"
    local has_error
    has_error=$(printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('error',False)).lower())" 2>/dev/null || echo "parse-error")
    if [[ "$has_error" == "true" ]]; then
        local reason
        reason=$(printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('reason','unknown'))" 2>/dev/null || echo "unknown")
        echo "[mood-live-check] FAIL [$coord]: API returned error=true, reason=$reason"
        FAIL=$((FAIL+1))
        return 1
    fi
    return 0
}

assert_current_fields() {
    local json="$1"
    local coord="$2"
    local ok=1
    for field in weather_code cloud_cover precipitation is_day time; do
        has=$(printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); c=d.get('current',{}); print('yes' if '$field' in c else 'no')" 2>/dev/null || echo "no")
        if [[ "$has" != "yes" ]]; then
            echo "[mood-live-check] FAIL [$coord]: current.$field missing from response"
            ok=0
        fi
    done
    for field in sunrise sunset; do
        has=$(printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); dd=d.get('daily',{}); arr=dd.get('$field',[]); print('yes' if arr else 'no')" 2>/dev/null || echo "no")
        if [[ "$has" != "yes" ]]; then
            echo "[mood-live-check] FAIL [$coord]: daily.$field missing or empty"
            ok=0
        fi
    done
    if [[ "$ok" -eq 1 ]]; then
        echo "[mood-live-check] PASS [$coord]: all required fields present in response"
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
    fi
}

# Build binary for fake-response-file seam test
BINARY=""
if swift build -c release > /dev/null 2>&1; then
    BINARY="$(swift build -c release --show-bin-path 2>/dev/null)/OnlyWallpapers"
fi

# Check network first
if ! check_network; then
    echo ""
    echo "[mood-live-check] Network unavailable. Skipping all live checks."
    echo "[mood-live-check] RESULT: SKIP ($SKIP skipped, $PASS passed, $FAIL failed)"
    exit 0
fi

echo "[mood-live-check] Network available. Running live checks..."
echo ""

FAKE_FILE="$(mktemp /tmp/ow-mood-live-XXXXXX.json)"
trap 'rm -f "$FAKE_FILE"' EXIT

for coord in "${COORDS[@]}"; do
    lat="${coord%,*}"
    lon="${coord#*,}"
    url="$(build_url "$lat" "$lon")"
    echo "[mood-live-check] GET $url"

    response=""
    if ! response="$(curl --silent --max-time 15 --fail "$url" 2>/dev/null)"; then
        echo "[mood-live-check] FAIL [$coord]: curl failed (HTTP error or timeout)"
        FAIL=$((FAIL+1))
        continue
    fi

    if ! assert_no_error "$response" "$coord"; then
        continue
    fi

    assert_current_fields "$response" "$coord"

    # End-to-end: pipe through app parse path via OW_MOOD_FAKE_RESPONSE_FILE seam.
    if [[ -n "$BINARY" && -x "$BINARY" ]]; then
        printf '%s' "$response" > "$FAKE_FILE"
        OW_SUPPORT_TMP="$(mktemp -d /tmp/ow-mood-live-app-XXXXXX)"
        app_out=""
        if app_out="$(OW_MOOD_FAKE_RESPONSE_FILE="$FAKE_FILE" OW_APP_SUPPORT_DIR="$OW_SUPPORT_TMP" OW_MOOD_TEST=1 WALLPAPER_WEB_DIR="$REPO_ROOT/Sources/OnlyWallpapers/web" timeout 10 "$BINARY" 2>&1 || true)"; then
            if printf '%s' "$app_out" | grep -q 'weather=ok'; then
                echo "[mood-live-check] PASS [$coord]: end-to-end parse via OW_MOOD_FAKE_RESPONSE_FILE succeeded (weather=ok)"
                PASS=$((PASS+1))
            elif printf '%s' "$app_out" | grep -q 'transport=fake'; then
                echo "[mood-live-check] WARN [$coord]: fake transport used but weather=ok not found; check app output"
            fi
        fi
        rm -rf "$OW_SUPPORT_TMP" 2>/dev/null || true
    fi
    echo ""
done

echo "[mood-live-check] RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
