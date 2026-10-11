// Oura SpO2: the decode, the percent contract, the batch-independent
// summary, and the eligibility gate — the whole path from the ring's
// `0x6f` events to a value that may be stored, shown and (later, after
// hardware validation) exported to Apple Health.
//
// WHY THIS LIVES IN edge AND NOT IN THE PROTOCOL PACKAGE: the pin
// (`ecb512b7…`) predates protocol-main's `decodeSpo2`/`kOuraEvtSpo2`
// (both landed in `bc1603e`, and the pinned SHA cannot reach them), and
// repinning to a SHA that has them would ride in the whole multi-device
// decoder sweep that REMOVES decoders this fork's adapters still use
// (`ringconn`, `ring11m`, `o2ring`, `zetime`, …). The decode below is
// byte-for-byte the contract protocol-main ships — same tag, same body
// shape, same refusal rules — so when the fork eventually repins onto a
// SHA that carries it, this copy deletes and the import moves to the
// package, with nothing downstream to change. Until then, `test/`
// `oura_spo2_test.dart` pins this copy against the upstream contract
// with independent expectations.
//
// NOTHING HERE HAS MET HARDWARE. The event layout is reverse-engineered,
// and a fixture passing says the DECODE works, not that the bytes mean
// oxygen saturation in a living finger. That is exactly why
// [kOuraSpo2InterpretationVerified] exists and defaults to false: the
// software path is complete, and the gate is the one thing hardware
// validation flips.
library;

import 'dart:typed_data';

/// SpO2 events: a header byte, then one saturation per second.
///
/// Tag value identical to protocol-main's `kOuraEvtSpo2`.
const int kOuraEvtSpo2 = 0x6f;

/// The envelope event shape, as the pinned protocol package defines it.
/// Local only so this file has no import on the package's `OuraEvent`
/// while the pin predates `kOuraEvtSpo2` — the fields and their meaning
/// are the package's contract, not a fork invention.
class OuraSpo2Event {
  const OuraSpo2Event(this.tag, this.tsDs, this.body);
  final int tag;
  final int tsDs;
  final Uint8List body;
}

/// A decoded [kOuraEvtSpo2] event: the per-second samples, and whether
/// the run CONTINUES in the next event (the trailing `0xff` marker).
///
/// THE CONTINUATION CARRIES NO TIME CONTRACT. Everything the pinned
/// decoder contract and the decompiled-app notes (open_oura
/// `native-decoder.md`) say about SpO2 timing is WITHIN one event:
/// batched events carry N samples sharing one event time, the first
/// sample at `utc_time_ms - (n-1) * interval` with a 1 s interval —
/// i.e. the ENVELOPE STAMP IS THE LAST sample's second and the samples
/// run BACKWARD from it. Whether the next event of a continued run
/// starts at the following second, at its own envelope stamp, or with
/// a gap is NOT established by any capture this project has. Stitching
/// the next event's seconds onto ours would INVENT a gapless series
/// the wire may not carry, so `continues` is recorded but deliberately
/// NOT used to re-time anything.
class OuraSpo2Samples {
  const OuraSpo2Samples(this.values, this.continues);
  final List<int> values;
  final bool continues;
}

/// The SpO2 percentages of a [kOuraEvtSpo2] event, one per second in
/// body order, or null when [e] is not one, carries no sample, or any
/// sample is over 100: a saturation over 100 % means the layout is
/// wrong, and the whole event is refused rather than half of it
/// trusted. A trailing `0xff` marks a run that continues in the next
/// event and is not a sample; a zero is "no reading", left for the
/// caller.
///
/// Byte-for-byte the pinned protocol-main contract (`bc1603e`+). A body
/// of `[0x01, 97, 0, 96, 98, 0xff]` yields `[97, 0, 96, 98]` — the
/// header is dropped, the continuation marker is dropped, the zero is
/// kept and MEANS "no measurement at this second".
OuraSpo2Samples? decodeOuraSpo2(OuraSpo2Event e) {
  if (e.tag != kOuraEvtSpo2 || e.body.length < 2) return null;
  var end = e.body.length;
  var continues = false;
  if (e.body[end - 1] == 0xff) {
    end--;
    continues = true;
  }
  if (end < 2) return null;
  final out = e.body.sublist(1, end);
  return out.any((v) => v > 100) ? null : OuraSpo2Samples(out, continues);
}

