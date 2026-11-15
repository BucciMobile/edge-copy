# Features

Everything below is computed and stored on your phone.

## Devices

- **WHOOP 4.0, 5.0 and MG:** full support. Every metric below is computed from these.
- **Any standard Bluetooth heart-rate strap:** pairs for workout tracking (heart rate
  and beat timing, stored and shown). Feeding it into recovery and strain is planned.
- **Oura Ring:** experimental. Pairs and syncs the ring's history to the phone; that
  history is stored but doesn't feed any score yet.
- **Being built:** Garmin, Pebble, Colmi, Ultrahuman, Mi Band and more. The pairing
  screen marks these **Experimental**. They can pair and store what they send, but none
  of it becomes a number in the app until the decoding is confirmed on a real device.

## Health

Heart rate, HRV, sleep staging, recovery/readiness, strain, stress, an HRV spot-check,
a VO2max estimate, and real-time breathing coherence.

Strain is scored against your own quiet waking heart rate, not a population constant,
so a workout counts the same for a fit person with a low resting HR as for anyone else.
It needs three days of your data before it shows a number. Nightly HRV is RMSSD from one
estimator, and a night where the beat detector over-counts is refused rather than scored.

### Deviations from your own baseline

The overnight watches (resting-heart-rate trend, unusual-overnight-physiology, skin
temperature) compare each night with **your own** rolling baseline over valid nights only —
never against a population table, and never against a night that was not measured. The
baseline unlocks in stages and says so while it is learning: below 7 valid nights the
watches stay quiet ("learning your baseline"), and a wear gap longer than two weeks steps
the stage back down. Each night is also checked against **context you already know about** —
training load, accumulated sleep debt, journal entries (alcohol, late caffeine, a late
meal, vaccination, travel, feeling unwell) and, when cycle tracking is on, the second half
of the logged cycle — so an expected deviation (a hard workout, a couple of drinks, a
vaccine) is not reported as an anomaly. What remains after that subtraction is what the
watches report: a deviation from your baseline, stated as a pattern, never as a diagnosis.
These are approximations based on published research (e.g. Mishra et al., *Nature
Biomedical Engineering* 2020; Natarajan et al., *npj Digital Medicine* 2020) — not
medical-grade, not validated against a lab, and not a diagnosis.

The residuals are then aggregated into tiers. One signal off baseline is a card on Home and
Health only; two or more signals off baseline for two or more nights earn one **ask-first
check-in** notification in the morning ("your values have deviated from your baseline for
the last 3 nights — do you feel unusually tired or run down?"), because self-report beats
objective wearable metrics for early detection (Saw et al., *BJSM* 2016 systematic review).
No tier above 1 ever comes from a single night. A skin-temperature + breathing-rate +
resting-heart-rate rise together for several nights raises the check-in's urgency, still
without naming any condition: it recommends rest and, if it persists, checking with a
healthcare professional. The quick replies are one tap: "I feel fine" quietens the same
watch for 48 hours, "a bit run down" keeps watching, and "sick / symptoms" starts an
explicit illness state — while it lasts, those deviations are expected, so the watches
stand down instead of re-warning, and every reply is journaled automatically. The state
ends after three nights back in your baseline or when you dismiss it. Missing signals
(say the band's firmware withholds skin temperature) simply do not count — the card says
which signals were unavailable rather than showing a green.

## Activity

Auto-detected workouts, live workout tracking with GPS routes, heart-rate zones you can
edit, and GPX export.

## Your data, elsewhere

- Writes to **Apple Health** (HealthKit) and **Google Health Connect**: sleep stages,
  resting HR, HRV, respiratory rate, active energy and workouts. Only things the device
  measures, never derived scores, which have no native type. Exports are idempotent, so
  re-deriving a day never duplicates samples.
- Export the entire local SQLite database to a file whenever you like.
- Scheduled local backups, which run when you open the app and one is due. On Android
  you can point them at a folder of your choice.

## Everything else

- Trends and history
- A journal with on-device correlation insights ("what actually moves your numbers")
- Lab-result CSV import
- Cycle tracking
- A deterministic coach and a bring-your-own-key AI assistant (see
  [guides/AI_COACH.md](../guides/AI_COACH.md))
- A shareable weekly recap
- Home-screen widgets, iOS Live Activities, and Siri shortcuts, including
  [Sync Data](../guides/IOS_SHORTCUTS.md) for on-demand or scheduled sync
- A smart alarm that buzzes the device on a weekly repeating schedule, with a wake
  window that catches you in light sleep
- Languages: English, German, Spanish, French, Hindi, Russian and Chinese

## Known limits

- iOS background sync is best-effort. Apple doesn't give third-party apps a real
  background service, so the OS decides when sync tasks run. Android has no such limit.
- Metrics are approximations based on published research. They are not medical-grade,
  not validated against a lab, and not a diagnosis.
- Not on the App Store or Play Store yet. iOS is a public TestFlight beta; Android is an
  APK from GitHub Releases.
- WHOOP 5.0 and MG support is newer than 4.0's and has had less daily wear. Open an
  issue when something looks wrong.
- Don't switch back and forth between this app and the device maker's app. A firmware
  update pushed from there could change the records this app depends on.
