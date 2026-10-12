# Oura SpO₂: iPhone-Gerätetest der HealthKit-Skala (A2)

Zweck: der entscheidende Nachweis, dass der SpO₂-Wert auf iOS in der
richtigen Größenordnung in Apple Health landet. HealthKit hat dafür
**keinen Simulator-Support** — der Test läuft nur auf einem echten
iPhone und ist nicht Teil der normalen Suite.

## Voraussetzung

- `integration_test` steht **nicht** in den `dev_dependencies` des
  Forks. Vor dem Lauf einmalig ergänzen (in `pubspec.yaml` unter
  `dev_dependencies:`):
  ```yaml
    integration_test:
      sdk: flutter
  ```
  und `flutter pub get` ausführen. Das ist eine lokale
  Entwicklungsänderung — committen oder als Teil dieses PRs aufnehmen,
  je nach Wunsch; der Test selbst kompiliert ohne sie nicht.

## Schritte

1. iPhone per Kabel anschließen, `flutter devices` zeigt die `<id>`.
2. Berechtigung: beim ersten Lauf öffnet sich das HealthKit-Sheet —
   **Lesen und Schreiben** für Blutsauerstoff erlauben.
3. Lauf:
   ```bash
   flutter test integration_test/oura_spo2_healthkit_roundtrip_test.dart -d <id>
   ```
4. Der Test schreibt **eine** eindeutig markierte Messung
   (2. Januar 2020, 03:00, 60 Sekunden, Wert 97 %) und liest sie über
   das Plugin zurück. Er gibt den **ROHEN** Rückgabewert aus:
   `RAW READ-BACK: [0.97]` ist der erwartete Lauf.
5. **Manueller Sichtcheck (das eigentliche Kriterium):** in der
   Apple-Health-App unter **Vitalwerte > Blutsauerstoff** den Eintrag
   vom **2. Januar 2020, 03:00** öffnen — er muss **„97 %"** zeigen,
   nicht „9700 %".
6. Der Test löscht nur sein eigenes Sample wieder. In der Health-App
   bestätigen, dass der Eintrag vom 2. Januar 2020 danach weg ist.

## Ergebnisse bewerten

- **`RAW READ-BACK: [0.97]` + Health-App „97 %"**: die iOS-Skalierung
  ist korrekt; `ouraSpo2PluginWrite` (÷100 auf Apple) ist bestätigt.
- **`RAW READ-BACK: [97.0]`** oder Health-App zeigt „9700 %": die
  Annahme aus A1 ist für die gepinnte Plugin-Version falsch — der
  Speicher erwartet Prozent. In dem Fall A1 anpassen (Apple-Zweig
  durchreichen statt ÷100), den neuen Beleg (Testausgabe +
  Health-App-Screenshot) dokumentieren und die Sandbox-Tests
  entsprechend korrigieren. **Nicht beide Skalen mischen.**
- **Test scheitert vorher** (Berechtigung verweigert, kein Gerät,
  Kompilierung): das ist ein Blocker, kein Misserfolg der Skala.
  Die Meldung `grant SpO2 read/write in the sheet` bedeutet: das Sheet
  wurde abgebrochen — App in iOS-Einstellungen > Gesundheit >
  Datenzugriff erneut erlauben.
- **Der Test läuft nicht an** (kein `integration_test`-Paket):
  Voraussetzung oben fehlt noch.

## Rückmeldung

Zurückmelden: den kompletten Konsolen-Output (`RAW READ-BACK`-Zeile),
was die Health-App anzeigt (Screenshot oder Text), und ob der Eintrag
nach dem Lauf wieder gelöscht war.