/// The percent contract at the normalisation boundary. A value is a
/// blood-oxygen percentage ONLY when it is finite, in (0, 100], and the
/// recorded unit is '%'. Anything else — a null, a fraction 0.97, a
/// raw ADC count, a unitless score — is not one, and this returns null
/// rather than guessing a scale.
double? spo2PercentOrNull(num? value, {required String? unit}) {
  if (value == null || unit != '%') return null;
  final percent = value.toDouble();
  if (!percent.isFinite) return null;
  if (percent <= 0 || percent > 100) return null;
  return percent;
}

/// The mean of ALREADY-VALIDATED percentage samples, with the sample
/// count carried beside it — the count is what makes the mean honest:
/// a mean of one fragment is not a night mean, and only the count lets a
/// caller know that.
///
/// Throws on any sample that is not a validated percentage: this is the
/// one place that summarises, and a silent skip here would quietly move
/// the boundary of what "validated" means. Callers validate first (the
/// adapter uses [spo2PercentOrNull]); tests pin the throw.
({double meanPercent, int count})? summarizeSpo2Percent(
  Iterable<double> samples,
) {
  var count = 0;
  var sum = 0.0;
  for (final sample in samples) {
    if (!sample.isFinite || sample <= 0 || sample > 100) {
      throw ArgumentError.value(
        sample,
        'samples',
        'Expected validated SpO2 percentages',
      );
    }
    sum += sample;
    count++;
  }
  if (count == 0) return null;
  return (meanPercent: sum / count, count: count);
}

/// The existing adapter compatibility floor, carried from the upstream
/// implementation this fork mirrors. 70 % is NOT a physiological claim
/// — lower saturations exist — it is the bound the upstream adapter
/// already applies to separate a plausible reading from a misread
/// layout, and this copy does not silently change it. The bound is
/// documented here so the hardware-acceptance checklist can confirm or
/// revise it with real captures.
const int kOuraSpo2AdapterFloor = 70;

/// Whether SpO2 interpretation has been verified against real ring
/// captures. FALSE until hardware validation flips it — and that is the
/// documented release point for the whole path: a fixture, a replay, a
/// successful pairing or a successful sync are each NOT a validation of
/// what the bytes mean.
///
/// Deliberately a const, not a persisted flag: it is a property of the
/// DECODER's verification status, not of any one install, and a bool in
/// prefs would let a stale value outlive the decoder it vouches for.
/// Flipping it is a reviewed code change together with the hardware
/// acceptance checklist (guides/OURA_SPO2_ACCEPTANCE.md), never a
/// runtime state transition.
const bool kOuraSpo2InterpretationVerified = false;

/// The one selection function every consumer goes through. Returns the
/// percentage only when the value is one AND the whole path is
/// released:
///
///  * [deviceSelected] — this ring is the device the observations are
///    read for (the caller supplies its own device-selection rule; a
///    value from a forgotten ring never renders as a current number);
///  * [integrationEnabled] — the Oura integration is switched on;
///  * [interpretationVerified] — the decoder's meaning has been
///    confirmed against real captures. Production passes
///    [kOuraSpo2InterpretationVerified]; tests may pass true through a
///    test double, and that grant never reaches production state
///    because it is a parameter, not a stored value;
///  * [timeReferenceSuitable] — the stored timestamp is a measurement
///    time (a decoded ring stamp), never a receive time or a fallback.
///
/// An unsuitable time reference closes the door completely — not
/// "export the value at noon anyway": a wrong instant in a health store
/// is a measurement claim nothing downstream can unpick.
double? eligibleOuraSpo2Percent({
  required num? value,
  required String? unit,
  required bool deviceSelected,
  required bool integrationEnabled,
  required bool interpretationVerified,
  required bool timeReferenceSuitable,
}) {
  if (!deviceSelected ||
      !integrationEnabled ||
      !interpretationVerified ||
      !timeReferenceSuitable) {
    return null;
  }
  return spo2PercentOrNull(value, unit: unit);
}
