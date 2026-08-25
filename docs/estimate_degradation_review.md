# `src/estimate_degradation/`

Simulation drivers that run the fitted equivalent-circuit model (from `src/identify_parameters/`)
forward through an observer to estimate SOC and the degradation parameter `gamma` online. Two
regimes, two subtrees (see `CLAUDE.md`):

**Update — the refactoring proposed below has been applied.** All items marked `[DONE]` are reflected
in the current code; the findings themselves are left as written (they describe the state this review
was written against) with a status note added to each. Only item 8 (persistent-state functions →
`classdef`) remains unapplied, by design — it's the one item flagged as optional/lower-priority.

- **Top level** (`run_discharge_with_kf_real_data_new_parameters_new.m`) —
  constant-current pipeline, single robust observer gain, Simulink-only.
- **`random_walk/`** — the primary, random-walk pipeline, gain-scheduled LPV observer, with two
  interchangeable execution paths (Simulink-driven and pure-MATLAB).

## Inventory

| File | Role |
|---|---|
| `run_discharge_with_kf_real_data_new_parameters_new.m` | Complete constant-current driver: loops batteries × discharge cycles, runs `estimation_data_with_new_parameter_new.slx`, accumulates + saves per-battery results |
| `init_simulation_accumulator.m` | *(new)* Empty per-battery result accumulator (shared) |
| `accumulate_cycle_results.m` | *(new)* Appends one cycle's `sim()` output to the accumulator (shared) |
| `save_simulation_results.m` | *(new)* Writes the accumulator to `results/<date>/<date>_<battery>.mat` (shared) |
| `random_walk/lqr_synthesis_observer_gain_scheduled_lpv.m` | CVX/LMI synthesis of the 4 polytope-vertex observer gains `L1..L4` |
| `random_walk/calcule_l_observer.m` | Bilinear (tensor-product) interpolation of `L1..L4` at runtime from `(rho1, rho2)`, clamped to the polytope |
| `random_walk/battery_twin.m` | Ground-truth plant simulation (persistent state, needs `reset`) |
| `random_walk/observer_lpv.m` | LPV state observer, state `x = [gamma; SOC; V]` (persistent state, needs `reset`) |
| `random_walk/voc_fun.m` | OCV(SOC) curve — now `voc_fun(z, params)`, shared by `battery_twin.m`/`observer_lpv.m` |
| `random_walk/rint_fun.m` | *(new)* R(SOC) curve — shared by `battery_twin.m`/`observer_lpv.m` |
| `random_walk/run_discharge_random_simulink.m` | Simulink-driven driver over pre-segmented `ref_discharges` cycles |
| `random_walk/simulate_discharge_cycle.m` | *(new)* Shared per-cycle sample loop for the two pure-MATLAB drivers below |
| `random_walk/plot_discharge_results.m` | *(new)* Shared figure set for the two pure-MATLAB drivers below |
| `random_walk/simulate_random_discharge_matlab.m` | Pure-MATLAB driver over the raw `random_walk_discharge` log (manually re-segmented into cycles) |
| `random_walk/simulate_reference_discharge_matlab.m` | Pure-MATLAB driver over the same pre-segmented `ref_discharges` cycles as the Simulink driver |

`run_discharge_random.m` (the unfinished stub described below) has been deleted — see item 5.

## What it does

**Constant-current driver.** `run_discharge_with_kf_real_data_new_parameters_new.m` loads a
battery's prepared CSV (or, for `battery_name == "random"`, a `.mat` with a differently-shaped
`step` struct — a special case bolted onto the same loop), synthesizes the single robust gain via
`src/models/lqr_synthesis_observer_simple_Lx3x3_no_VOC.m`, then for every discharge cycle (`mode ==
-i`) builds four base-workspace `timeseries` and runs `estimation_data_with_new_parameter_new.slx`.
Per-cycle outputs (`gammaf`, `gammaf_est`, `soc`, `soc_est`, `vt`, `vt_est`, `temperature`,
`temperature_est`, `current_input`) are concatenated across cycles, plus a derived Coulomb-counted
`capacity_vector` and `count_cycle` index, and saved to `results/<date>/<date>_<battery>.mat`.

