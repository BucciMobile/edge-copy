// ACSM walking/running metabolic equations are LOCOMOTION equations: they
// model the energy cost of moving the body over ground on foot. `_submaxVo2maxFromSplits`
// feeds them GPS speed, so any session whose GPS "speed" is not walking/running
// speed — a wheel on a bike, a boat, a lift — produces a number the equation
// never claimed. This gate is the sportart check that keeps the estimate inside
// the ACSM validity range; see docs/VO2MAX.md for the full method decision.

/// Session types the submax VO₂max estimate accepts. Walk/run/hike only:
/// exactly the gaits the ACSM equations in analytics' `vo2maxSubmaxEstimate`
// model (below 2.0 m/s the walking equation, at/above it the running one).
const Set<String> vo2maxEligibleTypes = {
  'run',
  'running',
  'walk',
  'walking',
  'hike',
  'hiking',
};

/// True when [type] is a foot-locomotion activity whose GPS pace can be fed
/// to the ACSM equations. Null/unknown types are rejected, not assumed: a
/// missing type is missing information, and an estimate on top of it would
// be a fabricated provenance.
bool vo2maxEligibleActivity(String? type) =>
    vo2maxEligibleTypes.contains((type ?? '').trim().toLowerCase());

/// ACSM EQUATION-DOMAIN GATE (edge-side, NOT a formula change).
///
/// The pinned analytics switches between the walking (<2.0 m/s) and running
/// (>=2.0 m/s) equation at a hard threshold. The two equations are NOT
/// continuous there — a flat bout at 2.0 m/s costs 15.5 ml/kg/min under the
/// walking equation and 27.5 under the running one, a ~12-unit jump that
/// no physiology produces over a hair of pace. The switch is a modelling
/// artefact of using two regression equations outside their individual
/// comfort zones, and the honest edge-side answer inside the grey zone is
/// NO ESTIMATE rather than whichever equation the pace happens to land in.
///
/// The bounds below are a TECHNICAL HEURISTIC marking where neither
/// equation's validation population lives (the walking equation's subjects
/// and the running equation's subjects simply do not meet at 2.0 m/s);
/// they are not calibrated confidence statements. A proper fix belongs in
/// the analytics repo (domain checks in vo2maxSubmaxEstimate itself); this
/// gate is the safe edge-side containment until that package change is
/// approved.
const double kVo2maxGreyZoneMinMps = 1.9;
const double kVo2maxGreyZoneMaxMps = 2.1;

/// Machine-readable reason a bout's pace falls where the ACSM equation
/// choice is arbitrary, or null when the pace is safely inside one
/// equation's domain. Pure, public, unit-testable.
String? acsmSpeedDomainReason(double speedMps) {
  if (!speedMps.isFinite || speedMps <= 0) return 'no_completed_km_split';
  if (speedMps >= kVo2maxGreyZoneMinMps &&
      speedMps <= kVo2maxGreyZoneMaxMps) {
    return 'equation_domain_ambiguous';
  }
  return null;
}
