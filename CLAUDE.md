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

**Helper composition.** Every flow in `flows/home/` begins with `runFlow: ../../helpers/complete_onboarding.yaml`. The current canonical entry sequence on the 20th-MAY APK is: dismiss OEM installer popups → wait for `language_screen` → tap `language_item_${LANGUAGE_CODE}` → tap `language_start_button` → wait up to 8s for the post-language notification permission dialog and grant it → land on `home_screen`. The helper short-circuits when `home_screen` is already visible (idempotent rerun). It also keeps four `when: visible:`-guarded steps for the older "Allow" text fallback, `"Skip for now"` overlay, `name_input`/`name_save_button` name-entry screen, and `location_interstitial_skip` — these are gated by a Firebase remote config flag on the backend and may reappear on any build at any time, so the guards must stay. When adding a new flow, start with this same `runFlow` line; do not duplicate onboarding steps inline.

**Environment variables.** `config/env.yaml` is the single source of truth. `run_tests.sh` parses it at startup (`ENV_FLAGS` block near the top), exports each `KEY: VALUE` line as both a shell variable and a `--env KEY=VALUE` flag passed to Maestro. To add a new variable used by a flow, add it to `config/env.yaml` only — no runner edit needed. The parser is a bash regex that matches `^[A-Z_][A-Z0-9_]*:` so keys must be uppercase + underscores.

**OEM popup handling.** Several Chinese OEMs (OPPO/realme `com.oplus.stdsp`) interrupt installs and app launches with extra confirmation dialogs that Maestro can't see. The runner has two layers for this:
1. `dismiss_system_popup()` parses `uiautomator dump` output and taps `Continue installation` / `btn_finish` / `btn_navigation_close` by extracted bounds, with hardcoded coordinate fallbacks tuned for a specific screen size.
2. During each test attempt a background loop calls `dismiss_system_popup` every 3s for up to 60s and is killed when the test finishes.

When debugging flakiness on a non-OPPO device, this whole machinery is a no-op (the `com.oplus.stdsp` check fails fast), so don't suspect it first.

**Retry and recovery.** Each test gets up to `MAX_RETRIES=2` (3 total attempts). Between attempts `reset_maestro_for_retry()` does a full `adb kill-server && adb start-server` and re-establishes the 7001 forward — this is needed because `driver did not start` and `Connection refused` errors leave the Maestro driver process and port forward in unrecoverable states. Don't replace this with a softer reset.

**Reports.** Every run writes both JSON and HTML to `reports/FarmerChat_TestReport_<tester>_<DDMMMYYYY>.{json,html}` and per-attempt logs to `reports/logs_<DATE>_<TIME>/`. The HTML is built by string-interpolating a heredoc inside `run_tests.sh` (no template files). If rclone is configured with a `gdrive:` remote, the JSON is uploaded to a hardcoded folder ID; otherwise the runner opens the Drive folder in a browser for manual upload. `reports/` is gitignored — never commit reports.

## Conventions when editing flows

- Use `id:` selectors over `text:` whenever the app exposes one (`home_screen`, `language_screen`, `chat_screen`, `language_item_${LANGUAGE_CODE}`, etc.) — text selectors break across language changes.
- Wrap conditional steps in `runFlow: { when: { visible: ... }, commands: [...] }` rather than relying on `optional: true` alone, so a missing element doesn't fail the test but a present-but-broken element still does.
- The flow filename prefix (`TC01_`, `TC02_`...) is parsed by `run_tests.sh` — the `TEST_CASES` array in the runner hardcodes IDs, filenames (without `.yaml`), names, descriptions, and priorities. Adding a new TC means editing both the flow and that array.
- Before tapping a button that can render near the system nav bar (`content_card_start_chat_btn`, `chat_listen_btn`, `chat_suggested_questions` items), wrap it in `scrollUntilVisible … centerElement: true`. Without centering, Maestro's tap can land on the OS Home key and send the app to background — this regressed once already (commit `3502503`).
- Maestro's `text:` matcher is **regex**. Anchor exact-match selectors: use `^Ask$` so a tap doesn't also match the composer hint `"Ask about your farm…"`.
- Don't add `extendedWaitUntil` on `chat_screen` as a "wait for AI response" — the wrapper renders the instant the user lands and the wait is a 0-second no-op. Use a `scrollUntilVisible` to an end-of-answer marker (`chat_suggested_questions`, `chat_listen_btn`) with a long timeout instead; that's the implicit wait.

