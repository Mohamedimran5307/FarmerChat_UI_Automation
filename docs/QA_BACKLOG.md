# QA Backlog — FarmerChat Maestro suite

Items surfaced during the May 2026 QA audit that are **not yet addressed in code**. Closed items have been committed; this list is the live "still open" tracker.

Owner: QA. Last updated: 2026-05-21.

---

## P0 — blockers / false confidence

### 1. Phone number still in git history
- **What:** `7013733824` appears in `config/env.yaml` in commits `ad312fa` and earlier on `origin/main`. The newest commit moved it to a gitignored `env.local.yaml`, but historical commits remain readable on a public GitHub URL.
- **Why it matters:** Leaked PII / spam target. A determined visitor can `git log -p` and find it.
- **Options:**
  - **Rotate** the test phone with backend team and let history age out (lowest risk).
  - **`git filter-repo`** to rewrite history + force-push `origin/main`. Collaborators must re-clone. Destructive but truly scrubs the leak.

### 2. No negative-path coverage
- **What:** All 5 TCs are happy paths. No test for: offline → recovery (the "No internet" + Try again screen we saw during discovery), invalid OTP (wrong code → error toast), location permission denied, signup with a number already in use.
- **Why it matters:** A regression in an error UI ships silently — the happy path doesn't exercise it.
- **Suggested:** TC06 offline-recovery (drop wifi via adb, assert error UI, restore, assert recovery), TC07 invalid-OTP.

---

## P1 — flake-trust / operability

### 3. Locale-broken helpers
- **What:** `helpers/grant_location.yaml` lines 25, 28, 35, 51 use English `text:` selectors (`Get local farm advice`, `Share Location`, `While using the app`, `No thanks`). `helpers/dismiss_system_popup.yaml` similarly uses `Continue installation` / `Close`. Both silently degrade on non-English runs.
- **Why it matters:** Today the suite pins `LANGUAGE_CODE=en` in `config/env.yaml`, so it passes. The day someone runs `LANGUAGE_CODE=hi`, TC01/TC03 degrade to "tap weather button + hope". TC04 already has a `# requires: LANGUAGE_CODE=en` guard — helpers don't.
- **Suggested:** replace `text:` selectors with system-permission ids where possible (line 42 of `grant_location.yaml` already does this for the foreground-only button). For app-internal Share Location text, ask frontend for a `share_location_btn` testTag.

### 4. No CI integration
- **What:** Suite is run-on-demand by a human via `./run_tests.sh`. Five tests × ~80–110s each = ~10 min total.
- **Why it matters:** Coverage discipline depends on someone remembering. PRs to the FarmerChat app repo can ship UI breakage that this suite would catch.
- **Suggested:** GitHub Actions on the FarmerChat app repo, self-hosted Android runner (or Maestro Cloud — already supported by the MCP). Nightly is the minimum bar; per-PR if budget allows.

### 5. `dismiss_system_popup` background loop is heavy on OPPO
- **What:** `run_tests.sh:391–395` fires `uiautomator dump` 20 × 3s = 60s × every test × every retry on OPPO/realme. Each dump is ~500ms of foreground CPU on the device.
- **Why it matters:** On non-OPPO devices it's a fast `case` skip (cheap, already gated). On OPPO it's measurable load that can itself perturb the test it's protecting.
- **Suggested:** only fire when `am start` produced a `com.oplus.stdsp` window (single dump up front, gate the loop on that).

---

## P2 — code hygiene / observability

### 6. `complete_onboarding` short-circuit ignores overlaid permission dialog
- **What:** `helpers/complete_onboarding.yaml:7–14` exits the helper immediately when `home_screen` is visible. The system notification permission dialog overlays `home_screen` (we saw this during discovery), so on a rerun the dialog is left pending and the next tap (`home_hamburger_button` in TC05) sometimes misses.
- **Suggested:** before the short-circuit, dismiss any overlaid permission dialog.

### 7. `run_tests.sh` is a 922-line monolith
- **What:** Device detect + popup handler + retry logic + JSON gen + HTML gen + Drive upload all in one file.
- **Suggested:** split into `lib/device.sh`, `lib/maestro.sh`, `lib/report.sh`. Anyone touching one section currently has to load all 922 lines.

