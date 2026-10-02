# VO₂max estimation in Edge

This document is the method decision record for the session-level VO₂max
estimate: what is computed, from what data, why the alternatives were not
implemented, the exact formulas with sources, the data-quality rules, and the
compatibility contract. The user-facing claim is always **"geschätzte VO₂max"**
(estimated) — never a measured VO₂max.

## 1. What exists today

| Piece | Where |
| --- | --- |
| Formula core (pure function) | `openstrap_analytics` (pinned SHA in `pubspec.yaml`), `lib/src/onehz/clinical/vo2max.dart` → `vo2maxSubmaxEstimate` |
| Edge call site / split selection (LIVE estimate) | `lib/data/local_repository_impl.dart` → `_submaxVo2maxFromSplits` |
| Activity-type gate (ACSM is foot-only) | `lib/compute/vo2max_activity_gate.dart` |
| Retrospective history pass ("Schätzung aus bisherigen Aktivitäten") | `lib/compute/vo2max_history.dart` → `backfillVo2maxHistory` (incremental per derive: full pass once per formula version via `compute_freshness`, then only sessions whose input fingerprint changed or that have no rows yet; invoked from `derivation_engine.dart` after the strain rescale) |
| Storage — live estimate (additive, nullable columns) | `lib/data/db.dart` → `sessions.vo2max_estimate`, `sessions.vo2max_method`, `sessions.vo2max_absence_reason` |
| Storage — history estimates (separate table) | `lib/data/db.dart` → `vo2max_history` (per (session_id, km): value, absence_reason, method, formula_version, hr_max_bpm, resting_hr_bpm, activity_ts, computed_at) |
| Display (label carries method + unit; history is its own row) | `lib/ui2/activity/summary.dart` → `sessionStats` |
| Dashboard trend (Health → Trends card + MetricDetail drill-down) | `lib/ui2/screens/health_screen.dart` → `_trends`, `lib/ui2/screens/metric_detail.dart` → `'vo2max'` MetricSpec, `lib/data/local_repository_impl.dart` → `getChart('vo2max')` |
| Tests | `test/vo2max_method_test.dart` (formula core, unit conversion, method selection), `test/vo2max_session_test.dart` (live backfill integration), `test/vo2max_history_test.dart` (history pass, anchors, idempotence, separation) |

Four categories are distinguished, and the app must never blur them:

1. **Directly measured VO₂max** — gas-exchange lab test. Edge does not do this
   and never claims to.
2. **Test-protocol-estimated VO₂max** — a defined submaximal protocol. This is
   what Edge implements (ACSM pace equation + Swain %HRR→%VO₂R extrapolation),
   at ESTIMATE tier.
3. **Rough HR-ratio estimate** (Uth et al. 2004) — NOT implemented; see §3.
4. **Estimated oxygen cost of an activity** — the ACSM equation output before
   extrapolation (VO₂submax). It is a *demand* estimate, not a VO₂max; Edge
   only uses it as an intermediate, never reports it as VO₂max.

## 2. Implemented method (ESTIMATE tier)

Formula core (analytics package, applied per completed km split):

```
speedMMin      = speedMps * 60                       // m/s → m/min
grade          = gradePercent / 100                  // % → fraction
running (≥2 m/s): VO2submax = 0.2*speedMMin + 0.9*speedMMin*grade + 3.5
walking (<2 m/s): VO2submax = 0.1*speedMMin + 1.8*speedMMin*grade + 3.5
%HRR           = (HRbout − HRrest) / (HRmax − HRrest)
VO2max_est     = 3.5 + (VO2submax − 3.5) / %HRR      [ml·kg⁻¹·min⁻¹]
```

Sources:

- **ACSM metabolic equations** — ACSM's *Guidelines for Exercise Testing and
  Prescription* (walking/running speed and grade terms). Application
  restriction, documented by Koutlianos et al. (2013), "Indirect estimation
  of VO2max in athletes by ACSM's equation: valid or not?" (PMCID:
  PMC3743617): the running equation is a population mean for the energetic
  cost of level/uphill running; it systematically **underestimates VO₂max in
  trained runners** (their economy is better than the equation assumes). Edge
  therefore publishes only Tier ESTIMATE, never a "measured" claim, and the
  label carries the method.
- **Swain & Leutholtz (1997)**, "Heart rate reserve is equivalent to oxygen
  consumption reserve during moderate-intensity exercise" (*Med Sci Sports
  Exerc*), for the %HRR ≈ %VO₂R equivalence the extrapolation leans on.

