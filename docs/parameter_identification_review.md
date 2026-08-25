# `src/identify_parameters/identify_model_parameters.m`

Offline, `lsqnonlin`-based fit of a static equivalent-circuit battery model (OCV curve, internal
resistance polynomial, first-order thermal model) from constant-current discharge data. Independent
of Simulink; its output parameters feed the model used inside the Simulink diagrams in
`src/models/`.

## What it does

**Data.** Reads `prepared data/battery01.csv` (shared, parent-level folder), a table with columns
`time`, `voltage_charger`, `current_load`, `temperature_battery`, `mode`. Extracts three discharge
segments by `mode == -2, -3, -4` into a `seg(1:3)` struct array (fields `X, V, V0, I, Z, T, T0`),
via the local `extractDischarge` function. For each segment, per-sample state of charge `Z` is
computed by Coulomb counting: `Z0 = 99.5`, `capacity = 2.5` Ah, integrated forward one sample at a
time (`Z(k) = max(Z(k-1) - dt*100*I(k)/(3600*capacity), 0.001)`, with `dt` the actual timestamp gap
between samples).

**Model.** 12 parameters `p(1)..p(12)`:

- Open-circuit voltage: `OCV(Z) = p2 - p3*log(100-Z) - p4/Z`
- Internal resistance: `R(Z) = p5 + p6*Z + p7*Z^2 + p8*Z^3 + p9*Z^4` (degree-4 polynomial in SOC)
- Terminal voltage: `V_k = p1*V_{k-1} + (1-p1)*(OCV(Z_k) - I_k*R(Z_k))`
- Battery temperature: `T_k = p10*T_{k-1} + (1-p10)*(p12 + p11*I_k^2*R(Z_k))` — `p12` is fixed at 23
  (ambient temperature, `lb=ub=23`) and `p11` is the Joule-heating coefficient.

`p1`/`p10` are first-order relaxation coefficients; `p1` is bounded to `[0, 0.9]` (fast electrical
relaxation), `p10` to `[0.9, 1]` (slow thermal relaxation). Both segments' `V_{k-1}`/`T_{k-1}` are
**simulated**, not measured: `batteryErrorFunction` runs each segment open-loop from its true
initial sample (`V0`/`T0`) via the local `simulateAR` helper, feeding the model's own previous
prediction back in at every step — an output-error / simulation-error fit, not equation-error. This
is what makes the residual meaningful as a proxy for open-loop accuracy: the model has no access to
ground truth after the first sample, matching how the downstream Simulink/EKF observer in
`src/estimate_degradation/` will use it.

**Fit.** `batteryErrorFunction` stacks the voltage residuals for all three segments, then the
temperature residuals for all three segments, into one vector; `lsqnonlin` minimizes it jointly
against the bounds `lb`/`ub`, starting from a fixed `params0`.

**Outputs.**
- `params_opt`, `resnorm` printed to the console.
- A post-fit diagnostic (`reportArCoefficient`) for `p(1)` and `p(10)`: their value against
  `[lb, ub]`, the implied physical-model weight `(1-p)`, and a warning if the coefficient sits
  within 2% of its bound — that's the case where the OCV/R (or thermal) submodel is contributing
  little to the fit and the residual/plots shouldn't be read as validating it.
- Plots: raw signal overview (figure 1); measured vs. model voltage for the `mode==-3` segment
  (figure 3); resistance-vs-SOC curve (figure 4); OCV-vs-SOC curve (figure 5); measured vs. model
  temperature for the `mode==-4` segment (figure 6).

## What it does not do

- **One battery, one fixed set of segments.** `battery_name = 'battery01.csv'` and
  `modeIDs = [-2 -3 -4]` are hardcoded; there's no loop over the other batteries present in
  `prepared data/` (`battery00`, `battery10`, `battery11`, `battery20`, …) or over a different number
  of discharge segments.
- **The output-error switch changed the fitted values, as expected.** Refitting with simulation
  (instead of the earlier equation-error form that blended in the true previous sample) moved
  `p1` from `0.60` to `0.39` — no longer close to its bound — and raised the physical-model weight
  `(1-p1)` from `0.40` to `0.61`; `resnorm` rose from `4.22` to `~665`, because it now measures
  accumulated open-loop drift over hundreds of samples per segment instead of a one-step-ahead
  prediction partly anchored to ground truth. `p10` (thermal) still converges to `0.999`, right at
  its bound, *even under output-error* — this looks like a genuine identifiability limit of a single
  short low-current discharge (temperature barely moves), not an artifact of the old method. The
  `p1`/`p10` diagnostic still exists to flag this on future refits.
- **No held-out validation.** The same three segments are used both to fit the parameters and to
  produce the validation plots.
- **Fixed AR coefficients, not time constants.** `p1`/`p10` are plain scalars, not scaled by the
  per-sample `dt` used in the SOC integration — an implicit uniform-sampling assumption. This is a
  reasonable simplification for the current data (`prepared data/battery01.csv`'s `mode==-3` segment
  samples at ~0.99 s ± 0.018 s), but would need revisiting on data with more irregular sampling.
- **`params0` provenance is undocumented.** The 12-element initial guess is a fixed vector with no
  comment on where its values came from, even though it materially affects which local minimum
  `lsqnonlin` converges to.
