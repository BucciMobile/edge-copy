# Behauptungsregister — Oura-SpO₂-PR (#8, Runde 11)

Format: ID | Aussage | Belegart | Ausschnitt der tatsächlichen Ausgabe.
Dieses Register ist der Beweisteil jeder Berichtsaussage; eine Aussage
ohne Eintrag ist unzulässig.

## Phase 1 — Basislinie

| ID | Aussage | Beleg | Ausgabe (Ausschnitt) |
|---|---|---|---|
| C01 | Start-HEAD ist e21aeee, Arbeitsbaum sauber auf dem Feature-Branch | `git rev-parse HEAD`, `git status` | `e21aeeee25eb47437d80d0348fa276dd6ba68106`, `## vibe/oura-spo2-historical-path-d6f8ca...origin/vibe/...` |
| C02 | Zwei SDKs installiert: 3.47.7 (Sandbox) und 3.41.6 (CI-Pin aus test.yml:47) | `flutter --version` je SDK | `Flutter 3.47.7 • ... 2026-10-08` / `Flutter 3.41.6 • ... 2026-03-25` |
| C03 | PR-Diff umfasst 26 Dateien, +4314/−56 | `git diff --stat origin/main...HEAD \| tail -1` | `26 files changed, 4314 insertions(+), 56 deletions(-)` |
| C04 | Der Commit e21aeee bewegte 7 Paketversionen im Lockfile, die Commit-Message behauptete das Gegenteil | `python3 tool/lock_diff.py origin/main` am Stand e21aeee | `changed: {'intl': ('0.20.2', '0.20.3'), 'matcher': ('0.12.19','0.12.20'), 'meta': ('1.17.0','1.19.0'), 'test': ('1.30.0','1.31.1'), 'test_api': ('0.7.10','0.7.12'), 'test_core': ('0.6.16','0.6.18'), 'vector_math': ('2.2.0','2.4.3')}` — **Fehler bestätigt** |
| C05 | pubspec.yaml (main) sagt: intl nicht unabhängig vom SDK driften | `grep -B2 intl pubspec.yaml` (main) | `# Pinned to what flutter_localizations (this SDK) requires ... intl: ^0.20.2` |
| C06 | **Fall 1**: mains Lockfile besteht `--enforce-lockfile` unter 3.41.6, scheitert unter 3.47.7 — der Drift ist ein 3.47.7-Auflösungsthema, kein PR-Fehler; der CI-Pin löst die Lockdatei beim pub get ohnehin (so) auf | `flutter pub get --enforce-lockfile` je SDK auf sauberem main-Checkout (/tmp/main_checkout @ 676fbca) | 3.41.6: `Got dependencies!` (exit 0) · 3.47.7: `Unable to satisfy pubspec.yaml using pubspec.lock ... Would change 7 dependencies. > intl 0.20.3 (was 0.20.2) ... > vector_math 2.4.3 (was 2.2.0)` (exit 65) |
| C07 | Nach Reset des Lockfiles auf main + `pub get` unter 3.41.6: **Exit 0** — nur die 6 erlaubten integration_test-Einträge kommen hinzu, 0 Versionssprünge | `python3 tool/lock_diff.py origin/main` | `changed: {} removed: [] added: ['flutter_driver','fuchsia_remote_debug_protocol','integration_test','process','sync_http','webdriver'] unexpected_added: []` (exit 0) |
| C08 | Unter 3.47.7 löst `pub get` die 7 Versionssprünge wieder ein (reproduziert C06) | `pub get` unter 3.47.7 dann lock_diff | `changed: {'intl': ...'vector_math': ...}` (exit 1) → danach erneut unter 3.41.6 aufgelöst → exit 0 |
| C09 | Bereinigtes Lockfile: analyze 0 issues unter 3.41.6, 47 SpO₂-Tests grün | `flutter analyze`, `flutter test test/oura_spo2_*` (3 Stück) unter 3.41.6 | `No issues found!` / `00:06 +47: All tests passed!` |
| C10 | pubspec.yaml-Diff gegen main enthält nur die integration_test-Dev-Dependency (plus Kommentar) | `git diff origin/main...HEAD -- pubspec.yaml` | nur `+ integration_test: sdk: flutter`-Block |

