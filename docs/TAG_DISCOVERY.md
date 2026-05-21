
## Onboarding skipped on fresh install
After tapping `language_start_button` (English), the app landed directly on `home_screen`. No notification-permission prompt, no privacy-policy screen, no name input, no location interstitial were shown. Implication: those steps in `helpers/complete_onboarding.yaml` should be wrapped in `optional`/`when:visible` (they may still appear for some locales or signup paths).

## Home screen (`home_screen`)
- `home_screen` — same
- `home_feed_list` — new (the scrolling feed)
- `home_hamburger_button` — same
- `home_weather_button` — same
- `home_feed_header` — new (the "For your farm today" header)
- `primary_input_photo_btn` — new
- `primary_input_speak_btn` — new
- `primary_input_type_btn` — same  *(TC02 selector still valid)*
- `home_feed_card_<UUID>` — new per-card id (UUID changes each load)
- `content_card_start_chat_btn` — new (the "Learn More" button on each feed card)

### Renames vs. old flows
- `home_type_button` (TC04 line 11) → `primary_input_type_btn`
- `chat_read_full_advice_button` (TC03 line 33,38,41) → `content_card_start_chat_btn` *(needs confirmation by tapping it)*

## Drawer (sliding panel from `home_hamburger_button`)
- `drawer_container` — new *(was `drawer_content` in `helpers/open_drawer.yaml:8`)*
- `drawer_home_btn` — new
- `drawer_language_btn` — new
- `drawer_settings_btn` — new *(was `drawer_settings_button` — TC05, `helpers/navigate_to_settings.yaml:7,10`)*
- `drawer_help_btn` — new
- `drawer_signup_card` — new (wrapper around the signup CTA at the bottom)
- `drawer_signup_btn` — new *(was `drawer_signup_button` — TC05:12,15,18)*

## Notification permission
Standard Android system dialog (`com.android.permissioncontroller:id/permission_allow_button`) — same selector as today.

## Settings (`settings_screen`) — logged-out state
- `settings_screen` — same
- `appbar_default_left_btn` — new (top-bar back chevron, also used on other inner screens)
- `settings_btn_appearance_day` / `_night` / `_auto` — new (theme toggle)
- `settings_name_edit_row` — new (Your name row)
- `settings_btn_auth` — new (shows "Sign up" while logged out; expected to flip to "Log out" once signed in — to be confirmed)

⚠ `settings_logout_button` from old TC05:76 not present in logged-out state. Likely lives behind sign-in; will confirm after signup.

## Auth / signup flow
**Phone entry (`auth_screen`)**
- `auth_screen` — new (wrapper for the auth flow; both phone + OTP share it)
- `auth_country_code_btn` — new (+91 selector)
- `auth_phone_input` — same
- `auth_send_sms_btn` — new *(was `auth_submit_button` in TC05:46 for the first submit)*

**OTP entry (still `auth_screen`)**
- `auth_otp_input` — same
- `auth_verify_btn` — new *(was the second `auth_submit_button` usage in TC05; verify CTA)*

**Account success (`account_success_screen`)**
- `account_success_screen` — same
- `account_success_btn_continue` — new *(was `account_success_continue` in TC05:53)*

## Settings (`settings_screen`) — logged-in state (after signup)
- `settings_btn_auth` — same tag as logged-out, but text flips to "Logout". *No separate `settings_logout_button` tag — the old TC05 selector `settings_logout_button` should be replaced with `settings_btn_auth`.*
- `settings_name_edit_row` — same; now shows the user's name (e.g. "Imran khan") in the value cell.

### Logout
Tapping `settings_btn_auth` (when logged in) lands directly on `language_screen` — matches the existing TC05 assertion.

## Chat input bar (overlaid on `home_screen` after tapping `primary_input_type_btn`)
- `chat_camera_btn` — new
- `chat_text_input` — new *(EditText with hint "Ask about your farm…"; was probably `text_input_send_button` confusion — `text_input_send_button` from TC04:16,19 no longer exists in this form)*
- `chat_voice_btn` — new

## Chat answer (`chat_screen`) — after `chat_send_btn`
- `chat_screen` — new (top-level wrapper; no `chat_thread_list` tag exists — old TC02:46, TC03:44, TC04:23,41 used `chat_thread_list`, which is gone. Use `chat_screen` for assertVisible instead.)
- `appbar_logo_left_btn` — new (top-left "X" close button)
- `chat_listen_btn` — new *(was `chat_listen_button` in TC04:28,33,36,38,41)*
- `chat_share_btn` — new
- `chat_save_btn` — new
- `chat_suggested_questions` — same — appears at the bottom of the answer

### Streaming → answered state
`primary_input_photo_btn` / `_speak_btn` / `_type_btn` always render at the bottom of `chat_screen`. The input bar (with `chat_text_input` + `chat_send_btn`) is only visible briefly while typing.

## Content card on home feed
- `content_card_start_chat_btn` is the new tag for the "Learn More" CTA inside each `home_feed_card_<UUID>`. *(Replaces `chat_read_full_advice_button` from old TC03:33,38,41.)*

---

# Consolidated old → new map

| Old selector | New selector | Where used |
| --- | --- | --- |
| `drawer_content` | `drawer_container` | helpers/open_drawer.yaml |
| `drawer_settings_button` | `drawer_settings_btn` | TC05, helpers/navigate_to_settings.yaml |
| `drawer_signup_button` | `drawer_signup_btn` | TC05 |
| `settings_logout_button` | `settings_btn_auth` | TC05 (text label flips Sign up ↔ Logout) |
| `auth_submit_button` | `auth_send_sms_btn` (phone) then `auth_verify_btn` (OTP) | TC05 |
| `account_success_continue` | `account_success_btn_continue` | TC05 |
| `home_type_button` | `primary_input_type_btn` | TC04 |
| `text_input_send_button` | `chat_send_btn` | TC04 |
| `chat_listen_button` | `chat_listen_btn` | TC04 |
| `chat_read_full_advice_button` | `content_card_start_chat_btn` (on home feed card) | TC03 |
| `chat_thread_list` | `chat_screen` (assertVisible only — no list rid) | TC02, TC03, TC04 |

Unchanged (verified live):
`language_screen`, `language_item_<code>`, `language_start_button`, `home_screen`, `home_hamburger_button`, `home_weather_button`, `primary_input_type_btn`, `chat_send_btn`, `auth_phone_input`, `auth_otp_input`, `account_success_screen`, `settings_screen`, `chat_suggested_questions`, system permission tags.

Removed from current first-launch flow (now skipped — wrap in `optional`/`when:visible`):
`name_input`, `name_save_button`, `location_interstitial_skip`, the "Privacy Policy" intro screen, "Skip for now" overlay.
