# Review: `src/identify_parameters/`

Reviewed files:

- `identify_model_parameters_nonlinear_all_random_data.m`
- `identify_model_parameters_random_walk.m`
- `identify_model_parameters_random_walk_only_one.m`

All three fit the same equivalent-circuit model — OCV(SOC), an internal-resistance polynomial in
SOC, and (in the first script) a first-order thermal model — via `lsqnonlin`, from constant-current
discharge segments. Findings below are ordered by severity and were checked by actually running each
script with `matlab -batch`, not just read from source.

## 1. `identify_model_parameters_random_walk.m` is broken as written

Running it fails immediately:

```
Unrecognized field name "mode".
Error in identify_model_parameters_random_walk (line 54)
mask_chosen2=battery_data.mode==-3;
```

The script loads the raw `data/constant/low_current.mat` directly (`fields: I, RT, V` — confirmed
with Octave), which has no `mode` column. `mode` only exists in the *derived* CSV that
`src/data_prep/prepara_random_data.m` writes to `data/constant/prepared/low_current_prepared.csv`
(confirmed: its header is `time,voltage_charger,current_load,temperature_battery,mode`). This script
needs to load that prepared CSV — the way
`identify_model_parameters_nonlinear_all_random_data.m` loads `prepared data/battery01.csv` — instead
of the raw `.mat`. As it stands, this script cannot run at all.

Once that's fixed, a second problem surfaces in the same file: `Y1`/`Z` (the first of the three
discharge segments) is never filtered by `mode` — `chosen_discharge` and `mask_discharge` are
assigned but never applied. So `Y1` runs over the *entire* unfiltered signal, not one discharge
cycle, while `Y3`/`Y4` correctly filter on `mode==-3`/`mode==-4`. Combined with the Coulomb-counting
loop that initializes SOC to 99.5% once and integrates monotonically downward (see below), this means
`Z` for the `Y1` segment is only meaningful for whatever the first cycle happens to be — every
subsequent discharge cycle concatenated into that same unfiltered stream gets Coulomb-counted as if
it were a continuous discharge starting near 99.5%, which is wrong SOC labeling for anything after
cycle 1. This looks like an abandoned "select one discharge cycle" feature, not an intentional design
choice (contrast with `..._only_one.m`, whose filename and lack of any `mode` usage make clear that
using the whole file unfiltered *is* the intended behavior there).

**Fix**: load the prepared CSV, and either wire up `mask_discharge`/`chosen_discharge` to filter `Y1`
by a specific `mode`, or drop the unused variables if the intent really is "whole file, one blob."

## 2. The AR/smoothing formulation lets the optimizer bypass the physical model

All three scripts predict voltage (and, in script 1, temperature) as:

```
V_k = a*Y_{k-1} + (1-a)*(OCV(Z_k) - I_k*R(Z_k))
```

using the **actual measured** previous sample `Y_{k-1}`, not the model's own previous prediction.
This is an equation-error / one-step-ahead regression, not the output-error recursive simulation the
fitted parameters will presumably run under once embedded in the Simulink/EKF observer (per this
project's `src/estimate_degradation/` pipeline, which doesn't get to peek at ground truth each step).
That mismatch matters here because it's not just theoretical — it's what the optimizer actually did:

- In `identify_model_parameters_random_walk_only_one.m`, the fitted `a` (`params_opt(1)`) converges to
  **exactly 0.99**, the upper bound (`ub(1)=0.99`) — verified by running it. The optimizer is pushed
  to the wall trying to weight the previous real sample as heavily as allowed, i.e. "copy last
  measurement" beats the physical OCV−IR term almost everywhere in the loss. With `(1-a)=0.01`, the
  OCV coefficients carry almost no leverage, and indeed they drift far from both the initial guess and
  from script 1's fitted values for a comparable curve (`p3` initial guess `0.05` → fitted `-6.25`;
  `p4` initial guess `0.32` → fitted `0.41`) — a sign of a nearly unidentifiable/collinear parameter
  once `a` saturates.
- The reported `resnorm` (0.057 over ~19,000 samples) looks like an excellent fit, but with `a=0.99`
  most of that accuracy is "the model is 99% equal to the true previous sample," not evidence the
  OCV/R submodel tracks the battery well.
- In `identify_model_parameters_nonlinear_all_random_data.m`, the analogous thermal AR coefficient
  `p(10)` converges to `0.9992` (bound `[0.9, 1]`), again pinned near the ceiling — the Joule-heating
  term (`p(11)`, `p(12)`) ends up weighted by only `~0.0008`, so it's weakly identified from a single
  short low-current discharge, where temperature barely moves anyway.