Reported error: the %HRR ≈ %VO₂R equivalence itself was validated in a
laboratory setting, but the FULL productive chain — ACSM pace equation on
GPS speed, %HRR extrapolation, and individually estimated HRmax/HRrest
anchors — has **no published validation for free-recorded outdoor
activities**. Its individual error is therefore NOT quantified, and Edge
renders no individual confidence interval. SEE figures around
3–5 ml·kg⁻¹·min⁻¹ reported for standardized submax protocols in the
general population are NOT transferable to this chain and were removed
from the UI for that reason. The analytics package attaches a heuristic
band-position confidence (0.25–0.6), which is a heuristic, not a
calibrated probability.

### Storage caveats

- `vo2max_history.hr_max_bpm` / `resting_hr_bpm` are `REAL NOT NULL` and read `0`
  when an anchor was missing — a SCHEMA LIMITATION, not a measurement. Every
  consumer treats `vo2max IS NULL` as the abstention signal; the anchor columns
  are provenance, and a nullable migration would be the clean fix (needs
  approval, it is a schema change).
- No FK to `sessions` (on-device only, like every session-owned table here);
  `putVo2maxHistory` guards against orphans transactionally instead.

### Data-quality gates (all machine-readable, all abstaining, never 0)

| Gate | Code (`vo2max_absence_reason`) | Rule |
| --- | --- | --- |
| Activity type | `unsupported_activity` | Session type must be foot locomotion (`run`, `walk`, `hike` + spelling variants). GPS speed from a bike/boat/car is not ACSM pace. |
| GPS route | `no_route` / `route_too_short` | No route, or fewer than 2 fixes. |
| Full km split | `no_completed_km_split` | Only completed ≥999 m splits; a partial trailing km has no fixed distance. |
| Steady HR over split | `no_steady_hr_for_split` | Split's own average HR exists and duration > 0. |
| Steady-state bout | `no_qualifying_bout` | Analytics-side: bout ≥ 300 s, %HRR in [0.40, 0.90], reserve ≥ 20 bpm, plausible result range. |
| Equation grey zone | `equation_domain_ambiguous` | Edge-side: bout pace in ~1.9–2.1 m/s, where the ACSM walk/run equation switch is a modelling artefact (a ~12 ml·kg⁻¹·min⁻¹ jump at 2.0 m/s). Technical heuristic; the real fix belongs in analytics. |
| Read failure | `estimation_unavailable` | A storage/route error — the method never ran; never dressed up as a physiology abstention. |
| Method | `acsm_speed_swain_hrr` | Provenance code stored with the value (`vo2max_method`). |

Known heuristic (labelled as such in the code, not as validated physiology):
edge picks the **longest** full km split, not a pace-variance-gated steady
sub-window — warm-up/surge/fade inside the chosen km blur the average. The
%HRR band is what catches most of that. Heuristic; documented; upgrade path
noted in `local_repository_impl.dart`.

### Inputs and their provenance

- **HRmax** — `estimatedMaxHr` (Tanaka 2001, `208 − 0.7·age`), an explicitly
  labelled age-based ESTIMATE, or the observed ceiling where a measured one
  exists. Never "highest HR of an arbitrary workout".
- **HRrest** — the derivation engine's nightly resting HR
  (`metric_series['rhr']`, trailing value), or a user-entered manual value.
  Never a raw minimum of noisy samples.
- **Speed/grade** — the session's own GPS route split (haversine distance
  over duration; net elevation over the km for grade; grade is omitted
  entirely rather than set to 0 when altitude is missing — 0 reads as
  "flat", which is a fabricated input).

## 2a. Retrospective estimate from history ("Schätzung aus bisherigen Aktivitäten")

A SECOND, separate claim lives alongside the live estimate. It answers
"what can my stored history say?" — computed by `backfillVo2maxHistory`
(`lib/compute/vo2max_history.dart`), an incremental pass the derivation engine
runs after its strain rescale.

**Same method, different data, separate storage.** The published chain is
the one above (ACSM pace → VO₂submax, Swain %HRR → extrapolation), but the
bout is a frozen per-km `workout_split` row — real distance, real duration,
its own average HR — rather than a live substrate window. Because the
splits survive the 3-day raw pruning, this pass covers the FULL stored
history, not just the retention window.

**Anchors, and the honesty rules around them:**

- **HRmax** is an observed ceiling recorded strictly BEFORE the session
  (`metric_series['hr_ceiling_bpm']`, date-checked), else the Tanaka age
  line with the CURRENT profile age. The session's own peak HR is NEVER
  the HRmax anchor: a workout peak is a lower bound on the true maximum.
