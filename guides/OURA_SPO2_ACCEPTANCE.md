# Oura SpO₂ — Hardware- und Zeitreferenz-Abnahme

Diese Checkliste ist die dokumentierte **Freigabestelle** für den produktiven
Oura-SpO₂-Export. Der Softwarepfad ist vollständig implementiert und mit
Fixtures geprüft; produktive Daten bleiben so lange vom Health-Export
ausgeschlossen, bis diese Abnahme bestanden ist.

## Die Freigabe selbst

Die Freigabe ist **ein Code-Review-Change, kein Laufzeitschalter**:

- `lib/ble/adapters/oura_spo2.dart`
  - `kOuraSpo2InterpretationVerified` → `true`
- Grund: die Konstante voucht für den **Decoder-Verifikationsstatus**, nicht
  für einen Installationszustand. Ein persistierter Boolean würde ein
  Stall-Signal überleben, das der Decoder, für den es steht, längst nicht
  mehr ist.

Bis zu diesem Flip liefert `eligibleOuraSpo2Percent` für jeden Production-Pfad
`null` — Anzeige in der Timeline bleibt erlaubt ( Gerätewert mit Attribution),
Export nach Apple Health / Health Connect bleibt geschlossen.


## Vier Betriebsarten — niemals gleichsetzen

| Modus | Was er ist | Adapter-Status |
| --- | --- | --- |
| **A. Historische Synchronisierung** | Ring liefert früher entstandene 0x6f-Events über den History-Drain (Cursor, batch summary, Replays dedupliziert) | **Implementiert** (der einzige Pfad, den dieser Fork heute hat) |
| **B. Letzten Gerätewert abfragen** | Lesende Latest-Anfrage (`2f 02 24 04`); Antwort kann alt, fehlend oder ohne Messzeit sein | Protokollhinweis vorhanden; **nicht implementiert, nicht freigegeben** |
| **C. Echte neue Messung auf Nutzerwunsch** | App startet eine neue Messung und erhält deren Ergebnis | **Kein nachgewiesener Startbefehl für SpO₂**; on_demand_meas (`0x62`) deckt laut Referenz HR/HRV/Atmung/Temperatur ab — ob/dass SpO₂ on-demand messbar ist: **derzeit unbekannt**. Nicht erraten, keine Opcodes hardcoden |
| **D. Live-Stream** | Fortlaufende neue Messungen während einer begrenzten Sitzung | CONNECTED_LIVE ist für HR belegt; ein SpO₂-Live-Stream ist **nicht nachgewiesen**. Keine Live-HR-Fähigkeit auf SpO₂ übertragen |

„Jetzt synchronisieren" (A) ist keine Messung. „Antwort empfangen" (B) ist kein
„gerade gemessen". Ein Feature-ACK bestätigt keine gültige Messung.

## Fähigkeitsübersicht des Oura-Adapters (per Datenpfad)

| Fähigkeit | Status | Nachweis/Quelle |
| --- | --- | --- |
| Historische SpO₂-Daten lesen (0x6f `API_SPO2_EVENT`, pro Sekunde, Prozent) | mit Fixtures geprüft; Hardware-Verifikation offen | Decoder-Vertrag identisch zu protocol-main `bc1603e`; open_oura: Produktions-Nachtwert |
| SpO₂-Smoothed lesen (0x70 `API_SPO2_SMOOTHED_EVENT`) | nicht untersucht; vom aktuellen Decoder bewusst NICHT gelesen | open_oura data-recovery-map; eigener Layout-Check nötig, bevor er decoded wird — Rohbytes landen schon heute in `raw_archive` |
| R-Ratio/PI-Pfad (0x8b `spo2_r_pi`) | nicht unterstützt für SpO₂-% — **bewusst nicht implementiert** | open_oura spo2-calibration: braucht App-Kalibrierpolynome (a/b/c nach Hardware); fremde Kalibrierkonstanten werden nicht übernommen; ein R-Ratio ist kein Prozentsatz |
| Feature-Status lesen (0x04 SpO₂, `2f 02 20 04`) | Protokollhinweis vorhanden; nicht implementiert | Referenzring antwortete mode/status/state/subscription — sagt nichts über laufende Messungen |
| Letzten SpO₂-Wert lesen (`2f 02 24 04`) | Protokollhinweis vorhanden; nicht implementiert | Referenzring: `result 0` mit „zero-like data" — Zeitbezug des Latest-Pfades unbekannt |
| SpO₂-Erfassung aktivieren/deaktivieren (`SetFeatureMode` 0x04) | Protokollhinweis vorhanden; **nicht implementiert** — kein Verstellen des Ring-Messmodus ohne Owner-Entscheid | open_oura ring-features: SPO2 default AUTOMATIC; Modus geht Ring-Speicherverbrauch an |
| Neue SpO₂-Messung starten | **derzeit unbekannt** | kein beobachteter Startbefehl; Startbedingungen, Messphase, Ergebnisvertrag fehlen |
| SpO₂ live streamen | **derzeit unbekannt** | CONNECTED_LIVE nur für HR belegt |
| Messung/Stream sicher stoppen | **derzeit unbekannt** | hängt an C/D; ohne Startbefehl gibt es nichts zu stoppen |