## Phase 2 — Pin-Warnung, Flake, übersprungene Tests

| ID | Aussage | Beleg | Ausgabe (Ausschnitt) |
|---|---|---|---|
| C11 | check_sibling_pins.sh: Branch und main identisch (exit 0 je), dieselben zwei Staleness-Warnungen | `bash .github/scripts/check_sibling_pins.sh` je Checkout; `diff` | `diff /tmp/pins_main.log /tmp/pins_branch.log` → `IDENTICAL`; wörtlich: `openstrap_protocol pinned at ecb512b…, lock agrees. ::warning:: … protocol's main has moved to 6e8c5705… ::warning:: Deliberate short lag is fine …` (und analog analytics 27b0ba4 → 458ba36) |
| C12 | Flake-Ursache: `syncForShortcut`'s `.then`-Callback ruft fire-and-forget `_deriveScheduler.markStoredData()` (lib/state/app_state.dart:5797); `_enqueue` läuft unawaited durch `LocalDb.enqueueDeriveJob`/`_refreshSnapshot` (derive_scheduler.dart:186-192, 265-268), während `app.dispose` (tearDown) die DB schließt → `DatabaseException(error database_closed)` aus `LocalDb.computeJobs` (db.dart:~10627) | Stack-Trace aus dem Fehlertext + Code-Lektüre | `DatabaseException(error database_closed) … LocalDb.computeJobs … DeriveScheduler._enqueue … DeriveScheduler.markStoredData … AppState.syncForShortcut.<fn> (app_state.dart 5797:48)` |
| C13 | Flake-Häufigkeit Branch: 20 Läufe → 14 Pass, 6 Fail; alle 6 Failures sind `database_closed` | 20× `flutter test test/app_state_shortcut_sync_test.dart` (Log /tmp/flake_branch.log) | `BRANCH RUN 20: pass=14 fail=6`; Detail-Lauf: `BRANCH-DB=6 OTHER=0` |
| C14 | Flake-Häufigkeit main: 20 Läufe → 19 Pass, 1 Fail; aufeinanderfolgender 10er-Detaillauf: 6× `database_closed` | 20× auf /tmp/main_checkout @ 676fbca (Log /tmp/flake_main.log) + 10er-Detaillauf | `MAIN RUN 20: pass=19 fail=1`; Detaillauf: `MAIN-DB=6 OTHER=0` — derselbe Fehler, dieselbe Ursache, präexistent |
| C15 | 462 übersprungene Tests (Suite unter 3.41.6), gegliedert nach Grund | Log-Auswertung /tmp/suite_3416_r2.log (~Zähler-Differenzen pro Datei) + `grep skip:` je Datei | Golden-Bilder fehlen lokal (212 ui2_golden, 108 ui2_home_health_golden, 88 ui2_onboarding_profile_golden, 31 ui2_activity — `_noGoldens`); Fixture-Dateien fehlen (16 series_codec `fixturesPresent?false`, 2 derivation_pipeline `skipNoFixture`); env-gated (1 cadence_group_c `OPENSTRAP_TEST_DBS`, 1 real_export_m5 `no real export DB`); 1 markTestSkipped wenn keine DST in der Laufzeit-Zone (day_timeline_test.dart:229); Rest (7) gleicht einzelne konditionale Skips in Goldens/UI-Tests aus |
| C16 | In den Pfaden dieses PR (test/oura_spo2_*, test/adapters/oura_spo2_*, health, db): kein übersprungener Test | `grep skip: test/oura_spo2* test/adapters/oura_spo2* test/health_* test/db_*` (nur Namensnennungen, keine skip-Annotation) | 0 `skip:`-Annotationen in diesen Dateien; einzige skip-Referenzen sind der String `'health_oura_spo2_skip:…'` (Marker-Name) |