- A consequence: the validation plots (figs 3/6 in script 1, fig 3 in scripts 2/3) will look very
  close to measured data almost regardless of the OCV/R model's quality, because the reconstruction
  itself is seeded with the true previous voltage at every step — they don't demonstrate open-loop
  predictive accuracy.

If the intent is genuinely to fit a smoothing filter on top of the physical model (plausible if it's
meant to absorb double-layer relaxation), consider tightening the upper bound on `a` well below 1, or
— better — refit/validate using **output-error** simulation (feed back the model's own previous
prediction, not `Y_{k-1}`) so the reported fit quality reflects what the deployed
observer will actually see.

## 3. SOC/Coulomb-counting loop is `O(n²)` and duplicated three times

In all three scripts, the SOC loop is written as:

```matlab
for k = 2:length(Z)
    dt = X(k) - X(k-1);
    Z(k:end) = Z(k-1) - dt*100*I(k)/(3600*capacity);
    Z(Z < 0.001) = 0.001;
end
```

`Z(k:end) = ...` rewrites the *entire remaining tail* on every iteration instead of just `Z(k)`. It's
functionally harmless (each later iteration overwrites the stale tail again), but it's `O(n²))`
instead of `O(n)`. For `low_current.mat` (~19,000 samples) that's on the order of 19,000² ≈ 360M
scalar writes for one segment alone, repeated on every `lsqnonlin` iteration/function evaluation —
plausibly why the `..._only_one.m` run above took visibly longer per iteration than script 1's
smaller segments. Simple fix: `Z(k) = max(Z(k-1) - dt*100*I(k)/(3600*capacity), 0.001);`.

This same block (extract-discharge + Coulomb-count) is implemented three times: once refactored into
a local function (`extractDischarge` in script 1) and twice more copy-pasted inline (scripts 2 and 3,
which also duplicate each other almost verbatim). Any fix — including the `O(n²)` one above and the
`mode`-filtering bug in §1 — currently has to be applied in multiple places by hand. Worth factoring
into one shared function (e.g. under a `src/identify_parameters/` or project-wide `+utils` helper)
that all three scripts call.

## 4. Minor / style

- **Confusing signal naming in script 1**: temperature vectors for discharge segments 1/3/4 are named
  `Y2/Y2m1`, `Y5/Y5m1`, `Y6/Y6m1` — offset by an unrelated index from their paired voltage vectors
  `Y1`, `Y3`, `Y4`. It works today, but if a fourth discharge segment or a reordering of
  `batteryErrorFunction`'s arguments is ever added, this numbering makes it easy to pass the wrong
  temperature/voltage pair. A struct-of-segments (or a table per discharge) would remove the
  index-matching burden.
- **Unexplained magic numbers**: `params0` in script 1 is a 12-element vector of specific decimals
  with no comment on provenance (a prior `params_opt`? a hand guess?). Worth a one-line comment
  either way, since it materially affects which local minimum `lsqnonlin` lands in.
- **Single hardcoded battery**: script 1 only ever fits `battery01.csv`, even though `prepared data/`
  holds several batteries (`battery00`, `battery10`, `battery11`, `battery20`, …). If per-battery (or
  cross-battery) parameters are eventually needed, this would need to become a loop — flagging as a
  scope gap rather than a bug, since a single-battery fit may be the current intent.
- `ub(2)=8.6` in script 1: the fit lands at `8.5872`, close to (though not touching) that ceiling.
  Not proven to be a problem, but worth a quick check with the bound relaxed to confirm `8.6` isn't
  quietly clipping the true optimum.

## Summary

| # | Finding | Confidence |
|---|---|---|
| 1 | `identify_model_parameters_random_walk.m` crashes — loads raw `.mat` lacking `mode`; also has an unfiltered/dead-code discharge segment | Confirmed by running it |
| 2 | AR blending with the true previous sample lets `lsqnonlin` saturate the smoothing coefficient at its bound, weakening identification of the physical OCV/R (and thermal) parameters | Confirmed by running scripts 1 and 3 |
| 3 | `O(n²)` SOC loop, duplicated 3×, instead of a shared `O(n)` helper | Confirmed by reading + timing behavior |
| 4 | Naming, magic numbers, single-battery scope, one near-bound parameter | Style/observational |