Nichts davon wird als „unterstützt" ausgegeben, bevor ein konkreter
Modell-/Firmwarestand es gezeigt hat. „Unbekannt" bleibt unbekannt.

## Datenpfade niemals mischen

0x6f-Prozentwerte, 0x70-Smoothed, 0x8b-R-Ratios und ein späterer
Latest-/On-Demand-Pfad sind **verschiedene Validierungsstände**. Die
Freigabe (`kOuraSpo2InterpretationVerified`) gilt zunächst NUR für den
historischen 0x6f-Pfad. Jeder weitere Pfad braucht seinen eigenen
Nachweis und seine eigene Freigabeentscheidung — die Konstante ist kein
Grünfärben aller Oura-SpO₂-Daten.


## Zeitvertrag: was belegt ist und was nicht

**Belegt** (open_oura `native-decoder.md`, dekompilierte App): Ein Event
trägt N Samples mit EINER Event-Zeit; das erste Sample liegt bei
`utc_time_ms − (n−1) × Intervall`, Intervall SpO2 = 1 s. Der
Envelope-Stempel ist also das ENDE der Messreihe des Events; die Samples
laufen rückwärts davon. Der Edge-Adapter stempelt entsprechend.

**Nicht belegt** (kein Capture, keine Doku): ob der auf `0xff`
fortgesetzte Lauf im nächsten Event die unmittelbar folgenden Sekunden
belegt, dort weiterläuft oder eine Lücke hat. Edge interpretiert das
NICHT: jedes Event behält seine eigenen Envelope-Sekunden; überlappende
Sekunden kollabieren im Identity-Index (Rohdaten bleiben in
`raw_archive`). Diese Lücke ist ein expliziter Punkt der
Hardware-Abnahme: **ein realer Capture eines fortgesetzten Laufs über
zwei Events** muss zeigen, wie die Stempel zusammenhängen, BEVOR der
Export freigegeben wird.

## Produktionsquellen der Gate-Zustände

| Zustand | Quelle | Nachweis |
| --- | --- | --- |
| registriert/gekoppelt | `device`-Zeile (`upsertDevice` schreibt, `deleteDevice` löscht) | Gate liest `ouraSpo2DayDevice` (JOIN) |
| ausgewählt | Tag-Owner = Gerät mit den meisten Messsekunden des Tages | `ouraSpo2DaySummaries`-Reihenfolge; PRODUCT-ENTSCHEIDUNG, dokumentiert; gegen bestehende Nutzer-/Geräteprioritäten prüfen, falls welche eingeführt werden |
| aktiviert | im Fork identisch mit der device-Zeile — es existiert KEIN separater Oura-Aktivierungsschalter; `OuraLink.sync` selbst entscheidet an derselben Zeile | dokumentiert; ein künftiger Aktivierungsschalter wäre eine eigene Produktentscheidung |
| Interpretation freigegeben | `kOuraSpo2InterpretationVerified` (const, Code-Flip) | gilt NUR für den historischen 0x6f-Pfad |

## Prozent-Nachweis (offen)