**Gain-scheduled LPV synthesis.** `lqr_synthesis_observer_gain_scheduled_lpv.m` poses the observer
design as an LMI over a 2-D polytope in `(rho1, rho2) = (-I, -R(SOC)*I)`, with 4 corner models
`A1..A4` (one per combination of `{pho1_min, pho1_max} × {pho2_min, pho2_max}`) and a shared `Q`/`R`
cost, solved once for a shared Lyapunov `P` and per-vertex `Y1..Y4` via `cvx_begin sdp`. Output is
`L = [L1 L2 L3 L4]`. `calcule_l_observer.m` then reproduces the same 4-vertex bilinear weighting at
runtime from the instantaneous `(rho1, rho2)` to interpolate a time-varying gain `L_k`.

**Plant twin / observer pair.** `battery_twin.m` forward-simulates the "true" plant (OCV/R/thermal
model, no noise injected) as ground truth; `observer_lpv.m` runs the corresponding LPV state-space
form `x = [gamma; SOC; V]` with correction `L*error`. Both are plain functions using `persistent`
state instead of objects, each with a `reset` flag as their last argument that must be called once
per cycle — this is the mechanism, not a MATLAB idiom incidental to the design.

**Two execution paths, same model.** `run_discharge_random_simulink.m` drives this same model via
`estimation_random.slx`, one `sim()` call per cycle of `ref_discharges`, with the same
accumulate-and-save shape as the constant-current driver. `simulate_random_discharge_matlab.m` and
`simulate_reference_discharge_matlab.m` instead call `battery_twin`/`observer_lpv`/
`calcule_l_observer` directly in a sample-by-sample `for k = 1:n_samples` loop — no Simulink — over,
respectively, the raw `random_walk_discharge` log (manually grouped into cycles by `cycleNum`) and
the already-segmented `ref_discharges`. Both pure-MATLAB drivers end in the same four-plot
visualization (SOC/voltage/temperature twin-vs-estimate, gamma vs. time, R_int vs. SOC, gamma across
all cycles).

## Findings

### Correctness

