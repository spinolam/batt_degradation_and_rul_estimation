# Battery Degradation and RUL Estimation (2025)

MATLAB/Simulink project for estimating a battery degradation parameter ("gamma") using an LPV/EKF-style
observer, and for identifying the underlying equivalent-circuit model parameters (OCV curve, internal
resistance polynomial, thermal model) from discharge data. Data comes from real battery cycling logs and
from NASA's public "Randomized Battery Usage Data Set".

This `2025/` folder is one year of a larger, multi-year project rooted at its parent directory
(`batt_gamma_estimation/`). The parent also contains `2024/` (a prior year's parallel code/results, treated
as frozen research history), a shared `prepared data/` folder, a separate `data/` ("battery_alt_dataset"),
and `figures/`. Only the parent-level `prepared data/` folder is an active dependency of the scripts here.

There is no build system, package manager, linter, or test suite — this is a MATLAB scripting project run
interactively from the MATLAB GUI or command line (`matlab -batch "scriptname"`).

## Requirements

- MATLAB with Simulink
- [CVX](https://cvxr.com/cvx/) convex-optimization toolbox (required by the observer synthesis script)

## Layout

```
2025/
├── data/
│   ├── raw/randomized_battery_usage/   # third-party NASA dataset, read-only
│   └── random/                          # synthetic/randomized-usage .mat inputs
├── src/
│   ├── models/                          # .slx Simulink models + the LQR/LMI observer synthesis script
│   ├── data_prep/                       # raw -> labeled charge/discharge data
│   ├── identify_parameters/             # offline equivalent-circuit parameter fitting (lsqnonlin)
│   ├── estimate_degradation/            # simulation drivers (run the Simulink model per cycle)
│   └── plot_results/                    # load results/<date>/ and plot
├── results/<date>/                      # one .mat per battery per experiment date
└── docs/Planning.md
```

## Path handling

Every script under `src/` computes its own project root at the top via
`fileparts(fileparts(mfilename('fullpath')))` (script's own folder → `src/` → `2025/`), then builds all data
paths with `fullfile(proj_root, ...)`. This makes scripts independent of MATLAB's current folder — you can
run any script regardless of what directory is currently active. When a script needs the shared
parent-level `prepared data/` folder, it also computes `parent_root = fileparts(proj_root)`.

## Workflow

Typical order of operations:

1. **Synthesize the observer gain** — `src/models/lqr_synthesis_observer_simple_Lx3x3_no_VOC.m`. Requires
   CVX (`cvx_startup`, `cvx_begin sdp`) to solve the polytopic LMI and produce the observer gain `L3`.
   Invoked via `run(fullfile(models_dir, ...))` from inside the `estimate_degradation/` drivers — no need
   to have it on the MATLAB path.
2. **Prepare random/raw data** — `src/data_prep/prepara_random_data.m` turns raw randomized-usage data
   (`data/random/*.mat`) into a labeled charge/discharge dataset (adds a `mode` column via `bwlabel`),
   writing to the parent-level `prepared data/` folder (shared with `2024/`).
3. **Identify model parameters** (optional, offline) — scripts in `src/identify_parameters/` fit OCV +
   internal resistance polynomial + thermal model coefficients from discharge segments via `lsqnonlin`.
   `identify_model_parameters_nonlinear_all_random_data.m` reads from the parent-level `prepared data/`;
   `identify_model_parameters_random_walk*.m` read from `data/random/`.
4. **Run the degradation-estimation simulation** — `src/estimate_degradation/run_discharge_random.m` or
   `run_discharge_with_kf_real_data_new_parameters_new.m`. These loop over cycles/batteries, run the
   Simulink model via `sim(...)`, and save accumulated results to `results/<date>/<date>_<battery>.mat`.
5. **Plot results** — scripts in `src/plot_results/` load the saved `results/<date>/...mat` files and
   produce comparison plots (voltage/temperature/SOC/degradation) across cycles or battery types.

## Architecture

- **Simulink models are the simulation core**: `src/models/estimation_data_with_new_parameter_new.slx` and
  `simulate_data.slx` consume base-workspace timeseries inputs (`ts_vt_many_cycles`, `ts_ik_many_cycles`,
  `ts_tk_many_cycles`, `ts_time`) and, on `sim(...)`, return outputs consumed by name from the returned
  object: `gammaf`, `gammaf_est`, `current_input`, `soc`, `soc_est`, `vt`, `vt_est`, `temperature`,
  `temperature_est`. These variable names are the contract between the `.m` driver scripts in
  `src/estimate_degradation/` and the Simulink block diagram — changing one side requires updating the other.
- **`src/estimate_degradation/`** — top-level simulation drivers. Per battery/cycle, they build the input
  timeseries from a data table (columns: `time`, `voltage_charger`, `current_load`, `temperature_battery`,
  `mode`, where `mode == -i` selects discharge cycle `i`), run the Simulink sim, and accumulate per-cycle
  gamma/SOC/voltage/temperature estimates into one `.mat` file per battery under `results/<date>/`.
  `run_discharge_random.m` is a shorter, in-progress variant that stops after building the input timeseries
  for one segment (no `sim`/save step yet) — `run_discharge_with_kf_real_data_new_parameters_new.m` is the
  complete driver.
- **`src/identify_parameters/`** — offline, independent of Simulink: fits a static equivalent-circuit model
  (OCV as a log/inverse-SOC curve, resistance as a degree-4 polynomial in SOC, optional first-order thermal
  model) to discharge segments via `lsqnonlin`. Segments are selected by `mode` value (e.g. `mode == -3`).
  These fitted parameters feed the model used inside the Simulink diagrams.
- **`src/data_prep/`** — turns raw randomized-usage logs into the labeled discharge/charge dataset consumed
  by the other stages (adds `mode` via `bwlabel` on the sign of current).
- **`data/raw/randomized_battery_usage/`** — third-party NASA dataset (raw `.mat`/README per subset); treat
  as read-only input data, not project source. Not currently read by any script here.
- **`results/<date>/`** — one `.mat` per battery per experiment date, produced by
  `src/estimate_degradation/` and consumed by `src/plot_results/`. Dates are arbitrary run labels (e.g.
  `24-sept`, `2-oct`, `4-oct`, `24-oct`), not calendar constraints. `results/unsorted_snapshots/` holds three
  loose partial-schema `.mat` snapshots (missing fields like `count_cycle`/`capacity_vector`) that predate
  this reorganization and aren't referenced by any script — likely safe to delete once confirmed unneeded.

## Notes

- Relocating a script keeps the path-handling pattern working as long as `data/`, `results/`, and
  `src/models/` stay at their fixed positions relative to `2025/`; renaming `2025/`, `src/`, or `data/`
  requires re-checking the `fullfile` arguments in the affected scripts.
- See `docs/Planning.md` for the original task breakdown behind this project's organization.