- **HRrest** is the last measured nightly RHR strictly before the session's
date (`metric_series['rhr']`), else the user's manual value. A LATER value
  is never passed off as historically available.
- Missing anchors are machine-readable abstentions
  (`no_hr_max_available`, `no_resting_hr_available`), never population
  defaults.

**What qualifies, what abstains** (per split, each with its own code): foot
locomotion only (`unsupported_activity` otherwise); a FULL km — ≥ 999 m,
the same rule as the live pass, because the stored table also carries the
partial trailing km, whose "speed" is no real pace (`no_completed_km_split`)
— with a frozen avg HR (`no_steady_hr_for_split` otherwise); and
the analytics submax band (`no_qualifying_bout`: <300 s, %HRR outside
40–90 %, reserve <20 bpm, implausible extrapolation). A **casual stroll
fails the %HRR floor on its own** — the band, not a type judgment, decides
what counts as "zügig"; no standardised walk-test protocol (Rockport et
al.) is claimed or run. Walking-speed bouts that ARE inside the band use
the ACSM WALKING equation (the model matches the gait).

**Free activities, not standardised tests.** Every qualifying bout is a
free-recorded activity, not a documented test protocol. The result is an
ESTIMATE-tier claim labelled "Schätzung aus bisherigen Aktivitäten", and
its UI row says so explicitly. No precision beyond that is claimed.

**Original values are never touched.** The pass writes ONLY to
`vo2max_history` — session rows, routes, splits and their frozen test
assignments stay byte-identical. Rows carry `activity_ts` (the activity's
own time) and `computed_at` (the after-the-fact computation time), so a
nachträgliche Berechnung is always distinguishable from a live one.

**Idempotence and re-runs.** Rows are keyed (session_id, km), INSERT OR
REPLACE: repeated passes (or a `force` re-run after a formula bump — bump
`kVo2maxHistoryFormulaVersion` with it) overwrite in place, never
duplicate. A `compute_freshness` gate short-circuits the pass after the
first run. Session deletion cascades to its history rows.

**Display aggregate.** A session's qualifying split estimates are
summarised as their MEDIAN (not the mean — one outlier split, e.g. a
downhill wind-aided km, must not drag the aggregate), computed at read
time via `LocalDb.vo2maxHistoryMedians()`, shown as a separate
"VO2max (from history)" row. Never stored as if it were itself a
measurement, never mixed with the live estimate's row, and never averaged
across methods.

## 3. Method candidates NOT implemented, and why

### Uth et al. (2004) HR-ratio method — `15.3 × HRmax/HRrest`

Source: Uth, Sørensen, Overgaard, Pedersen, "Estimation of VO2max from the
ratio between HRmax and HRrest – the Heart Rate Ratio Method", *Eur J Appl
Physiol* (DOI: 10.1007/s00421-003-0988-y). Validated on 46 well-trained men
aged 21–51 — Edge's user base is not that population and Edge makes no such
claim. Decisive repo-internal reason: the formula reduces algebraically to a
rescaled **resting heart rate** (constant HRmax ⇒ VO₂max = 15.3·HRmax/HRrest
∝ 1/RHR), i.e. it is not an independent fitness signal; the repo deleted it
deliberately (`lib/compute/crossday_pipeline.dart`, CV-02) together with the
physiological age that double-counted the same input. A regression test pins
its absence (`test/vo2max_method_test.dart`), including the reference case
HRmax 180 / HRrest 60 → 45.9: asserted as arithmetic of the *rejected*
formula only, unreachable from any shipped code path.

### Cooper 12-minute run — `22.351 × distance_km − 11.288`

Used in the Cooper-validation literature (e.g. Bandyopadhyay, "Validity of
Cooper's 12-minute run test …", DOI: 10.5604/20831862.1127283, male
university students). NOT implemented: Edge records free sessions, and an
arbitrary 12-minute window from a normal run is **not a documented Cooper
protocol**. Applying the formula without the protocol fabricates a provenance
the data does not have.

### No cross-sport transfer

The ACSM **running** equation is never applied to cycling, swimming or other
types; the activity gate enforces this and stores
`unsupported_activity` as the machine-readable reason.

### No averaging across methods

No two estimate methods are combined into one average value — each session
carries at most one estimate from one method (`vo2max_method`).

## 4. Compatibility and migration

- Three additive, nullable `sessions` columns (`vo2max_estimate` was
  pre-existing; `vo2max_method`, `vo2max_absence_reason` are new). Old rows
  read NULL — the honest "no estimate / reason unknown" state. No stored value
  is ever rewritten: the estimate is forward-only/backfill-once (same 3-day
  substrate-retention reason as `avg_hr`).
