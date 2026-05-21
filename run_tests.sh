#!/bin/bash
# =============================================================================
# MAESTRO STABLE TEST RUNNER
# Collects device info, runs tests, generates JSON report, uploads to Google Drive
# =============================================================================

# Don't exit on error - we handle errors with retry logic
# set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="$SCRIPT_DIR/reports"
DATE_STAMP=$(date +%d%b%Y)
TIME_STAMP=$(date +%H%M%S)

# ─────────────────────────────────────────────────────────────────────────────
# LOAD TEST CONFIG
# Reads config/env.yaml (committed defaults) then config/env.local.yaml
# (gitignored, holds secrets like PHONE_NUMBER / OTP_CODE). Keys defined
# in env.local.yaml override env.yaml. Parallel indexed arrays are used
# instead of `declare -A` so this works under macOS's default bash 3.2.
# ─────────────────────────────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/config/env.yaml"
ENV_LOCAL_FILE="$SCRIPT_DIR/config/env.local.yaml"
declare -a ENV_KEYS=()
declare -a ENV_VALUES=()
declare -a ENV_FLAGS=()

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found"
  exit 1
fi

env_set() {
  # Upsert a key→value pair into ENV_KEYS / ENV_VALUES. Later writes win.
  local key="$1" value="$2"
  local i
  for i in "${!ENV_KEYS[@]}"; do
    if [ "${ENV_KEYS[$i]}" = "$key" ]; then
      ENV_VALUES[$i]="$value"
      return
    fi
  done
  ENV_KEYS+=("$key")
  ENV_VALUES+=("$value")
}

load_env_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*):[[:space:]]*(.*)$ ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      value="${value%"${value##*[![:space:]]}"}"
      export "$key=$value"
      env_set "$key" "$value"
    fi
  done < "$file"
}

load_env_file "$ENV_FILE"
load_env_file "$ENV_LOCAL_FILE"   # overrides for any keys defined here

for i in "${!ENV_KEYS[@]}"; do
  ENV_FLAGS+=(--env "${ENV_KEYS[$i]}=${ENV_VALUES[$i]}")
done

# Warn (but don't fail) if secrets are missing — surfaces immediately
# instead of waiting for a flow to fail with unresolved ${PHONE_NUMBER}.
if [ ! -f "$ENV_LOCAL_FILE" ]; then
  echo "WARNING: $ENV_LOCAL_FILE not found — secrets (PHONE_NUMBER, OTP_CODE) will be unresolved."
  echo "  Copy config/env.local.example.yaml to config/env.local.yaml and fill in values."
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Create reports directory
mkdir -p "$REPORTS_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# GET TESTER NAME
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}           FARMERCHAT MAESTRO TEST SUITE${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Check if tester name is provided as argument or prompt
if [ -n "$1" ]; then
  TESTER_NAME="$1"
else
  echo -e "${CYAN}Enter your name (Tester Name):${NC} "
  read -r TESTER_NAME
  if [ -z "$TESTER_NAME" ]; then
    TESTER_NAME="Unknown_Tester"
  fi
fi
echo -e "Tester: ${YELLOW}$TESTER_NAME${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# OPTIONAL TC FILTER (second arg, comma-separated)
# Examples: ./run_tests.sh "Imran" TC03
#           ./run_tests.sh "Imran" TC01,TC03
# ─────────────────────────────────────────────────────────────────────────────
TC_FILTER="${2:-}"
if [ -n "$TC_FILTER" ]; then
  echo -e "Filter:  ${YELLOW}$TC_FILTER${NC}"
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# DETECT CONNECTED DEVICE
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}Detecting connected device...${NC}"

DEVICE_ID=$(adb devices | grep -v 'List' | grep 'device$' | head -1 | awk '{print $1}')

if [ -z "$DEVICE_ID" ]; then
  echo -e "${RED}ERROR: No Android device connected!${NC}"
  echo "Please connect a device via USB and enable USB debugging."
  exit 1
fi

echo -e "Device ID: ${YELLOW}$DEVICE_ID${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# COLLECT DEVICE INFORMATION
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}Collecting device information...${NC}"

DEVICE_MODEL=$(adb -s $DEVICE_ID shell getprop ro.product.model | tr -d '\r')
DEVICE_BRAND=$(adb -s $DEVICE_ID shell getprop ro.product.brand | tr -d '\r')
DEVICE_MANUFACTURER=$(adb -s $DEVICE_ID shell getprop ro.product.manufacturer | tr -d '\r')
ANDROID_VERSION=$(adb -s $DEVICE_ID shell getprop ro.build.version.release | tr -d '\r')
SDK_VERSION=$(adb -s $DEVICE_ID shell getprop ro.build.version.sdk | tr -d '\r')
DEVICE_NAME=$(adb -s $DEVICE_ID shell getprop ro.product.name | tr -d '\r')
BUILD_ID=$(adb -s $DEVICE_ID shell getprop ro.build.id | tr -d '\r')
SECURITY_PATCH=$(adb -s $DEVICE_ID shell getprop ro.build.version.security_patch | tr -d '\r')
DEVICE_SERIAL=$(adb -s $DEVICE_ID shell getprop ro.serialno | tr -d '\r')

# OEM popup loop only fires on OPPO/realme (com.oplus.stdsp). Gate it once so
# non-OPPO devices skip ~20 useless uiautomator dumps per test.
OEM_LOWER=$(echo "$DEVICE_MANUFACTURER $DEVICE_BRAND" | tr '[:upper:]' '[:lower:]')
case "$OEM_LOWER" in
  *oppo*|*realme*) POPUP_LOOP_ENABLED=1 ;;
  *) POPUP_LOOP_ENABLED=0 ;;
esac