Dart `97.0` → `writeHealthData(value: 97.0, type: BLOOD_OXYGEN, unit:
PERCENT)` → iOS `HKQuantity(quantityType: oxygenSaturation, unit:
HKUnit.percent(), value: 97.0)`. Plugin-Quellen (health 12.2.1)
benutzen `HKUnit.percent()` ohne Skalierung; Android schreibt
`OxygenSaturationRecord(percentage)`. Der NATIVE Zahlenwert wurde NICHT
auf einem Gerät/iOS-Build verifiziert — dieser Nachweis bleibt offen
bis ein iOS-Build läuft (in dieser Sandbox nicht ausführbar).

## Nachweise, die die Freigabe benötigt

1. **Ringmodell/Firmware** dokumentiert (welches Modell, welche Firmware).
2. **Kopplung und Authentifizierung** über mehrere Verbindungen stabil.
3. **Messfunktion** bestätigt aktiv — oder Status ehrlich „unbekannt“
   (dann weiter geschlossen).
4. **Daten dauerhaft gespeichert**: Per-Sekunden-Rows in `observation`
   sichtbar, Identity-Index dedupliziert Replays.
5. **SpO₂-Layout an realen Captures geprüft**: `0x6f`-Events aus
   `raw_archive` mit dem Decoder abgeglichen; mindestens zwei
   unabhängige Messreihen.
6. **0xff-Fortsetzungsmarker** an realen Events bestätigt (Position und
   Häufigkeit). **Fortsetzende Läufe** müssen zusammenhängende Sekunden
   belegen — der Adapter nummeriert die Sekunden entlang des Laufs, nicht
   pro Event-Stempel neu (Test pinnt das; ein Verstoß würde zwei Werte
   auf dieselbe Sekunde legen, und der Identity-Index behält still den
   zuletzt geschriebenen).
7. **0 = keine Messung** an realen Events bestätigt.
8. **Zeitanker über mehrere Verbindungen stabil**: gleiche physiologische
   Sekunde → gleicher Unix-Sekund; Replays überschreiben sich selbst
   (keine Duplikate in `observation`).
9. **Neustartverhalten**: Ring-Reboot (RingStart/Counterreset) getestet;
   Cursor-Reset (`oura_cursor_stranded`) wirkt; kein Zeitversatz.
10. **Batchaufteilung verändert das Ergebnis nicht**: gleiche Nacht,
    unterschiedlich große Batches → identische Per-Sekunden-Rows und
    identische Tageszusammenfassung.
11. **Untergrenze 70 geprüft**: bestätigen oder anpassen (sie ist eine
    Adapter-Kompatibilitätsgrenze gegen fehlgelesene Layouts, keine
    physiologische Aussage).
12. **Referenzvergleich**, soweit ohne Datenverlust möglich (z. B. gegen
    die Oura-App oder ein Fingerspulsoximeter). Eine übereinstimmende Nacht
    ist **kein** umfassender Validierungsnachweis.
13. **Nach Freigabe**: korrekter Wert (97,0 % = 97 %) in Apple Health sichtbar;
    erneuter Sync erzeugt keine Duplikate; Fremddaten (Oura-App, Apple Watch,
    andere Apps) bleiben unverändert.
14. **Berechtigungs-Isolation**: verweigerte SpO₂-Schreibberechtigung
    blockiert Schlaf-, HR- und Workout-Export nicht (Tests pinnen das).

## Rahmenbedingungen

- Kein gleichzeitiger Oura-App-Betrieb erforderlich, wenn der geprüfte
  Kopplungsvertrag ihn ausschließt (Pairing entfernt die App ohnehin).
- **Kein Factory Reset für Referenztests** ohne ausdrückliche Zustimmung
  des Owners — der Pairing-Key ist lokal und geht dabei verloren.

## Nach dem Flip

- Kurzer finaler Testlauf der kompletten Kette (Fixtures + ein echter Sync).
- Der SpO₂-Backfill-Cursor (`health_oura_spo2_through`) holt Tage nach,
  die vor der Freigabe gespeichert wurden — Altwerte werden nicht rückwirkend
  umgedeutet; Tage ohne damalige Speicherung bleiben geführt fehlend.