- One NEW table `vo2max_history` (CREATE IF NOT EXISTS — additive, no
  migration of existing data, nothing to migrate: the pass fills it). The
  history pass never writes to `sessions`/`workout_route`/`workout_split`;
  deletion cascades from `deleteSession` keep it owner-consistent.
- API shape unchanged: `getWorkout`/`getWorkouts` gain two optional nullable
  keys; `ActivityResult.vo2maxAbsenceReason` is a new optional field carried
  through `copyWith`. No existing key, format or platform version changes.
- UI: the value line shows "VO2max (est.) … (est., ACSM pace + %HRR)" with the
  unit; when there is no estimate the line shows the reason in prose via
  `vo2maxAbsenceText` (snake_case codes never render). No screen shows
  VO₂max = 0 for missing data.
- Localization: the VO₂max stat labels, method hints and every absence
  reason are keyed in `lib/l10n/app_*.arb` (`vo2maxStatLabel`,
  `vo2maxStatMethod`, `vo2maxHistoryStatLabel`,
  `vo2maxHistoryStatMethod`, `vo2maxAbsence*`) for ALL SIX supported
  locales (de, en, es, fr, hi, zh). `vo2maxAbsenceText(code, l)` takes the
  caller's `AppLocalizations`; a null `l` falls back to the built-in
  English lines so pure unit callers keep working. The storage codes stay
  locale-independent vocabulary.
- No new dependencies. No personal health data is logged by this path beyond
  what the session row already stores.

## 5. Verification performed

- `flutter test test/vo2max_method_test.dart test/vo2max_history_test.dart `
  `test/vo2max_session_test.dart` (CI shape: `--concurrency=1`) - all VO2max
  suites passing, including hand-derived reference cases (flat run 3.03 m/s
  at 72 %HRR -> 54.03 ml/kg/min core / 54.18 with the fixture's slightly-long
  km; walking 1.39 m/s -> 15.08), km/h->m/min and %->fraction unit tests,
  NaN / negative / zero / contradictory-HR abstentions, activity-gate
  coverage, absence-code prose mapping (including the history-pass codes),
  and DB integration (backfill once, cycling abstains with
  `unsupported_activity`, no-route banks `no_route`, near-maximal banks
  `no_qualifying_bout`, a PARTIAL trailing km banks `no_completed_km_split`).
- `flutter test test/vo2max_trend_test.dart` - dashboard aggregation: same-day splits collapse to one MEDIAN point; day buckets key on the LOCAL calendar day (not day-of-month); a foreign `method` never leaks into the series (mixing rule); abstention rows chart nothing, never a 0; empty history is an empty series.
- `flutter test test/vo2max_history_test.dart` - history pass: a stored split
  with anchors becomes a history estimate (reference ~54); the session row
  stays untouched; a casual stroll abstains `no_qualifying_bout`; cycling
  abstains `unsupported_activity`; missing pre-session RHR abstains
  `no_resting_hr_available` (a later-dated RHR value is NOT used); the
  session peak HR never serves as HRmax (age line wins over a stored 205
  spike); a PARTIAL trailing km abstains `no_completed_km_split`; re-running
  replaces in place (no duplicates, same values); the freshness gate
  short-circuits a second non-forced pass; per-session medians exclude
  abstentions; deletion cascades; an imported RHR day is not an anchor.
- Regression suites re-run green: `db_migration_ladder_test`,
  `db_v43_nullable_hr_test`, `db_integrity_test`, `db_storage_hygiene_test`,
  `derivation_pipeline_test`, `ui2_activity_test`, `ui2_wiring_r2_test`,
  `absence_and_offload_guards_test`, `crossday_pipeline_test`,
  `workout_enrichment_test`, `log_workout_test`.
- `flutter analyze` - no issues.
- Test isolation: every VO₂max DB test runs on a FRESH database per test
  (`setUp` deletes the file). The suites additionally pass under
  `--test-randomize-ordering-seed` (history seed 12345, trend seeds 777/42)
  and per-`--plain-name` single runs — no hidden order dependencies.
- Provenance re-walk regressions: a later-measured historical RHR re-walks
  a session whose splits never changed (abstention upgrades to a value,
  reason fully cleared); a LATER `hr_ceiling_bpm` does not displace an older
  session's as-of anchor (187 stays 187, value stays ~54); a corrected
  session timestamp re-walks and replaces the stale row.
