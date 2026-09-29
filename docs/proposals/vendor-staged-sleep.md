# Proposal (NOT an owner ruling): a `vendor_staged` sleep source

**Status: idea for the owners to rule on. Nothing here is implemented, and
nothing here should be merged as-is.** This document collides with stated
project principles on purpose — the collision is named first, not discovered
later — because the collision is the decision.

## The collision, stated up front

Two rules this proposal would have to bend:

1. **`observation` is never an input to a derivation.** The single invariant
   of `OBSERVATION_SPEC`: nothing reads the table into a baseline, into a
   trend that also carries derived values, or into any input to a
   derivation. `observation_isolation_test.dart` fails the moment anyone
   does. A vendor's sleep staging is exactly the kind of number that lands
   in `observation`, and this proposal would read it out again.

2. **`InputSignal` names INPUTS, never outputs.** `signals.dart`: "DO NOT
   add a member for something we compute." A vendor hypnogram consumed as a
   sleep source is a consumed output — the seam this repo built its whole
   adapter layer to avoid.

This document argues both bends are survivable for ONE narrow case, and asks
the owners to rule. It is not an implementation plan; it is the decision
input.

## Why this narrow case might be worth the bend anyway

The existing sleep source precedence (`substrate.dart`) is:

```
rejected > manual / confirmed (user override) > auto (van-Hees accel)
        > auto_fallback (HR-led, LOW confidence) > none
```

The proposal adds one rung:

```
rejected > manual / confirmed (user override)
        > vendor_staged (vendor hypnogram: window + per-epoch stages)
        > auto (van-Hees accel)
        > auto_fallback > none
```

The argument for it, stated as strongly as it can be:

- **A vendor hypnogram is not an opaque composite.** `readiness`, Body
  Battery, a sleep score out of 100 — those are numbers with no method we
  can describe, and the `key`/`vendorKey` split exists to fence them. A
  hypnogram is different in kind: it is a **window claim plus a per-epoch
  classification**, the same shape as our own `stages4` staging. It is a
  claim we can VALIDATE against our own staging, not a number we can only
  display.
- **The ring stages sleep ON the ring**, from its own multi-sensor array,
  with a firmware algorithm tuned by the vendor across their whole fleet.
  Our own staging (analytics `#34`) measured kappa 0.036 against PSG on
  DREAMT for the OLD rules; the rewrite improved it, but a ring that stages
  sleep natively is not obviously worse than our own re-derivation from 1 Hz
  accel — and it is a different algorithm answering the same question, which
  is exactly what the ownership machinery (per-`InputSignal` priority,
  primary-device default) already arbitrates.
- **User override stays on top.** `manual`/`confirmed` outrank everything
  except `rejected`; a vendor window the user corrects is corrected. The
  existing sleep-window override UI (`sleep_override` table,
  `sleep_detail.dart`) is the remedy surface, unchanged.

## What would have to be true before any of it ships

Not a checklist for this PR — the conditions the owners would impose, as
this document predicts them:

1. **A verified capture.** R6: the 0x4b/0x4e/0x5a hypnogram layout is
   confirmed against a Gen 3 Horizon capture by the open_oura project. No
   Ring 4/5 emission has been observed. No vendor-staged source ships
   before a ring this project owns has produced a hypnogram against this
   decoder.
2. **A consumer for the epoch series.** `db.dart`: "a vendor hypnogram is
   not a scalar and has no consumer — give it a table of its own when
   something is actually going to read it." A `vendor_staged` sleep source
   is that consumer; the table comes with the ruling, not before it.
3. **An isolation carve-out that is structural, not remembered.** If the
   rows are read into the pipeline, they leave `observation` for the new
   table on the day of the ruling — the read happens from the vendor
   hypnogram table, never from `observation` itself, so the isolation test
   keeps its teeth.
4. **Provenance travels.** A vendor-staged night renders with its
   attribution everywhere our own staging renders, the same way
   `observationsForDay` rows carry theirs. A vendor window shown as our own
   detection is the worst available outcome of this whole idea.

## What this proposal deliberately does NOT ask for

- Not a generic "trust vendor numbers" rule. One sleep source rung, one
  table, one consumer.
- Not a second staging algorithm in `analytics/` — `analytics` stays
  device-blind (OBSERVATION_SPEC §4); the vendor hypnogram enters at the
  `substrate`/pipeline layer as an already-staged input, the same layer the
  user override enters at.
- Not a change to ownership resolution. WHOOP-vs-Oura cannot conflict
  today: `_resolveOwnership` is per-`InputSignal`, default
  `[kPrimaryDeviceId]`, and the two never mix in one computation. A
  `vendor_staged` source inherits that machinery; it does not bypass it.

## Alternative this document owes the owners

Doing nothing is defensible and is the current state: the aggregates from
PR (sleep-stage vendor scalars) render in the day timeline with attribution,
the epoch frames stay in `raw_archive`, and a future owner can still build
this source from the banked bytes. The cost of waiting is zero bytes lost —
which is why this is a proposal and not an implementation.
