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
