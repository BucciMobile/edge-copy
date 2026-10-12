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