### 8. Stale `sleep`s in `run_tests.sh`
- `L297` `sleep 2` immediately before `wait_for_driver_port` — the wait already polls up to 10s. Remove.
- `L300` `sleep 3` after `am start` — replace with a `dumpsys window | grep mCurrentFocus` poll for `$APP_ID`. Faster on warm starts.
- `L193, L198` backgrounded `adb install` + `sleep 5; wait` is racy — `wait $!` on the specific install pid would be deterministic.

### 9. Flow `tags:` are decorative
- `regression`, `home`, `chat` etc. are declared in every TC's front-matter but `run_tests.sh` ignores them — it uses the positional comma TC-ID filter. Maestro CLI natively supports `--include-tags regression`.
- **Suggested:** add a `--tag` filter as an alternative second arg.

### 10. `priorities` (P0/P1) in `TEST_CASES` are decorative
- Shown in HTML, don't affect execution order, retry count, or failure threshold.
- **Suggested:** either implement (e.g., a P0 failure forces exit ≠ 0, P1 failure exits 0 with warning) or drop the field.

### 11. No assertion on AI answer content
- TC02/TC03/TC04 assert that some structural element rendered (`chat_suggested_questions`, `chat_listen_btn`) — proving the app rendered something but not that the answer is sensible. A backend returning "OK" for every prompt would pass all three.
- **Suggested:** soft check that `chat_screen` body contains ≥ N characters of text, or that a noun from the prompt ("sugarcane", "tomato") appears.

### 12. Auto-discovery sort order
- `flows/home/TC*_*.yaml` is globbed lexicographically. With zero-padded names (`TC01..TC05`) ordering is correct. If someone ever names a flow `TC9_*` or `TC10_*` without zero-padding, `TC10_*` sorts before `TC9_*` (and `TC2_*` sorts after `TC10_*`). Foot-gun.
- **Suggested:** keep zero-padding as a convention (document in CLAUDE.md), or change the sort key to natural-numeric.

### 13. `FarmerChat_Test_Setup_Guide.html` at repo root
- 38 KB tracked HTML at the root. Should move to `docs/`.

### 14. No retention policy on `reports/`
- 26 MB on disk locally, grows forever. Gitignored, but eats local disk for active users.
- **Suggested:** keep the last 20 runs, auto-prune older.

---

## P3 — strategic

### 15. Parallel device execution
- `maestro test` supports multi-device sharding; `run_tests.sh` doesn't. Not urgent at 5 tests, mandatory if the suite grows to 20+.

### 16. Test data factories
- Hardcoded `PHONE_NUMBER` means the auth account is shared across runs / testers. Hides backend race issues that surface with concurrent fresh accounts.
- **Suggested:** timestamp-suffix the phone (`70137338${timestamp%10000}`) when backend supports unique-per-run.

### 17. Performance budgets
- TC01 84s, TC04 104s. If a future regression pushes any TC to 200s, no alarm fires.
- **Suggested:** per-TC `# duration_budget: 120s` annotation; warn (or fail) when exceeded.

### 18. Upgrade scenarios
- No test for "user signed up → APK updated → flows still work". Migrations are silent.

---

## Recently closed (May 2026)

For context — items already fixed in commits `ad312fa..0d9c40d`:

- Tag migration to 20th-MAY APK (drawer_content → drawer_container, etc.)
- TC04 audio assertion via Listen/Pause/Play state machine (was a no-op)
- TC02 `^Ask$` regex → stable `chat_suggested_question_0` id
- `waitForAnimationToEnd` after trigger taps in TC02/TC04/TC05 (chat_text_input race)
- `env.yaml` split: secrets in gitignored `env.local.yaml`
- Auto-discovery of `TEST_CASES` from `flows/home/TC*_*.yaml`
- First-attempt pass rate + flake rate in summary and JSON
- `# requires: LANGUAGE_CODE=en` guard on TC04
- HTML failure rows now embed last debug screenshot
- README documents env.local.yaml setup + the en-only TC04 caveat