## App testTag map (20th-MAY APK, v4.0.2)

Full discovery notes with screen-by-screen output live in `docs/TAG_DISCOVERY.md`. Quick reference for tags the flows depend on:

| Screen | Tag | Notes |
| --- | --- | --- |
| Language | `language_screen`, `language_item_<code>`, `language_start_button`, `language_list`, `language_all_languages_chip`, `language_legal_text`, `language_logo_mark` | First launch and post-logout entry. No separate privacy-policy screen — legal text is inline. |
| Home | `home_screen`, `home_feed_list`, `home_hamburger_button`, `home_weather_button`, `home_feed_header`, `home_feed_card_<UUID>`, `content_card_start_chat_btn` | `primary_input_photo_btn` / `primary_input_speak_btn` / `primary_input_type_btn` render at the bottom of the home screen but collapse to a sticky-top row as soon as the feed scrolls — `home_feed_header` ends up partially occluded under the sticky row, so don't use it as a "top of feed" assertion. `home_hamburger_button` and `home_weather_button` only render at the expanded top and unmount once the feed scrolls, which makes them clean top-of-feed witnesses (use `scrollUntilVisible: home_hamburger_button` to return to top). Profile-prompt cards like `home_feed_card_gender` can be toggled off via a backend feature flag, so don't rely on them in tests. Content cards have UUID-suffixed ids (`home_feed_card_<UUID>`) that change every load; to open a card's chat, target the contained `content_card_start_chat_btn`. |
| Chat input bar (overlay after `primary_input_type_btn`) | `chat_camera_btn`, `chat_text_input`, `chat_voice_btn`, `chat_send_btn` | `chat_send_btn` only appears once `chat_text_input` has non-empty text. |
| Chat answer (`chat_screen`) | `chat_screen`, `appbar_logo_left_btn`, `chat_listen_btn`, `chat_share_btn`, `chat_save_btn`, `chat_suggested_questions` | `chat_screen` is the always-visible wrapper. Use `chat_suggested_questions` (or `chat_share_btn`) as the answer-finished signal. `chat_listen_btn` is gated on TTS being available for the active language and may not render — prefer `chat_share_btn` for unconditional action-row checks. No `chat_thread_list` tag exists. |
| Feed-card chat (`chat_screen`, opened from `content_card_start_chat_btn`) | `chat_screen`, `chat_read_full_advice_btn`, `chat_suggested_questions` | Card-initiated chats render a preview variant of the answer with a single `chat_read_full_advice_btn` ("Read full advice") instead of the listen/share/save action row. Use `chat_read_full_advice_btn` as the action-row check on this code path. |
| Drawer | `drawer_container`, `drawer_home_btn`, `drawer_language_btn`, `drawer_settings_btn`, `drawer_help_btn`, `drawer_signup_card`, `drawer_signup_btn` | Slide-in from `home_hamburger_button`. |
| Settings | `settings_screen`, `appbar_default_left_btn`, `settings_btn_appearance_day` / `_night` / `_auto`, `settings_name_edit_row`, `settings_btn_auth` | `settings_btn_auth` is the same tag for **Sign up** and **Logout** — text flips with auth state. There is no separate `settings_logout_button`. |
| Auth (`auth_screen`) | `auth_screen`, `auth_country_code_btn`, `auth_phone_input`, `auth_send_sms_btn`, `auth_otp_input`, `auth_verify_btn` | Phone step uses `auth_send_sms_btn`; OTP step uses `auth_verify_btn`. Both used to be a single `auth_submit_button` — keep them split or the flow taps the wrong one. |
| Account success | `account_success_screen`, `account_success_btn_continue` | |

### Conditionally rendered (Firebase-gated)
The 20th-MAY APK in its current default config does **not** show the privacy-policy screen, an `"Allow"`-text notification dialog, a `"Skip for now"` overlay, a name-entry screen (`name_input` / `name_save_button`), or a location-interstitial (`location_interstitial_skip`). However, these screens are toggleable via a Firebase remote config flag from the backend, so any build can surface them at any time — the corresponding `when: visible:`-guarded blocks live in `helpers/complete_onboarding.yaml` and must remain there. Removing them would silently break tests the moment the flag flips on.
