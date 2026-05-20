# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Maestro-based UI test suite for the FarmerChat Android app (`org.digitalgreen.farmer.chat`). There is no application code here — only YAML test flows, a Bash runner, and generated reports. No package manager, build system, or linter.

## Common commands

```bash
./setup_device.sh                       # One-time: extract Maestro APKs from ~/.maestro/lib and install on device
./run_tests.sh "Tester Name"            # Run the full TC01–TC05 suite; prompts for name if omitted
./run_tests.sh "Tester Name" TC03       # Run a single test through the runner (keeps setup/retries/reporting)
./run_tests.sh "Tester Name" TC01,TC03  # Run a comma-separated subset

# Run a single flow directly (bypasses the runner's setup, retries, popup loop, and reporting):
maestro --device <DEVICE_ID> test \
  --env APP_ID=org.digitalgreen.farmer.chat --env LANGUAGE_CODE=en --env USER_NAME="Test Farmer" \
  --env PHONE_NUMBER=7013733824 --env OTP_CODE=1111 --env WAIT_TIMEOUT=10000 \
  flows/home/TC02_ai_chat_experience.yaml
```

The second positional arg to `run_tests.sh` is a TC filter (parsed at `run_tests.sh:56`); use it instead of the raw `maestro test` form whenever you want the clean-state setup and retry recovery.

`run_tests.sh` requires a USB-connected device with debugging enabled, ADB on PATH, and Maestro CLI installed. It exits with the failure count.

## Architecture

**Test execution model.** Flows declare `appId: any` rather than the FarmerChat package. They never auto-launch the app — `run_tests.sh:setup_test()` does that explicitly via `am start --activity-clear-task`. This is deliberate: the runner first wipes app state (`run-as $APP_ID rm -rf shared_prefs/* files/* cache/* databases/*`) so each test starts from a clean install, then forwards `tcp:7001` (Maestro driver port) and waits for it to listen before launching the app and invoking `maestro test`.

**Helper composition.** Every flow in `flows/home/` begins with `runFlow: ../../helpers/complete_onboarding.yaml`, which is the canonical entry sequence: dismiss system popups → handle notification permission → skip privacy policy → run language picker (uses `language_item_${LANGUAGE_CODE}`) → enter `${USER_NAME}` if prompted → wait for `home_screen`. It is idempotent — if `home_screen` is already visible it short-circuits, so re-running flows on a logged-in device works. When adding a new flow, start with this same `runFlow` line; do not duplicate onboarding steps inline.

**Environment variables.** `config/env.yaml` documents the variables the flows reference (`${APP_ID}`, `${LANGUAGE_CODE}`, `${USER_NAME}`, `${PHONE_NUMBER}`, `${OTP_CODE}`, `${WAIT_TIMEOUT}`, etc.), but `run_tests.sh` does **not** load that file — it passes the same values via repeated `--env` flags in `run_test_attempt()`. If you add a new variable used by a flow, you must add it to **both** places, or it will be empty when the runner invokes Maestro.

**OEM popup handling.** Several Chinese OEMs (OPPO/realme `com.oplus.stdsp`) interrupt installs and app launches with extra confirmation dialogs that Maestro can't see. The runner has two layers for this:
1. `dismiss_system_popup()` parses `uiautomator dump` output and taps `Continue installation` / `btn_finish` / `btn_navigation_close` by extracted bounds, with hardcoded coordinate fallbacks tuned for a specific screen size.
2. During each test attempt a background loop calls `dismiss_system_popup` every 3s for up to 60s and is killed when the test finishes.

When debugging flakiness on a non-OPPO device, this whole machinery is a no-op (the `com.oplus.stdsp` check fails fast), so don't suspect it first.

**Retry and recovery.** Each test gets up to `MAX_RETRIES=2` (3 total attempts). Between attempts `reset_maestro_for_retry()` does a full `adb kill-server && adb start-server` and re-establishes the 7001 forward — this is needed because `driver did not start` and `Connection refused` errors leave the Maestro driver process and port forward in unrecoverable states. Don't replace this with a softer reset.

**Reports.** Every run writes both JSON and HTML to `reports/FarmerChat_TestReport_<tester>_<DDMMMYYYY>.{json,html}` and per-attempt logs to `reports/logs_<DATE>_<TIME>/`. The HTML is built by string-interpolating a heredoc inside `run_tests.sh` (no template files). If rclone is configured with a `gdrive:` remote, the JSON is uploaded to a hardcoded folder ID; otherwise the runner opens the Drive folder in a browser for manual upload. `reports/` is gitignored — never commit reports.

## Conventions when editing flows

- Use `id:` selectors over `text:` whenever the app exposes one (`home_screen`, `language_screen`, `name_input`, `language_item_${LANGUAGE_CODE}`, etc.) — text selectors break across language changes.
- Wrap conditional steps in `runFlow: { when: { visible: ... }, commands: [...] }` rather than relying on `optional: true` alone, so a missing element doesn't fail the test but a present-but-broken element still does.
- The flow filename prefix (`TC01_`, `TC02_`...) is parsed by `run_tests.sh` — the `TEST_CASES` array in the runner hardcodes IDs, filenames (without `.yaml`), names, descriptions, and priorities. Adding a new TC means editing both the flow and that array.
