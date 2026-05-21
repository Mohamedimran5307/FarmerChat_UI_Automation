# FarmerChat Maestro Test Suite

Automated UI test suite for the FarmerChat Android application using Maestro framework. Supports multiple Android device manufacturers.

## Quick Start for Testers

### Prerequisites

1. **Android Device** connected via USB with USB Debugging enabled
2. **ADB** installed and accessible from command line
3. **Maestro CLI** installed: 
   ```bash
   curl -Ls "https://get.maestro.mobile.dev" | bash
   ```
4. **FarmerChat APK** installed on the device

### Running Tests

1. **Clone the repository:**
   ```bash
   git clone https://github.com/Mohamedimran5307/FarmerChat_Core_scenarios.git
   cd FarmerChat_Core_scenarios
   ```

2. **Set up local secrets** (one-time):
   ```bash
   cp config/env.local.example.yaml config/env.local.yaml
   # then edit config/env.local.yaml with real PHONE_NUMBER / OTP_CODE
   ```
   `config/env.local.yaml` is gitignored. The runner loads it on top of
   `config/env.yaml` so its values override the committed defaults.

3. **Run the test suite:**
   ```bash
   ./run_tests.sh
   ```
   
   Or with your name + a filter:
   ```bash
   ./run_tests.sh "Your Name"            # full TC01–TC05 suite
   ./run_tests.sh "Your Name" TC03       # just TC03
   ./run_tests.sh "Your Name" TC01,TC03  # comma-separated subset
   ```