- Partial-failure regression: with a SQLite trigger injected to fail one
  session's history INSERT mid-pass, the pass throws, the already-written
  session's rows survive, the freshness payload is NOT marked current, and
  the next pass completes the failed session without duplicating the
  good one (test seam: SQL trigger, no production-code hook).
- Upgrade regression: a stale `formula_version` payload triggers a full
  re-walk that replaces rows in place.
- L10n regression: every absence code resolves to localized, non-empty,
  underscore-free prose in EVERY supported locale (de/en/es/fr/hi/zh) via
  `lookupAppLocalizations`.

Unit tests prove arithmetic, not clinical accuracy. The physiological
validity of a submax estimate on any individual is not claimed and cannot be
tested by this suite.

## 6. Not supported (stated, not hidden)

- Directly measured VO₂max (no gas exchange in this stack).
- Cooper or Åstrand protocols (no documented protocol capture).
- HR-ratio (Uth) estimates — deliberately deleted.
- Non-foot sports, treadmill sessions without GPS, sessions whose raw
  substrate has already been pruned without a banked estimate.
- Population-specific coefficient adjustments (e.g. local validation
  cohorts) are not folded into the general formula.

## 6a. Dashboard integration (Health -> Trends + MetricDetail)

The retrospective series IS charted; the live estimate is NOT:

- **Trend card** (`lib/ui2/screens/health_screen.dart` -> `_trends`): a
  `TrendCard` for "VO2max (est.)" between HRV and Time asleep, built by the
  same `trend()` helper every other card uses - trailing 28-day mean, dense
  30-day window, "as of <day>" data-age line, delta direction with
  higher-better judgement.
- **Drill-down** (`lib/ui2/screens/metric_detail.dart`): a `MetricSpec`
  entry whose method text states the estimate tier, the formula chain, that
  the individual error of the extrapolated chain on free-recorded bouts is
  not quantified and no individual confidence interval is shown, and that
  non-qualifying sessions contribute nothing. Citations:
  ACSM metabolic equations, Swain & Leutholtz 1997.
- **Data path** (`LocalDb.vo2maxHistoryDailyTrend` -> `getChart('vo2max')`):
  one MEDIAN point per local calendar day that has at least one valued
  history row. The per-day median - not the mean - for the same outlier
  reason as the per-session aggregate: one wind-aided downhill km must not
  drag the day.

**Mixing rules, machine-enforced in the DB layer:**
- only rows with `method = 'acsm_speed_swain_hrr'` chart; any other method
  (e.g. a future imported device estimate) is a different claim and never
  averaged into this series;
- a formula-version boundary surfaces as an `algo_break` in the
  `getChart` payload - the same convention `metric_series` version breaks
  already follow, so the chart can mark where the maths changed;
- the per-session LIVE estimate (`sessions.vo2max_estimate`) never charts
  here and is never averaged with the retrospective points.

Empty history renders as the standard "no trend yet" card - never a 0
point, never a fabricated flat line.

### Which historical activities can be evaluated, and why

| Activity shape | Can the history pass use it? | Why |
| --- | --- | --- |
| Run/walk/hike with a frozen full-km split + its own avg HR, and pre-session RHR + (observed ceiling or age) available | YES — one estimate per qualifying split | every model prerequisite is met |
| Brisk walk inside the 40–90 %HRR band | YES (ACSM WALKING equation) | the gait model matches the speed band |
| Casual stroll / Spaziergang below the %HRR floor | NO — `no_qualifying_bout` | too easy to extrapolate reliably; the band, not a type label, decides |
| Cycling, swimming, strength, unknown type | NO — `unsupported_activity` | ACSM running/walking equations are foot-locomotion models |
| Session with no completed km split or no frozen HR for it | NO — `no_completed_km_split` / `no_steady_hr_for_split` | no fixed distance/duration or no bout HR |
| Session predating every RHR measurement (no manual value) | NO — `no_resting_hr_available` | a later-measured RHR is not historically available |
| Session with no age and no pre-session observed ceiling | NO — `no_hr_max_available` | no honest HRmax anchor; never a population default |
| Summary-only imports (distance/duration without per-split data) | NO | the method needs a bout's own HR; averages alone are not segment analysis |
| Sessions whose splits predate the `workout_split` feature | NO | nothing frozen at finalize — never reconstructed from raw that is gone |

Open verification (no source access in this environment, flagged rather
than silently assumed): the exact SEE values reported by Swain & Leutholtz
(1997) and the ACSM Guidelines' current-edition coefficients were not
re-checkable against the originals here; the analytics pin's coefficients
match the commonly published forms of both. No errata were found in the
reachable secondary literature (Koutlianos 2013, PMCID PMC3743617).