echo -e "  Brand:           ${CYAN}$DEVICE_BRAND${NC}"
echo -e "  Model:           ${CYAN}$DEVICE_MODEL${NC}"
echo -e "  Android Version: ${CYAN}$ANDROID_VERSION (SDK $SDK_VERSION)${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# CLEAN UP STALE MAESTRO PROCESSES & FORWARDS
# Zombie CI jobs (e.g. self-hosted Actions targeting a missing emulator) and
# orphaned IDE MCP servers can pile up and squat on port 7001 / poison ADB.
# ─────────────────────────────────────────────────────────────────────────────
STALE_PIDS=$(pgrep -f 'maestro.cli.AppKt' 2>/dev/null || true)
if [ -n "$STALE_PIDS" ]; then
  STALE_COUNT=$(echo "$STALE_PIDS" | wc -l | tr -d ' ')
  echo -e "${YELLOW}Cleaning up $STALE_COUNT stale Maestro JVM(s)...${NC}"
  pkill -9 -f 'maestro.cli.AppKt' 2>/dev/null || true
  sleep 1
  echo -e "  ${GREEN}✓ Stale processes terminated${NC}"
fi
adb -s "$DEVICE_ID" forward --remove-all 2>/dev/null || true
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# DISABLE ADB VERIFICATION (for devices with app verification)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}Configuring device for testing...${NC}"
adb -s $DEVICE_ID shell settings put global verifier_verify_adb_installs 0 2>/dev/null || true
adb -s $DEVICE_ID shell settings put global package_verifier_enable 0 2>/dev/null || true
echo -e "  ${GREEN}✓ ADB verification disabled${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# ENSURE MAESTRO APKS ARE INSTALLED
# ─────────────────────────────────────────────────────────────────────────────
ensure_maestro_installed() {
  local MAESTRO_APP=$(adb -s $DEVICE_ID shell pm list packages 2>/dev/null | grep "dev.mobile.maestro$" || true)
  local MAESTRO_TEST=$(adb -s $DEVICE_ID shell pm list packages 2>/dev/null | grep "dev.mobile.maestro.test" || true)

  local REASON=""
  if [ -z "$MAESTRO_APP" ] || [ -z "$MAESTRO_TEST" ]; then
    REASON="missing"
  else
    # Version-mismatch check. Maestro driver APKs share a fixed versionCode
    # across releases, so we can't compare versions directly. Instead compare
    # the bundled jar's mtime to the on-device lastUpdateTime — if the jar is
    # newer (i.e. Maestro CLI was upgraded after the driver was installed),
    # the client/driver proto generations will diverge and gRPC will close
    # the channel with "UNAVAILABLE" / "tcp:7001 closed". Reinstall to match.
    local JAR_PATH="$HOME/.maestro/lib/maestro-client.jar"
    if [ -f "$JAR_PATH" ]; then
      local JAR_MTIME=$(stat -f %m "$JAR_PATH" 2>/dev/null || stat -c %Y "$JAR_PATH" 2>/dev/null)
      local INSTALL_TIME_STR=$(adb -s $DEVICE_ID shell 'dumpsys package dev.mobile.maestro 2>/dev/null' | grep 'lastUpdateTime' | head -1 | sed 's/.*lastUpdateTime=//' | tr -d '\r')
      if [ -n "$JAR_MTIME" ] && [ -n "$INSTALL_TIME_STR" ]; then
        local INSTALL_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S" "$INSTALL_TIME_STR" "+%s" 2>/dev/null || date -d "$INSTALL_TIME_STR" "+%s" 2>/dev/null)
        if [ -n "$INSTALL_EPOCH" ] && [ "$JAR_MTIME" -gt "$INSTALL_EPOCH" ]; then
          REASON="stale"
        fi
      fi
    fi
  fi

  if [ -n "$REASON" ]; then
    if [ "$REASON" = "stale" ]; then
      echo -e "  ${YELLOW}Driver APKs are older than Maestro CLI — refreshing...${NC}"
      adb -s $DEVICE_ID shell am force-stop dev.mobile.maestro 2>/dev/null || true
      adb -s $DEVICE_ID shell am force-stop dev.mobile.maestro.test 2>/dev/null || true
    else
      echo -e "  ${YELLOW}Installing Maestro driver APKs...${NC}"
    fi
    cd /tmp
    unzip -o ~/.maestro/lib/maestro-client.jar maestro-app.apk maestro-server.apk 2>/dev/null || true
    # On "stale" we always reinstall both; on "missing" only the absent one.
    if [ -z "$MAESTRO_APP" ] || [ "$REASON" = "stale" ]; then
      adb -s $DEVICE_ID install -r -g /tmp/maestro-app.apk &>/dev/null &
      sleep 5
      wait 2>/dev/null || true
    fi
    if [ -z "$MAESTRO_TEST" ] || [ "$REASON" = "stale" ]; then
      adb -s $DEVICE_ID install -r -g /tmp/maestro-server.apk &>/dev/null &
      sleep 5
      wait 2>/dev/null || true
    fi
    cd - >/dev/null
    echo -e "  ${GREEN}✓ Maestro APKs installed${NC}"
  else
    echo -e "  ${GREEN}✓ Maestro APKs already installed and up to date${NC}"
  fi
}

