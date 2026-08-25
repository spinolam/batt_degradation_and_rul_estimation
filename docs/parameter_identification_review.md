# `src/identify_parameters/identify_model_parameters.m`

Offline, `lsqnonlin`-based fit of a static equivalent-circuit battery model (OCV curve, internal
resistance polynomial, first-order thermal model) from NASA RW1 discharge data (the in-scope
"Randomized Battery Usage" dataset — see `CLAUDE.md`). Independent of Simulink; its output
parameters feed the model used inside the Simulink diagrams in `src/models/`.

## What it does

**Data.** Reads two prepared CSVs for battery `RW1` from `data/constant/prepared/` (columns `time`,
`voltage_charger`, `current_load`, `temperature_battery`, `mode`):

- `RW1_low_current_prepared.csv`, mode `-1` — the freshest low-current (~0.04 A) discharge, spanning
  the full SOC range. At this current, `I*R` is negligible, so the measured voltage is close to a
  direct OCV(SOC) trace.
- `RW1_pulsed_prepared.csv`, modes `-1` through `-13` — the freshest HPPC-style pulse day: 13
  ~1 A, ~10-minute discharge pulses (separated by rest periods not present in this file) at
  progressively decreasing SOC. Every 3rd pulse (modes `-1, -4, -7, -10, -13`, 5 total) is used in the
  fit; the skipped ones overlap too heavily in SOC to be worth the added `lsqnonlin` runtime.

Extraction is via the local `extractDischarge` function (fields `X, V, V0, I, Z, T, T0`). Per-sample
SOC `Z` is computed by Coulomb counting (`Z0 = 99.5`, `capacity = 2.03` Ah, integrated forward one
sample at a time: `Z(k) = max(Z(k-1) - dt*100*I(k)/(3600*capacity), 0.001)`). `capacity` is the actual
charge removed over all 13 pulses of the day (integrating measured current, including the ones this
fit skips) — the 13th pulse ends early, at the real 3.2 V discharge cutoff, so this is a measured
value for this specific cell/day rather than the dataset's general nominal rating. For the pulse
train, each pulse's ending `Z` is passed as the next pulse's `Z0` — `extractDischarge` only resets
SOC at the `Z0` it's given, so without this chaining it can't see the charge already removed by the
pulses before it in the same day.

Combining both current levels in one fit is the point: a single constant-current trace can't
separate OCV(Z) from R(Z), because at one current level their contributions to voltage are linearly
dependent along the fit. The low-current segment pins down OCV(Z) on its own (`I*R` negligible); the
~25x larger pulse current then pins down R(Z) given that OCV.

**Model.** 10 parameters `p(1)..p(10)`:

- Open-circuit voltage: `OCV(Z) = p2 - p3*log(100-Z) - p4/Z`
- Internal resistance: `R(Z) = p5 + p6*Z + p7*Z^2` (degree-2 polynomial in SOC — deliberately not
  higher-order; see below)
- Terminal voltage: `V_k = p1*V_{k-1} + (1-p1)*(OCV(Z_k) - I_k*R(Z_k))`
- Battery temperature: `T_k = p8*T_{k-1} + (1-p8)*(p10 + p9*I_k^2*R(Z_k))` — `p10` is the ambient
  temperature (bounded `[16, 20]`, matching the room-temperature data) and `p9` is the Joule-heating
  coefficient.

`p1`/`p8` are first-order relaxation coefficients; `p1` is bounded to `[0, 0.9]` (fast electrical
relaxation), `p8` to `[0.9, 1]` (slow thermal relaxation). Both `V_{k-1}`/`T_{k-1}` are
**simulated**, not measured: `batteryErrorFunction` runs each segment open-loop from its true initial
sample (`V0`/`T0`) via the local `simulateAR` helper, feeding the model's own previous prediction back
in at every step — an output-error / simulation-error fit, not equation-error. This is what makes the
residual meaningful as a proxy for open-loop accuracy: the model has no access to ground truth after
the first sample, matching how the downstream Simulink/EKF observer in `src/estimate_degradation/`
will use it.