4. **View Results** - JSON + HTML reports land in `reports/`. The
   terminal summary calls out `Passed: N (X on first attempt, Y after
   retry)` and a `Flake Rate` line so silent retries are visible.

   Every attempt is recorded as an mp4 via `adb shell screenrecord`
   (capped at 180s per Android's own limit; ~3 MB / minute at 4 Mbps).
   The HTML report adds a collapsible `📹 Recordings` link per TC
   pointing at the local mp4 file under `reports/logs_<run>/`. To skip
   recording (e.g. on a low-disk machine):
   ```bash
   RECORD_DISABLED=1 ./run_tests.sh "Your Name"
   ```

---

## Key Test Scenarios (Execution Order 1-5)

| ID | Name | Description |
|----|------|-------------|
| TC01 | Location-Based Personalization | Ensures the app captures user GPS via the weather widget and displays relevant image questions and content cards based on location |
| TC02 | AI Chat Experience | Validates that users can ask farming-related questions and receive AI-generated responses along with suggested follow-up questions |
| TC03 | Home Feed Usability | Confirms that users can smoothly scroll through the home feed and access all content cards without issues |
| TC04 | Audio Response Feature | Ensures users can listen to AI responses using the text-to-speech feature |
| TC05 | User Authentication & Logout | Verifies complete user flow including sign-up, login, and logout functionality |

---

## Google Drive Upload Setup

### Option 1: Using rclone (Recommended)

1. **Install rclone:**
   ```bash
   # macOS
   brew install rclone
   
   # Linux
   curl https://rclone.org/install.sh | sudo bash
   ```

2. **Configure Google Drive:**
   ```bash
   rclone config
   ```
   - Choose `n` for new remote
   - Name it `gdrive`
   - Choose `drive` (Google Drive)
   - Follow OAuth prompts

3. **Run tests** - Reports will auto-upload to `gdrive:FarmerChat_Test_Reports/`

### Option 2: Using gdrive CLI

1. **Install gdrive:**
   ```bash
   # macOS
   brew install gdrive
   
   # Linux
   # Download from https://github.com/glotlabs/gdrive/releases
   ```

2. **Authenticate:**
   ```bash
   gdrive account add
   ```

3. **Set folder ID (optional):**
   ```bash
   export GDRIVE_FOLDER_ID="your-folder-id-here"
   ```

### Option 3: Manual Upload

If no CLI tool is installed, the script will:
- Generate the JSON report locally in `reports/`
- Prompt you to open Google Drive for manual upload

---

## JSON Report Format

```json
{
  "testSuite": "FarmerChat Core Scenarios",

  "summary": {
    "total": 5,
    "passed": 5,
    "failed": 0,
    "pass_rate": "100%"
  },

  "device": {
    "manufacturer": "Samsung",
    "model": "Galaxy A54",
    "android_version": "14"
  },

  "tester": "Imran",
  "timestamp": "14 April 2026, 02:30 PM IST",

  "testCases": [
    {
      "tc": "TC01",
      "name": "Location-Based Personalization",
      "description": "Ensures the app captures user GPS via the weather widget and displays relevant image questions and content cards based on location",
      "status": "PASSED",
      "priority": "P0",
      "time_taken": "1m 42s",
      "issue": ""
    },
    {
      "tc": "TC02",
      "name": "AI Chat Experience",
      "description": "Validates that users can ask farming-related questions and receive AI-generated responses along with suggested follow-up questions",
      "status": "PASSED",
      "priority": "P0",
      "time_taken": "2m 57s",
      "issue": ""
    },
    {
      "tc": "TC03",
      "name": "Home Feed Usability",
      "description": "Confirms that users can smoothly scroll through the home feed and access all content cards without issues",
      "status": "PASSED",
      "priority": "P1",
      "time_taken": "1m 45s",
      "issue": ""
    },
    {
      "tc": "TC04",
      "name": "Audio Response Feature",
      "description": "Ensures users can listen to AI responses using the text-to-speech feature",
      "status": "PASSED",
      "priority": "P0",
      "time_taken": "2m 33s",
      "issue": ""
    },
    {
      "tc": "TC05",
      "name": "User Authentication & Logout",
      "description": "Verifies complete user flow including sign-up, login, and logout functionality",
      "status": "PASSED",
      "priority": "P0",
      "time_taken": "2m 24s",
      "issue": ""
    }
  ]
}
```

---

## Project Structure

```
maestro-stable/
├── run_tests.sh              # Main test runner script
├── setup_device.sh           # One-time device setup for Maestro APKs
├── config/
│   └── env.yaml              # Environment variables
├── flows/
│   └── home/
│       ├── TC01_location_based_personalization.yaml
│       ├── TC02_ai_chat_experience.yaml
│       ├── TC03_home_feed_usability.yaml
│       ├── TC04_audio_response_feature.yaml
│       └── TC05_user_authentication_logout.yaml
├── helpers/
│   ├── complete_onboarding.yaml
│   ├── dismiss_system_popup.yaml
│   ├── open_drawer.yaml
│   └── navigate_to_settings.yaml
└── reports/                  # Generated test reports (gitignored)
```

---

## Troubleshooting

### "No Android device connected"
- Ensure USB Debugging is enabled on device
- Run `adb devices` to verify connection
- Try `adb kill-server && adb start-server`

### System Installation Popup
- The script automatically handles device manufacturer app verification popups
- If stuck, manually tap "Continue installation" then "Close"

### Maestro Connection Issues
- Run `./setup_device.sh` to manually install Maestro APKs
- Ensure device screen is unlocked during tests

### Tests Timing Out
- Check device has stable internet connection
- Ensure FarmerChat app is installed and working

---

## Environment Variables

The runner reads two YAML files in order:
1. `config/env.yaml` — committed defaults (no secrets)
2. `config/env.local.yaml` — gitignored, overrides the defaults. Holds
   `PHONE_NUMBER`, `OTP_CODE`, and anything else you don't want in git.
   Template: `config/env.local.example.yaml`.

Both files use a simple `KEY: VALUE` format. Every parsed key is exported
to the shell and passed to `maestro` via `--env`.

| Variable | Where defined | Default | Description |
|----------|---------------|---------|-------------|
| `APP_ID` | env.yaml | `org.digitalgreen.farmer.chat` | App package name |
| `LANGUAGE_CODE` | env.yaml | `en` | Language to pick during onboarding. **TC04 currently asserts on English accessibility strings ("Listen"/"Pause"/"Play") — running TC04 with any other code will fail.** |
| `USER_NAME` | env.yaml | `Test Farmer` | Name typed if the legacy name screen appears |
| `WAIT_TIMEOUT` | env.yaml | `10000` | Default timeout (ms) for waits |
| `PHONE_NUMBER` | **env.local.yaml** | — | Real phone for TC05 signup |
| `OTP_CODE` | **env.local.yaml** | — | Test OTP for TC05 verify |
| `GDRIVE_FOLDER_ID` | shell | (none) | Google Drive folder ID for uploads |
| `RCLONE_REMOTE` | shell | `gdrive` | rclone remote name |

---

## Support

For issues or questions, contact the QA team or raise an issue in this repository.