- **Likely bug in the LMI vertex definitions** (`lqr_synthesis_observer_gain_scheduled_lpv.m:35-37`).
  The four vertices should tile `{pho1_min, pho1_max} × {pho2_min, pho2_max}`, matching
  `calcule_l_observer.m`'s `mu1..mu4` (which pairs `w1` from `pho1` with `w2` from `pho2`). `A1`,
  `A3`, `A4` follow that pattern (`eta*pho1_min` or `eta*pho1_max` in the `(2,1)` entry, which is the
  `pho1`-dependent term), but `A2` uses `eta*pho2_min` instead of `eta*pho1_min`:
  ```
  A2 = [b 0 0;
      eta*pho2_min 1 0;      % should be eta*pho1_min
     (1-a)*pho2_max 0 a];
  ```
  `pho1_min = -1` and `pho2_min = -0.2` (given `Idescargamin=1`, `Rmin=0.2`) are numerically
  different, so this isn't a harmless alias — vertex `A2` (nominally `(pho1_min, pho2_max)`) is
  actually built from `(pho2_min, pho2_max)`, i.e. the wrong corner of the polytope. The LMI still
  solves (it's still a valid, if wrong, set of constraints), so this fails silently — no error, just
  a `L2` gain synthesized for a corner of state-space the real system doesn't visit at that vertex,
  and the true `(pho1_min, pho2_max)` corner left uncertified. Worth fixing and re-synthesizing before
  trusting `L2`/the interpolated gain near that region. *(Fixed — refactoring #1.)*
- **`battery_twin.m:39` sensor noise is dead**: `noise = randn*0;` — always exactly zero. The
  variable name and the surrounding "sensor model" comment imply noise is injected; it never is. If
  this is deliberate (deterministic twin for now), fine, but as written it reads as disabled
  instrumentation rather than a design choice — worth a comment or removing the `*0` and wiring a
  real noise level through the function's arguments. *(Not addressed — wasn't in the numbered
  proposal; whether the twin should be deterministic is a design call, not a refactor.)*
- **`voc_fun.m` is broken as written** (per its own header comment) — references `params`/`zk`, which
  are neither its arguments (`z`) nor in scope. Already flagged as dead/unwired by a previous author;
  not currently a risk since nothing calls it, but see "Duplication" below — it's the natural home for
  a formula that's currently triplicated. *(Fixed — refactoring #2.)*
- **Stale doc reference**: `lqr_synthesis_observer_gain_scheduled_lpv.m:5` points to
  `random_walk/README.md` for more context — that file doesn't exist in this repo. *(Fixed — refactoring #9.)*

### Duplication / dead code

- **OCV and R(SOC) formulas are triplicated.** The same `voc = params(2) - params(3)*log(100-zk) -
  params(4)/zk` appears in `battery_twin.m:27`, `observer_lpv.m:33`, and (broken) `voc_fun.m:7`; the
  same `rint` degree-4 polynomial appears in `battery_twin.m:28` and `observer_lpv.m:34`. A future
  change to either curve (e.g. picking up the `log_tanh` OCV variant already explored in
  `identify_model_parameters.m`) has to be applied in two or three places by hand, with no compiler
  help if one is missed. *(Fixed — refactoring #2.)*
- **The accumulate-and-save boilerplate is duplicated across three drivers** almost verbatim:
  `run_discharge_with_kf_real_data_new_parameters_new.m:56-121`,
  `run_discharge_random_simulink.m:38-102` — same variable list, same `mkdir`/`save` pattern, same
  `count_cycle`/`capacity_vector` derivation from `r.current_input`. *(Fixed — refactoring #3.)*
- **`simulate_random_discharge_matlab.m` and `simulate_reference_discharge_matlab.m` are ~90% the
  same script** — identical per-sample loop calling `battery_twin`/`calcule_l_observer`/
  `observer_lpv`, identical early-stop-at-3.2V logic, identical four-figure visualization block. They
  differ only in how `dataOut` is built/indexed (raw log grouped by `cycleNum` vs. pre-segmented
  `ref_discharges`), the cycle-count cap (hardcoded `for i = 1:5` vs. `for i = 1:1`), and that only the
  "reference" variant captures `voc` (6th output of `battery_twin`) into `cycle_result.twin.voc` — the
  "random" variant preallocates `twin_voc` (line 102) but never fills or stores it, and the two
  scripts' `cycle_result` structs end up with different fields for what should be the same computation.
  *(Fixed — refactoring #4.)*
- **`run_discharge_random.m` is a dead stub.** It duplicates
  `run_discharge_with_kf_real_data_new_parameters_new.m`'s setup verbatim (same data-loading branch,
  same settings) but replaces the `for i = 1:max_cycle` loop with a single hardcoded window
  (`mask_chosen(3:303)=1`) and stops before calling `sim`/`save`. Already called out as an
  "in-progress variant" in `CLAUDE.md`; as it stands it's unreachable dead weight, not a working
  reduced-scope tool. *(Fixed — refactoring #5: deleted.)*
- **Unused outputs**: `rho1m`/`rho2m` returned by `observer_lpv.m` are captured by both pure-MATLAB
  drivers but never read. `seed`/`h_mean` are set in `run_discharge_random_simulink.m` (and the two
  constant-current drivers) but never referenced afterward — likely leftover from an earlier version
  that generated synthetic random currents rather than reading logged ones. *(Partially addressed:
  `rho1m`/`rho2m` are now `~`-discarded in `simulate_discharge_cycle.m` as a side effect of
  refactoring #4. `seed`/`h_mean` weren't in the numbered proposal and remain unused — harmless as-is.)*

### Robustness gap

- **No saturation of the scheduling variables in `calcule_l_observer.m`.** `w1`/`w2` are computed by
  linearly rescaling the live `(pho1, pho2)` against the synthesis-time bounds, but never clamped to
  `[0, 1]`. If the actual current or resistance at runtime falls outside `[Idescargamin,
  Idescargamax]` / the corresponding `R`-scaled range assumed in
  `lqr_synthesis_observer_gain_scheduled_lpv.m`, `mu1..mu4` extrapolate outside the vertex simplex
  (can go negative or exceed 1), producing an interpolated gain with no LMI stability guarantee — the
  one thing the gain-scheduled design is supposed to provide over the single robust gain.
  *(Fixed — refactoring #6.)*

### Consistency / minor

- Magic numbers (`Cr = 2.5`, `z0 = 99.5`, cutoff voltage `3.2`) are hardcoded identically in both
  pure-MATLAB drivers rather than defined once. *(Fixed — refactoring #7.)*
- Mixed-language comments (Spanish in `calcule_l_observer.m` and the LMI script, English elsewhere)
  and `pho` for `rho` throughout — cosmetic, but worth standardizing if these files get touched again.
  *(Not addressed — cosmetic, wasn't in the numbered proposal.)*
- `date` is used as a plain string variable name in every driver, shadowing the builtin `date()` —
  harmless here since it's always assigned before use, but a landmine if a future edit reads `date`
  before assigning it. *(Not addressed — same reason.)*

## Proposed refactoring

Ordered roughly by priority (correctness first, then duplication, then structural).

1. **`[DONE]` Fix the `A2` vertex bug** in `lqr_synthesis_observer_gain_scheduled_lpv.m` (`eta*pho2_min` →
   `eta*pho1_min`). Re-verified by re-running the CVX synthesis after the fix — it still solves
   (`cvx_status` = `Solved`/`Inaccurate Solved`), now against the correct four corners.
2. **`[DONE]` Factor `voc`/`rint` into shared functions.** `voc_fun(z, params)` now takes `params` as
   an argument and a matching `rint_fun(z, params)` was added; both `battery_twin.m` and
   `observer_lpv.m` call them instead of inlining the formulas. Verified the extracted functions
   return bit-identical values to the original inline expressions.
3. **`[DONE]` Extract the accumulate-and-save step** into `init_simulation_accumulator.m` /
   `accumulate_cycle_results.m` / `save_simulation_results.m` (living in `src/estimate_degradation/`,
   `addpath`-referenced from `random_walk/run_discharge_random_simulink.m`), used by both
   `run_discharge_with_kf_real_data_new_parameters_new.m` and `run_discharge_random_simulink.m`.
   `save_simulation_results.m` uses `save(save_name, '-struct', accum)` so the on-disk `.mat` schema
   (one top-level variable per accumulator field, same names/values) is unchanged — verified with a
   save/load round-trip test against manually-computed expected values.
4. **`[DONE]` Merge the two pure-MATLAB drivers'** per-sample loop into `simulate_discharge_cycle.m`
   and their figures into `plot_discharge_results.m`; `simulate_random_discharge_matlab.m` and
   `simulate_reference_discharge_matlab.m` are now thin drivers that only differ in data
   loading/segmentation and their cycle-skip condition. This fixes the `twin.voc` field inconsistency
   (both now always populate it) as a side effect, and as part of the merge the early-stop condition
   was standardized to the more conservative of the two originals (`Vtrue <= cutoff || Vm <= cutoff`).
   Verified the new per-cycle function reproduces a hand-inlined copy of the original loop exactly,
   sample for sample, on synthetic data.
5. **`[DONE]` Resolved `run_discharge_random.m` → deleted.** Confirmed with the user (dead/unreachable
   stub, fully superseded by `run_discharge_with_kf_real_data_new_parameters_new.m`); references to it
   in `CLAUDE.md` were updated accordingly.
6. **`[DONE]` Add saturation to `calcule_l_observer.m`**: `w1`/`w2` are now clamped to `[0, 1]` before
   computing `mu1..mu4`. Verified with an out-of-envelope test case that the clamped result exactly
   equals the nearest vertex gain (`L1`) rather than an extrapolated value.
7. **`[DONE]` Centralize the shared physical constants** (`Cr`, `z0`, cutoff voltage) — folded into
   the `cfg` struct (`cfg.Cr`, `cfg.z0`, `cfg.gamma0`, `cfg.voltage_cutoff`) introduced as part of
   item 4, passed into `simulate_discharge_cycle.m` instead of being re-typed in each driver.
8. **Not done — left optional, as originally scoped.** Replacing the `persistent`-state function
   pairs (`battery_twin.m`, `observer_lpv.m`) with a `classdef` is a larger, riskier change with a
   purely stylistic payoff; skipped unless requested.
9. **`[DONE]` Fixed the stale `random_walk/README.md` reference in
   `lqr_synthesis_observer_gain_scheduled_lpv.m`'s header comment — now points at `CLAUDE.md` and
   `docs/estimate_degradation_approach.md`.

All of the above (except item 8) has been applied and, where testable without the (gitignored, not
present in this checkout) `data/random_walk_data/` files or a full Simulink run, verified against the
pre-refactor logic — see the individual commit/notes above for what each check covered. Items 1 and 2
were the ones with actual behavioral consequences (a wrong gain vertex; a formula that could silently
drift out of sync between two files); the rest were maintainability cleanups.