`R(Z)` is degree-2, not degree-4. The 5 pulse segments only cover disjoint SOC "islands" (roughly
91-99.5%, 66-74.5%, 41-49.6%, 16-24.6%, and one degenerate low-SOC point), with wide gaps between them
where only the low-current segment's negligible `I*R` weakly constrains `R(Z)`. A degree-4 fit was
free to wiggle in those gaps — it converged to two spurious local maxima (an "M" shape) with *lower*
resistance at both true endpoints (Z≈0 and Z≈99.5) than in the interior, the opposite of the expected
rise at SOC extremes. Degree-2 can't reproduce that wiggle; it converges to a single minimum around
Z≈81% (R≈0.14 Ω), rising toward both ends (R≈0.43 Ω at Z≈0, R≈0.16 Ω at Z≈99.5) — the physically
expected shape. The trade-off: with `R(Z)` less flexible, `p(1)` now saturates at its upper bound
(0.9) instead of settling around 0.34 as it did with the degree-4 fit — the electrical submodel is
carrying noticeably less of the voltage fit (physical-model weight `(1-p1)` down from ~66% to ~10%),
which `reportArCoefficient` flags. Fixing the resistance shape traded away some of the AR
diagnostic's headroom; it didn't eliminate the underlying identifiability limit from the sparse pulse
islands.

**Fit.** `batteryErrorFunction` stacks the voltage residuals for all six segments (1 low-current + 5
pulses), then the temperature residuals for the same six, into one vector; `lsqnonlin` minimizes it
jointly against the bounds `lb`/`ub`, starting from a fixed `params0`.

**Outputs.**
- `params_opt`, `resnorm` printed to the console.
- A post-fit diagnostic (`reportArCoefficient`) for `p(1)` and `p(8)`: their value against
  `[lb, ub]`, the implied physical-model weight `(1-p)`, and a warning if the coefficient sits
  within 2% of its bound — that's the case where the OCV/R (or thermal) submodel is contributing
  little to the fit and the residual/plots shouldn't be read as validating it.
- A post-fit parameter-uncertainty table (`reportParameterUncertainty`): standard error, an
  approximate 95% CI, and coefficient of variation for each parameter, from the Gauss-Newton
  covariance `sigma^2 * pinv(J'*J)` using `lsqnonlin`'s returned Jacobian. Parameters sitting at a
  bound are flagged instead of given a confidence interval, since the covariance approximation isn't
  valid there.
- Plots: raw signal overview from the pulse data (figure 1); measured vs. model voltage for the
  low-current segment (figure 3) and for one pulse segment (figure 7); resistance-vs-SOC curve
  (figure 4); OCV-vs-SOC curve (figure 5, both from the low-current segment's SOC range); measured vs.
  model temperature for the last (lowest-SOC) pulse segment (figure 6) — the pulse segments carry
  most of the Joule-heating signal, so the temperature fit is shown against one of them rather than
  the low-current segment.

## What it does not do

- **One battery, one fixed set of segments.** `battery_name = 'RW1'` and the specific mode selections
  are hardcoded; there's no loop over the other RW batteries in `data/constant/prepared/`
  (`RW2`...`RW28`) or over a different characterization day.
- **Both AR coefficients now sit at a bound.** `p(8)` (thermal) converges to `~0.999`, within 2% of
  its `[0.9, 1]` upper bound, even with the ~1 A pulse data contributing much stronger Joule-heating
  excitation than a low-current-only fit would. This looks like a genuine limit of how much a
  first-order lumped thermal model can extract from ten-minute pulses — a longer high-current hold, or
  a higher-order thermal model, would likely be needed to move it off the bound. `p(1)` (voltage) now
  converges to its bound too (`0.9`), as a direct consequence of restricting `R(Z)` to degree-2 (see
  above) — `reportArCoefficient` flags both.
- **The uncertainty table is optimistic.** `reportParameterUncertainty`'s Gauss-Newton covariance
  assumes independent residuals. The output-error simulation makes consecutive residuals serially
  correlated (each sample's error carries over via the AR feedback), and the fit is packed into only
  six long continuous segments — so the true parameter uncertainty is larger, likely by a wide margin,
  than the reported standard errors.
- **No held-out validation.** The same segments used to fit the parameters are also used to produce
  the validation plots.
- **Fixed AR coefficients, not time constants.** `p1`/`p8` are plain scalars, not scaled by the
  per-sample `dt` used in the SOC integration — an implicit uniform-sampling assumption.
- **`params0` provenance is undocumented beyond order-of-magnitude reasoning.** The 10-element initial
  guess is picked to be in the right ballpark for a single Li-ion cell (OCV ~3.2-4.2 V, R ~0.1 Ω,
  ambient ~18 C) but isn't derived from any prior fit; it materially affects which local minimum
  `lsqnonlin` converges to.
- **The rest periods between pulses aren't used.** `RW1_pulsed_prepared.csv` only contains discharge
  samples (current > 0); the relaxation voltage during each pulse's rest period — which would give a
  much cleaner, near-model-free R(Z) estimate via the instantaneous voltage step at pulse onset — isn't
  available in this file and isn't used here. The pulse contribution to this fit is a joint,
  model-based one (through the same output-error `lsqnonlin` fit as the low-current segment), not a
  simple `ΔV/ΔI` calculation.