ensure_maestro_installed
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# DISMISS SYSTEM POPUP FUNCTION
# ─────────────────────────────────────────────────────────────────────────────
dismiss_system_popup() {
  for attempt in 1 2 3 4; do
    adb -s $DEVICE_ID shell uiautomator dump /sdcard/ui_check.xml >/dev/null 2>&1
    local ui_dump=$(adb -s $DEVICE_ID shell cat /sdcard/ui_check.xml 2>/dev/null)
    
    if echo "$ui_dump" | grep -q "com.oplus.stdsp"; then
      if echo "$ui_dump" | grep -q "Continue installation"; then
        # Try clicking by text, fall back to coordinate
        local bounds=$(echo "$ui_dump" | grep -o 'text="Continue installation"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1)
        if [ -n "$bounds" ]; then
          local x1=$(echo "$bounds" | grep -o '\[[0-9]*,' | head -1 | tr -d '[,')
          local y1=$(echo "$bounds" | grep -o ',[0-9]*\]' | head -1 | tr -d ',]')
          local x2=$(echo "$bounds" | grep -o '\[[0-9]*,' | tail -1 | tr -d '[,')
          local y2=$(echo "$bounds" | grep -o ',[0-9]*\]' | tail -1 | tr -d ',]')
          local cx=$(( (x1 + x2) / 2 ))
          local cy=$(( (y1 + y2) / 2 ))
          adb -s $DEVICE_ID shell input tap $cx $cy 2>/dev/null
        else
          adb -s $DEVICE_ID shell input tap 360 1192 2>/dev/null
        fi
        sleep 3
      elif echo "$ui_dump" | grep -q "btn_finish"; then
        local bounds=$(echo "$ui_dump" | grep -o 'resource-id="[^"]*btn_finish"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1)
        if [ -n "$bounds" ]; then
          local x1=$(echo "$bounds" | grep -o '\[[0-9]*,' | head -1 | tr -d '[,')
          local y1=$(echo "$bounds" | grep -o ',[0-9]*\]' | head -1 | tr -d ',]')
          local x2=$(echo "$bounds" | grep -o '\[[0-9]*,' | tail -1 | tr -d '[,')
          local y2=$(echo "$bounds" | grep -o ',[0-9]*\]' | tail -1 | tr -d ',]')
          local cx=$(( (x1 + x2) / 2 ))
          local cy=$(( (y1 + y2) / 2 ))
          adb -s $DEVICE_ID shell input tap $cx $cy 2>/dev/null
        else
          adb -s $DEVICE_ID shell input tap 360 1312 2>/dev/null
        fi
        sleep 1
      elif echo "$ui_dump" | grep -q "btn_navigation_close"; then
        local bounds=$(echo "$ui_dump" | grep -o 'resource-id="[^"]*btn_navigation_close"[^>]*bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"' | head -1)
        if [ -n "$bounds" ]; then
          local x1=$(echo "$bounds" | grep -o '\[[0-9]*,' | head -1 | tr -d '[,')
          local y1=$(echo "$bounds" | grep -o ',[0-9]*\]' | head -1 | tr -d ',]')
          local x2=$(echo "$bounds" | grep -o '\[[0-9]*,' | tail -1 | tr -d '[,')
          local y2=$(echo "$bounds" | grep -o ',[0-9]*\]' | tail -1 | tr -d ',]')
          local cx=$(( (x1 + x2) / 2 ))
          local cy=$(( (y1 + y2) / 2 ))
          adb -s $DEVICE_ID shell input tap $cx $cy 2>/dev/null
        else
          adb -s $DEVICE_ID shell input tap 73 130 2>/dev/null
        fi
        sleep 1
      fi
    else
      break
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# SETUP TEST FUNCTION
# ─────────────────────────────────────────────────────────────────────────────
# Wait until the Maestro driver port is listening on the device.
# 7001 in hex = 1B59; appears in /proc/net/tcp when the driver service is up.
# Returns 0 on success, 1 on timeout (10s max).
wait_for_driver_port() {
  local PORT_RETRIES=0
  while [ $PORT_RETRIES -lt 5 ]; do
    if adb -s $DEVICE_ID shell "cat /proc/net/tcp" 2>/dev/null | grep -qi "1B59"; then
      return 0
    fi
    PORT_RETRIES=$((PORT_RETRIES + 1))
    sleep 2
  done
  return 1
}

setup_test() {
  # Keep the screen on and unlocked — long AI-response waits (30–90s) would
  # otherwise hit the OEM screen-lock and surface as "Element not found".
  adb -s $DEVICE_ID shell svc power stayon true 2>/dev/null || true
  adb -s $DEVICE_ID shell input keyevent KEYCODE_WAKEUP 2>/dev/null || true

  adb -s $DEVICE_ID shell am force-stop $APP_ID 2>/dev/null
  adb -s $DEVICE_ID shell "run-as $APP_ID sh -c 'rm -rf shared_prefs/* files/* cache/* databases/*'" 2>/dev/null || true
  adb -s $DEVICE_ID forward tcp:7001 tcp:7001 2>/dev/null
  sleep 2
  wait_for_driver_port
  adb -s $DEVICE_ID shell am start --activity-clear-task -n $APP_ID/org.digitalgreen.farmer.chatbot.MainActivity 2>/dev/null
  sleep 3
  [ "$POPUP_LOOP_ENABLED" = "1" ] && dismiss_system_popup
}

# ─────────────────────────────────────────────────────────────────────────────
# DISCOVER TEST CASES from flows/home/TC*_*.yaml
# Each TC entry is built from the YAML front-matter:
#   `name:`          → display name (required; fallback = filename)
#   `# priority:`    → P0/P1/P2 comment in front-matter (default P1)
#   `# description:` → comment in front-matter (default = name minus prefix)
# Sorted by filename so TC01 runs before TC02 etc. Adding a new TC means
# dropping a TC<NN>_<slug>.yaml into flows/home/ — no edit here needed.
# Format kept identical to the old hardcoded array: TC_ID|FILE|NAME|DESC|PRIO
# ─────────────────────────────────────────────────────────────────────────────
declare -a TEST_CASES=()
for tc_path in "$SCRIPT_DIR"/flows/home/TC*_*.yaml; do
  [ -f "$tc_path" ] || continue
  tc_file=$(basename "$tc_path" .yaml)
  # TC_ID = leading "TC" + digits, e.g. TC01, TC10
  if [[ "$tc_file" =~ ^(TC[0-9]+) ]]; then
    tc_id="${BASH_REMATCH[1]}"
  else
    continue
  fi

  tc_name=""
  tc_priority=""
  tc_desc=""

  # Read front-matter only (stop at `---`).
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" = "---" ] && break
    if [[ -z "$tc_name" && "$line" =~ ^name:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$ ]]; then
      tc_name="${BASH_REMATCH[1]}"
    elif [[ -z "$tc_priority" && "$line" =~ ^\#[[:space:]]*priority:[[:space:]]*([A-Z0-9]+)[[:space:]]*$ ]]; then
      tc_priority="${BASH_REMATCH[1]}"
    elif [[ -z "$tc_desc" && "$line" =~ ^\#[[:space:]]*description:[[:space:]]*(.*)$ ]]; then
      tc_desc="${BASH_REMATCH[1]}"
    fi
  done < "$tc_path"

  [ -z "$tc_name" ]     && tc_name="$tc_file"
  [ -z "$tc_priority" ] && tc_priority="P1"
  # If no `# description:` comment, fall back to the name stripped of its
  # "TC## - " prefix so reports still get something readable.
  if [ -z "$tc_desc" ]; then
    tc_desc=$(echo "$tc_name" | sed -E 's/^TC[0-9]+[[:space:]]*-[[:space:]]*//')
  fi
  # Strip "TC## - " from the displayed name too so the runner's progress
  # column stays narrow (matches the old hand-curated names).
  display_name=$(echo "$tc_name" | sed -E 's/^TC[0-9]+[[:space:]]*-[[:space:]]*//')

  TEST_CASES+=("${tc_id}|${tc_file}|${display_name}|${tc_desc}|${tc_priority}")
done

if [ ${#TEST_CASES[@]} -eq 0 ]; then
  echo -e "${RED}ERROR: No test cases discovered under flows/home/${NC}"
  echo "  Expected files matching: flows/home/TC<NN>_*.yaml"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# APPLY TC FILTER (if provided)
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "$TC_FILTER" ]; then
  IFS=',' read -ra REQUESTED_TCS <<< "$TC_FILTER"
  declare -a FILTERED=()
  for test_case in "${TEST_CASES[@]}"; do
    IFS='|' read -r TC_ID _REST <<< "$test_case"
    for req in "${REQUESTED_TCS[@]}"; do
      # Trim whitespace
      req="${req#"${req%%[![:space:]]*}"}"
      req="${req%"${req##*[![:space:]]}"}"
      if [ "$TC_ID" = "$req" ]; then
        FILTERED+=("$test_case")
        break
      fi
    done
  done
  if [ ${#FILTERED[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No matching test cases for filter '$TC_FILTER'${NC}"
    available_ids=""
    for tc in "${TEST_CASES[@]}"; do
      IFS='|' read -r aid _ <<< "$tc"
      available_ids="${available_ids:+$available_ids, }$aid"
    done
    echo "Available: $available_ids"
    exit 1
  fi
  TEST_CASES=("${FILTERED[@]}")
fi
TOTAL_COUNT=${#TEST_CASES[@]}

# ─────────────────────────────────────────────────────────────────────────────
# RUN TESTS
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                    RUNNING TEST CASES${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Create logs directory for this run
RUN_LOGS_DIR="$REPORTS_DIR/logs_${DATE_STAMP}_${TIME_STAMP}"
mkdir -p "$RUN_LOGS_DIR"

# Master log file
MASTER_LOG="$RUN_LOGS_DIR/run.log"
echo "FarmerChat Test Run - $(date)" > "$MASTER_LOG"
echo "Device: $DEVICE_ID ($DEVICE_BRAND $DEVICE_MODEL, Android $ANDROID_VERSION)" >> "$MASTER_LOG"
echo "Tester: $TESTER_NAME" >> "$MASTER_LOG"
echo "═══════════════════════════════════════════════════════════════" >> "$MASTER_LOG"

# Show logs directory
echo -e "${CYAN}Logs directory:${NC} $RUN_LOGS_DIR"
echo -e "${CYAN}Master log:${NC} $MASTER_LOG"
echo ""

# Maximum retry attempts (2 retries = 3 total attempts)
MAX_RETRIES=2

TOTAL=0
PASSED=0
FAILED=0
# FIRST_ATTEMPT_PASSED counts tests that passed without any retry.
# (PASSED - FIRST_ATTEMPT_PASSED) = tests that flaked and only passed on
# retry — useful signal that something is unstable even when totals are
# green. Surfaced in the summary + JSON for trend tracking.
FIRST_ATTEMPT_PASSED=0
TEST_RESULTS=""
declare -a TEST_STATUS_ARRAY=()
START_TIME=$(date +%s)

# ─────────────────────────────────────────────────────────────────────────────
# RUN SINGLE TEST ATTEMPT
# ─────────────────────────────────────────────────────────────────────────────
run_test_attempt() {
  local TC_FILE="$1"
  local ATTEMPT_NUM="$2"
  
  TEST_LOG_FILE="$RUN_LOGS_DIR/${TC_FILE}_attempt${ATTEMPT_NUM}.log"
  
  setup_test >/dev/null 2>&1

  local POPUP_PID=""
  if [ "$POPUP_LOOP_ENABLED" = "1" ]; then
    (
      for i in $(seq 1 20); do
        sleep 3
        dismiss_system_popup 2>/dev/null
      done
    ) &
    POPUP_PID=$!
  fi

  local DEBUG_DIR="$RUN_LOGS_DIR/${TC_FILE}_attempt${ATTEMPT_NUM}_debug"
  local TEST_START=$(date +%s)
  TEST_OUTPUT=$(maestro --device $DEVICE_ID test \
    --debug-output "$DEBUG_DIR" \
    "${ENV_FLAGS[@]}" \
    "$SCRIPT_DIR/flows/home/${TC_FILE}.yaml" 2>&1)

  TEST_EXIT_CODE=$?
  local TEST_END=$(date +%s)
  TEST_DURATION=$((TEST_END - TEST_START))

  if [ -n "$POPUP_PID" ]; then
    kill $POPUP_PID 2>/dev/null || true
    wait $POPUP_PID 2>/dev/null || true
  fi
  
  {
    echo "═══════════════════════════════════════════════════════════════"
    echo "Test: $TC_FILE (Attempt $ATTEMPT_NUM)"
    echo "Device: $DEVICE_ID"
    echo "Duration: ${TEST_DURATION}s"
    echo "Exit Code: $TEST_EXIT_CODE"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "$TEST_OUTPUT"
  } > "$TEST_LOG_FILE"
  
  echo "[$(date '+%H:%M:%S')] $TC_FILE attempt $ATTEMPT_NUM: exit_code=$TEST_EXIT_CODE, duration=${TEST_DURATION}s" >> "$MASTER_LOG"
  
  return $TEST_EXIT_CODE
}

# ─────────────────────────────────────────────────────────────────────────────
# SHOW FAILURE DETAILS
# ─────────────────────────────────────────────────────────────────────────────
show_failure_details() {
  local OUTPUT="$1"
  local LOG_FILE="$2"
  
  echo ""
  echo -e "  ${RED}━━━ FAILURE DETAILS ━━━${NC}"
  
  if echo "$OUTPUT" | grep -q "driver did not start"; then
    echo -e "  ${YELLOW}Type:${NC}  Driver Timeout"
    echo -e "  ${MAGENTA}Error:${NC} Maestro Android driver did not start up in time"
    echo -e "  ${CYAN}Hint:${NC}  Run: adb kill-server && adb start-server"
  elif echo "$OUTPUT" | grep -q "Connection refused"; then
    echo -e "  ${YELLOW}Type:${NC}  Connection Error"
    echo -e "  ${MAGENTA}Error:${NC} Connection refused on port 7001"
    echo -e "  ${CYAN}Hint:${NC}  Run: adb forward tcp:7001 tcp:7001"
  elif echo "$OUTPUT" | grep -q "Element not found"; then
    local FAILED_STEP=$(echo "$OUTPUT" | grep "FAILED" | head -1)
    local ELEMENT_ERROR=$(echo "$OUTPUT" | grep "Element not found" | head -1)
    echo -e "  ${YELLOW}Type:${NC}  Element Not Found"
    [ -n "$FAILED_STEP" ] && echo -e "  ${YELLOW}Step:${NC}  $FAILED_STEP"
    echo -e "  ${MAGENTA}Error:${NC} $ELEMENT_ERROR"
    echo -e "  ${CYAN}Hint:${NC}  Element may not be visible or selector may be incorrect"
  elif echo "$OUTPUT" | grep -q "FAILED"; then
    local FAILED_STEP=$(echo "$OUTPUT" | grep "FAILED" | head -1)
    echo -e "  ${YELLOW}Type:${NC}  Test Step Failed"
    echo -e "  ${YELLOW}Step:${NC}  $FAILED_STEP"
    echo -e "  ${CYAN}Hint:${NC}  Check the full log for more details"
  else
    echo -e "  ${YELLOW}Type:${NC}  Unknown Error"
    echo -e "  ${CYAN}Hint:${NC}  Check the full log for more details"
  fi
  
  [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] && echo -e "  ${CYAN}Full log:${NC} $LOG_FILE"
  
  echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# RESET MAESTRO CONNECTION (for retry)
# ─────────────────────────────────────────────────────────────────────────────
reset_maestro_for_retry() {
  adb -s $DEVICE_ID shell am force-stop dev.mobile.maestro 2>/dev/null || true
  adb -s $DEVICE_ID shell am force-stop dev.mobile.maestro.test 2>/dev/null || true
  adb -s $DEVICE_ID forward --remove tcp:7001 2>/dev/null || true
  # Full ADB reset to recover from driver timeouts and connection refused errors
  adb kill-server 2>/dev/null || true
  sleep 2
  adb start-server 2>/dev/null || true
  sleep 3
  adb -s $DEVICE_ID forward tcp:7001 tcp:7001 >/dev/null 2>&1
  # Self-heal mid-run regressions: driver APKs auto-uninstalled by
  # MIUI/ColorOS cleanup, or drifted out of sync after a host-side
  # Maestro CLI upgrade. The function is cheap when nothing's wrong
  # (a pm-list + jar-mtime check), so safe to call on every retry.
  ensure_maestro_installed
  # Poll for driver readiness instead of a blind sleep — exits early on
  # clean recovery, waits up to 10s on slow recovery.
  wait_for_driver_port || true
}

for test_case in "${TEST_CASES[@]}"; do
  IFS='|' read -r TC_ID TC_FILE TC_NAME TC_DESC TC_PRIORITY <<< "$test_case"
  TOTAL=$((TOTAL + 1))
  
  ATTEMPT=1
  TEST_PASSED=false
  FINAL_OUTPUT=""
  FINAL_DURATION=0
  FINAL_LOG_FILE=""
  RETRY_INFO=""
  
  while [ $ATTEMPT -le $((MAX_RETRIES + 1)) ] && [ "$TEST_PASSED" = "false" ]; do
    echo -ne "\r"
    printf "${YELLOW}[%d/%d]${NC} %-35s " "$TOTAL" "$TOTAL_COUNT" "$TC_NAME"
    if [ $ATTEMPT -eq 1 ]; then
      echo -ne "${BLUE}RUNNING...${NC}"
    else
      echo -ne "${BLUE}RETRY $((ATTEMPT-1))/${MAX_RETRIES}...${NC}"
    fi
    
    run_test_attempt "$TC_FILE" "$ATTEMPT"
    
    if [ $TEST_EXIT_CODE -eq 0 ]; then
      TEST_PASSED=true
      FINAL_OUTPUT="$TEST_OUTPUT"
      FINAL_DURATION=$TEST_DURATION
      FINAL_LOG_FILE="$TEST_LOG_FILE"
      if [ $ATTEMPT -eq 1 ]; then
        FIRST_ATTEMPT_PASSED=$((FIRST_ATTEMPT_PASSED + 1))
      else
        RETRY_INFO=" ${CYAN}(passed on retry $((ATTEMPT-1)))${NC}"
      fi
    else
      FINAL_OUTPUT="$TEST_OUTPUT"
      FINAL_DURATION=$TEST_DURATION
      FINAL_LOG_FILE="$TEST_LOG_FILE"
      
      if [ $ATTEMPT -le $MAX_RETRIES ]; then
        echo -ne "\r"
        printf "${YELLOW}[%d/%d]${NC} %-35s " "$TOTAL" "$TOTAL_COUNT" "$TC_NAME"
        echo -e "${YELLOW}⟳ ATTEMPT $ATTEMPT FAILED${NC} (${TEST_DURATION}s) - retrying..."
        show_failure_details "$TEST_OUTPUT" "$TEST_LOG_FILE"
        reset_maestro_for_retry
      fi
      
      ATTEMPT=$((ATTEMPT + 1))
    fi
  done
  
  echo -ne "\r"
  printf "${YELLOW}[%d/%d]${NC} %-35s " "$TOTAL" "$TOTAL_COUNT" "$TC_NAME"
  
  if [ "$TEST_PASSED" = "true" ]; then
    STATUS="PASSED"
    PASSED=$((PASSED + 1))
    TEST_STATUS_ARRAY+=("PASSED")
    echo -e "${GREEN}✓ PASSED${NC} (${FINAL_DURATION}s)${RETRY_INFO}"
    ERROR_MESSAGE=""
  else
    STATUS="FAILED"
    FAILED=$((FAILED + 1))
    TEST_STATUS_ARRAY+=("FAILED")
    echo -e "${RED}✗ FAILED${NC} (${FINAL_DURATION}s) ${YELLOW}(after $MAX_RETRIES retries)${NC}"
    # Escape backslashes first (\ → \\) so paths like C:\... or regex \d
    # in the failure output don't produce invalid JSON.
    ERROR_MESSAGE=$(echo "$FINAL_OUTPUT" | grep -A 2 "FAILED" | head -3 | tr '\n' ' ' | sed 's/\\/\\\\/g' | tr '"' "'" | sed 's/[[:cntrl:]]//g')
    show_failure_details "$FINAL_OUTPUT" "$FINAL_LOG_FILE"
  fi
  
  OUTPUT="$FINAL_OUTPUT"
  
  if [ -n "$TEST_RESULTS" ]; then
    TEST_RESULTS="$TEST_RESULTS,"
  fi
  
  if [ $FINAL_DURATION -ge 60 ]; then
    DURATION_FRIENDLY="$((FINAL_DURATION / 60))m $((FINAL_DURATION % 60))s"
  else
    DURATION_FRIENDLY="${FINAL_DURATION}s"
  fi
  
  if [ "$STATUS" = "PASSED" ]; then
    STATUS_DISPLAY="✓ Passed"
  else
    STATUS_DISPLAY="✗ Failed"
  fi
  
  TEST_RESULTS="$TEST_RESULTS
    {
      \"tc\": \"$TC_ID\",
      \"name\": \"$TC_NAME\",
      \"description\": \"$TC_DESC\",
      \"status\": \"$STATUS\",
      \"priority\": \"$TC_PRIORITY\",
      \"time_taken\": \"$DURATION_FRIENDLY\",
      \"issue\": \"$ERROR_MESSAGE\"
    }"
done

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
MINS=$((TOTAL_DURATION / 60))
SECS=$((TOTAL_DURATION % 60))

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE JSON REPORT (Stakeholder-friendly format)
# ─────────────────────────────────────────────────────────────────────────────
REPORT_FILE="$REPORTS_DIR/FarmerChat_TestReport_${TESTER_NAME// /_}_${DATE_STAMP}.json"
RUN_DATE_FRIENDLY=$(date +"%d %B %Y")
RUN_TIME_FRIENDLY=$(date +"%I:%M %p IST")
TIMESTAMP_FRIENDLY="$RUN_DATE_FRIENDLY, $RUN_TIME_FRIENDLY"

# Compute derived counters once, here — both the JSON and the terminal
# summary below read these. (Previously FLAKED was computed in the summary
# block AFTER the JSON heredoc ran, leaving "flaked": , in the report.)
FLAKED=$((PASSED - FIRST_ATTEMPT_PASSED))
if [ "$TOTAL" -gt 0 ]; then
  PASS_RATE_INT=$(echo "scale=0; $PASSED * 100 / $TOTAL" | bc)
  FLAKE_RATE_INT=$(echo "scale=0; $FLAKED * 100 / $TOTAL" | bc)
else
  PASS_RATE_INT=0
  FLAKE_RATE_INT=0
fi

cat > "$REPORT_FILE" << EOF
{
  "testSuite": "FarmerChat Core Scenarios",

  "summary": {
    "total": $TOTAL,
    "passed": $PASSED,
    "failed": $FAILED,
    "first_attempt_passed": $FIRST_ATTEMPT_PASSED,
    "flaked": $FLAKED,
    "pass_rate": "${PASS_RATE_INT}%",
    "flake_rate": "${FLAKE_RATE_INT}%"
  },

  "device": {
    "manufacturer": "$DEVICE_BRAND",
    "model": "$DEVICE_MODEL",
    "android_version": "$ANDROID_VERSION"
  },

  "tester": "$TESTER_NAME",
  "timestamp": "$TIMESTAMP_FRIENDLY",

  "testCases": [$TEST_RESULTS
  ]
}
EOF

# ─────────────────────────────────────────────────────────────────────────────
# GENERATE HTML REPORT
# ─────────────────────────────────────────────────────────────────────────────
HTML_REPORT_FILE="$REPORTS_DIR/FarmerChat_TestReport_${TESTER_NAME// /_}_${DATE_STAMP}.html"
PASS_RATE=$(echo "scale=0; $PASSED * 100 / $TOTAL" | bc)

# Determine overall status color
if [ $FAILED -eq 0 ]; then
  STATUS_COLOR="#4caf50"
  STATUS_BG="#e8f5e9"
  STATUS_TEXT="ALL TESTS PASSED"
else
  STATUS_COLOR="#f44336"
  STATUS_BG="#ffebee"
  STATUS_TEXT="$FAILED TEST(S) FAILED"
fi

# Build test cases HTML
TEST_CASES_HTML=""
TC_INDEX=0
for test_case in "${TEST_CASES[@]}"; do
  IFS='|' read -r TC_ID TC_FILE TC_NAME TC_DESC TC_PRIORITY <<< "$test_case"
  
  # Use actual recorded status for each test case
  if [ "${TEST_STATUS_ARRAY[$TC_INDEX]}" = "PASSED" ]; then
    TC_STATUS="PASSED"
    TC_STATUS_COLOR="#4caf50"
    TC_STATUS_BG="#e8f5e9"
    TC_ICON="✓"
  else
    TC_STATUS="FAILED"
    TC_STATUS_COLOR="#f44336"
    TC_STATUS_BG="#ffebee"
    TC_ICON="✗"
  fi
  TC_INDEX=$((TC_INDEX + 1))
  
  TEST_CASES_HTML="$TEST_CASES_HTML
    <tr>
      <td style='font-weight: 600; color: #2e7d32;'>$TC_ID</td>
      <td>$TC_NAME</td>
      <td style='color: #666; font-size: 13px;'>$TC_DESC</td>
      <td><span style='background: ${TC_STATUS_BG}; color: ${TC_STATUS_COLOR}; padding: 4px 12px; border-radius: 12px; font-size: 12px; font-weight: 600;'>$TC_ICON $TC_STATUS</span></td>
      <td><span style='background: #fff3e0; color: #e65100; padding: 4px 10px; border-radius: 12px; font-size: 11px; font-weight: 600;'>$TC_PRIORITY</span></td>
    </tr>"
done

cat > "$HTML_REPORT_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>FarmerChat Test Report - $TESTER_NAME - $RUN_DATE_FRIENDLY</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif; background: #f5f5f5; line-height: 1.6; }
        .container { max-width: 1000px; margin: 0 auto; background: white; box-shadow: 0 2px 20px rgba(0,0,0,0.1); }
        
        /* Header */
        .header { background: linear-gradient(135deg, #2e7d32 0%, #4caf50 50%, #81c784 100%); color: white; padding: 40px; text-align: center; }
        .header h1 { font-size: 28px; margin-bottom: 8px; }
        .header .subtitle { opacity: 0.9; font-size: 14px; }
        .header .timestamp { margin-top: 15px; font-size: 13px; opacity: 0.8; }
        
        /* Status Banner */
        .status-banner { background: ${STATUS_BG}; border-left: 5px solid ${STATUS_COLOR}; padding: 20px 40px; display: flex; align-items: center; justify-content: space-between; }
        .status-banner .status { font-size: 20px; font-weight: 700; color: ${STATUS_COLOR}; }
        .status-banner .pass-rate { font-size: 36px; font-weight: 700; color: ${STATUS_COLOR}; }
        
        /* Content */
        .content { padding: 40px; }
        
        /* Info Cards */
        .info-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin-bottom: 40px; }
        .info-card { background: #fafafa; border-radius: 12px; padding: 24px; border: 1px solid #e0e0e0; }
        .info-card h3 { font-size: 12px; text-transform: uppercase; color: #888; letter-spacing: 1px; margin-bottom: 15px; }
        .info-card .item { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #eee; }
        .info-card .item:last-child { border-bottom: none; }
        .info-card .label { color: #666; font-size: 14px; }
        .info-card .value { font-weight: 600; color: #333; font-size: 14px; }
        
        /* Summary Stats */
        .stats-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 20px; margin-bottom: 40px; }
        .stat-card { text-align: center; padding: 24px; border-radius: 12px; }
        .stat-card.total { background: #e3f2fd; }
        .stat-card.passed { background: #e8f5e9; }
        .stat-card.failed { background: #ffebee; }
        .stat-card.duration { background: #fff3e0; }
        .stat-card .number { font-size: 42px; font-weight: 700; }
        .stat-card.total .number { color: #1976d2; }
        .stat-card.passed .number { color: #4caf50; }
        .stat-card.failed .number { color: #f44336; }
        .stat-card.duration .number { color: #ff9800; font-size: 28px; }
        .stat-card .label { font-size: 13px; color: #666; text-transform: uppercase; letter-spacing: 1px; margin-top: 8px; }
        
        /* Test Results Table */
        .section-title { font-size: 18px; color: #2e7d32; margin-bottom: 20px; padding-bottom: 10px; border-bottom: 2px solid #4caf50; }
        table { width: 100%; border-collapse: collapse; margin-bottom: 30px; }
        th { background: linear-gradient(135deg, #2e7d32, #4caf50); color: white; padding: 14px 16px; text-align: left; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; }
        td { padding: 16px; border-bottom: 1px solid #eee; vertical-align: middle; }
        tr:hover { background: #f9f9f9; }
        
        /* Footer */
        .footer { background: #263238; color: white; padding: 25px 40px; text-align: center; font-size: 13px; }
        .footer a { color: #81c784; text-decoration: none; }
        
        @media print {
            body { background: white; }
            .container { box-shadow: none; }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🌾 FarmerChat Test Report</h1>
            <p class="subtitle">Automated UI Test Results - Core Scenarios</p>
            <p class="timestamp">$TIMESTAMP_FRIENDLY</p>
        </div>
        
        <div class="status-banner">
            <div class="status">$STATUS_TEXT</div>
            <div class="pass-rate">${PASS_RATE}%</div>
        </div>
        
        <div class="content">
            <!-- Info Cards -->
            <div class="info-grid">
                <div class="info-card">
                    <h3>👤 Tester Info</h3>
                    <div class="item"><span class="label">Name</span><span class="value">$TESTER_NAME</span></div>
                    <div class="item"><span class="label">Date</span><span class="value">$RUN_DATE_FRIENDLY</span></div>
                    <div class="item"><span class="label">Time</span><span class="value">$RUN_TIME_FRIENDLY</span></div>
                </div>
                <div class="info-card">
                    <h3>📱 Device Info</h3>
                    <div class="item"><span class="label">Brand</span><span class="value">$DEVICE_BRAND</span></div>
                    <div class="item"><span class="label">Model</span><span class="value">$DEVICE_MODEL</span></div>
                    <div class="item"><span class="label">Android</span><span class="value">$ANDROID_VERSION (SDK $SDK_VERSION)</span></div>
                </div>
                <div class="info-card">
                    <h3>📦 App Under Test</h3>
                    <div class="item"><span class="label">App</span><span class="value">FarmerChat</span></div>
                    <div class="item"><span class="label">Package</span><span class="value" style="font-size: 11px;">$APP_ID</span></div>
                    <div class="item"><span class="label">Build</span><span class="value">$BUILD_ID</span></div>
                </div>
            </div>
            
            <!-- Stats -->
            <div class="stats-grid">
                <div class="stat-card total">
                    <div class="number">$TOTAL</div>
                    <div class="label">Total Tests</div>
                </div>
                <div class="stat-card passed">
                    <div class="number">$PASSED</div>
                    <div class="label">Passed</div>
                </div>
                <div class="stat-card failed">
                    <div class="number">$FAILED</div>
                    <div class="label">Failed</div>
                </div>
                <div class="stat-card duration">
                    <div class="number">${MINS}m ${SECS}s</div>
                    <div class="label">Duration</div>
                </div>
            </div>
            
            <!-- Test Results -->
            <h2 class="section-title">Test Case Results</h2>
            <table>
                <thead>
                    <tr>
                        <th style="width: 10%;">ID</th>
                        <th style="width: 20%;">Test Case</th>
                        <th style="width: 40%;">Description</th>
                        <th style="width: 15%;">Status</th>
                        <th style="width: 15%;">Priority</th>
                    </tr>
                </thead>
                <tbody>
                    $TEST_CASES_HTML
                </tbody>
            </table>
        </div>
        
        <div class="footer">
            <p>Generated by FarmerChat Maestro Test Suite</p>
            <p style="margin-top: 5px; opacity: 0.7;">Repository: <a href="https://github.com/Mohamedimran5307/FarmerChat_Core_scenarios">github.com/Mohamedimran5307/FarmerChat_Core_scenarios</a></p>
        </div>
    </div>
</body>
</html>
HTMLEOF

echo -e "${GREEN}✓ HTML Report generated: ${CYAN}$HTML_REPORT_FILE${NC}"

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                    TEST RESULTS SUMMARY${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Tester:     ${CYAN}$TESTER_NAME${NC}"
echo -e "  Device:     ${CYAN}$DEVICE_BRAND $DEVICE_MODEL${NC}"
echo -e "  Android:    ${CYAN}$ANDROID_VERSION (SDK $SDK_VERSION)${NC}"
echo ""
echo -e "  Total:      ${YELLOW}$TOTAL${NC}"
echo -e "  Passed:     ${GREEN}$PASSED${NC} (${FIRST_ATTEMPT_PASSED} on first attempt, ${FLAKED} after retry)"
echo -e "  Failed:     ${RED}$FAILED${NC}"
echo -e "  Pass Rate:  ${CYAN}${PASS_RATE_INT}%${NC}"
if [ "$FLAKED" -gt 0 ]; then
  echo -e "  Flake Rate: ${YELLOW}${FLAKE_RATE_INT}%${NC} (${FLAKED}/${TOTAL} needed a retry)"
else
  echo -e "  Flake Rate: ${GREEN}${FLAKE_RATE_INT}%${NC}"
fi
echo -e "  Duration:   ${YELLOW}${MINS}m ${SECS}s${NC}"
echo ""
echo -e "  ${CYAN}Logs:${NC}         $RUN_LOGS_DIR"
echo -e "  ${CYAN}JSON Report:${NC}  $REPORT_FILE"
echo -e "  ${CYAN}HTML Report:${NC}  $HTML_REPORT_FILE"
echo ""

# Write summary to master log
{
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "TEST RUN SUMMARY"
  echo "═══════════════════════════════════════════════════════════════"
  echo "Total: $TOTAL | Passed: $PASSED ($FIRST_ATTEMPT_PASSED first-attempt) | Failed: $FAILED"
  echo "Pass Rate: ${PASS_RATE_INT}%"
  echo "Flake Rate: ${FLAKE_RATE_INT}% ($FLAKED needed retry)"
  echo "Duration: ${MINS}m ${SECS}s"
  echo "Completed: $(date)"
} >> "$MASTER_LOG"

# ─────────────────────────────────────────────────────────────────────────────
# UPLOAD TO GOOGLE DRIVE
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                  UPLOADING TO GOOGLE DRIVE${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# Google Drive folder ID for FarmerChat test reports
GDRIVE_FOLDER_ID="1CsIXNd7CFD-NWFzpPU4guoCbjVj-1s9Y"
GDRIVE_FOLDER_URL="https://drive.google.com/drive/folders/$GDRIVE_FOLDER_ID"

# Check if rclone is configured
if command -v rclone &> /dev/null; then
  # Check if gdrive remote exists
  if rclone listremotes | grep -q "gdrive:"; then
    echo -e "${YELLOW}Uploading JSON report to Google Drive...${NC}"
    rclone copy "$REPORT_FILE" "gdrive:" --drive-root-folder-id="$GDRIVE_FOLDER_ID" && \
      echo -e "${GREEN}✓ JSON report uploaded successfully!${NC}" && \
      echo -e "  View at: ${CYAN}$GDRIVE_FOLDER_URL${NC}" || \
      echo -e "${RED}✗ Failed to upload report${NC}"
  else
    echo -e "${YELLOW}rclone is installed but not configured for Google Drive.${NC}"
    echo ""
    echo "Run this command to configure Google Drive access:"
    echo -e "  ${CYAN}rclone config${NC}"
    echo ""
    echo "Then choose:"
    echo "  - n (new remote)"
    echo "  - Name: gdrive"
    echo "  - Storage: drive (Google Drive)"
    echo "  - Follow the prompts to authenticate"
    echo ""
    echo -e "After setup, run tests again to auto-upload."
    echo ""
    echo -e "${YELLOW}Opening Google Drive for manual upload...${NC}"
    if [ "$(uname)" = "Darwin" ]; then
      open "$GDRIVE_FOLDER_URL"
    elif [ "$(uname)" = "Linux" ]; then
      xdg-open "$GDRIVE_FOLDER_URL" 2>/dev/null
    fi
    echo -e "Report file: ${CYAN}$REPORT_FILE${NC}"
  fi
else
  echo -e "${YELLOW}rclone not installed.${NC}"
  echo ""
  echo "Install rclone for automatic uploads:"
  echo -e "  ${CYAN}brew install rclone${NC}  (macOS)"
  echo -e "  ${CYAN}curl https://rclone.org/install.sh | sudo bash${NC}  (Linux)"
  echo ""
  echo -e "${YELLOW}Opening Google Drive for manual upload...${NC}"
  if [ "$(uname)" = "Darwin" ]; then
    open "$GDRIVE_FOLDER_URL"
  elif [ "$(uname)" = "Linux" ]; then
    xdg-open "$GDRIVE_FOLDER_URL" 2>/dev/null
  fi
  echo -e "Report file: ${CYAN}$REPORT_FILE${NC}"
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                    TEST RUN COMPLETE${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""

exit $FAILED