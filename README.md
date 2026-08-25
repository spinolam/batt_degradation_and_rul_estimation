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

## Experimental data: constant-current vs. variable-current segments

This project draws on two independent, unrelated datasets, each documented separately:

- **NASA's "Randomized Battery Usage Data Set"** (`data/raw/randomized_battery_usage/`; Bole, Kulkarni &
  Daigle, NASA Ames PCoE) — downloaded as item "11. Randomized Battery Usage" from the
  [NASA PCoE Data Set Repository](https://www.nasa.gov/intelligent-systems-division/discovery-and-systems-health/pcoe/pcoe-data-set-repository/);
  documented per sub-dataset by its own `README_RW_*.html`/`.Rmd` file.
- **The accelerated life-testing dataset** described in
  `docs/3587-Full-Length Manuscripts-13587-1-10-20231221.pdf` (Fricke, Nascimento, Corbetta, Kulkarni &
  Viana) — this is `battery_alt_dataset` at the parent level (`batt_gamma_estimation/data/`; see its own
  `README.txt`), **not** anything under this project's `data/`. The `battery00.csv`...`battery52.csv` files
  in the shared `prepared data/` folder that `src/identify_parameters/` and `src/estimate_degradation/`
  read are almost certainly derived from it — the naming matches `battery_alt_dataset`'s `batt_XX.mat` files
  exactly, and its `README.txt` documents the same `mode`/`mission type` columns those scripts rely on.

Despite being unrelated, both datasets mix the same two fundamentally different kinds of cycling segments,
and this project's pipeline is organized around that split:

- **Constant-current segments** — e.g. NASA's low-current (0.04A) discharge used to trace OCV vs. SOC, its
  2A "reference discharge/charge", or `battery_alt_dataset`'s periodic reference discharges (constant
  current at 2.5A, per its `README.txt`). Because the current is held fixed:
  - The equivalent-circuit parameters (OCV(SOC) curve, internal-resistance polynomial, thermal model) can be
    fit directly via `lsqnonlin` — this is what `src/identify_parameters/` does, and it only works on this
    kind of segment.
  - A full constant-current discharge gives a direct, model-free capacity measurement by integrating current
    over time (Coulomb counting) — this is the ground-truth capacity/degradation benchmark, independent of
    any observer or model (this is exactly how residual capacity is measured in the source experiments).

- **Variable/random-current segments** — NASA's "random walk" cycling (current resampled every ≤5 minutes
  from {-4.5A...4.5A}) or `battery_alt_dataset`'s "regular mission"/variable-load cycling. This is the
  realistic-usage data the project wants to track degradation *under*. Because the current isn't constant,
  neither trick above applies directly — the static OCV/R model can't be fit cleanly, and Coulomb counting
  alone isn't a reliable capacity estimate. This is exactly why the project runs the LPV/EKF-style observer
  (`src/models/` + `src/estimate_degradation/`) over this data: it estimates SOC and the degradation
  parameter `gamma` online, using the equivalent-circuit parameters identified from the constant-current
  segments as its underlying model.

In short: constant-current segments are how the model is *calibrated* (parameters) and degradation is
*ground-truthed* (capacity fade via Coulomb counting); variable-current segments are the *unknown* the
observer is built to track.

## Requirements

- MATLAB with Simulink
- [CVX](https://cvxr.com/cvx/) convex-optimization toolbox (required by the observer synthesis script)

## Layout

```
2025/
├── data/
│   ├── raw/randomized_battery_usage/   # third-party NASA dataset, read-only
│   ├── extracted/<battery>/             # per-category segments isolated from the raw logs (see below)
│   ├── constant/                        # constant-current .mat inputs + prepared/ CSV output
│   └── random/                          # random/variable-current .mat inputs + prepared/ CSV output
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
2. **Extract per-category segments from the raw logs** — `src/data_prep/extract_raw_battery_segments.m`
   loads every raw multi-step log under `data/raw/randomized_battery_usage/**/data/Matlab/RW*.mat` and
   isolates the useful step types (mirroring what NASA's own `MatlabSamplePlots.m` reference script does by
   hand, per dataset, for plotting only) by keyword-matching each step's `comment`: `random_walk`,
   `low_current`, `reference`, `pulsed`, or `other` if unmatched. Each non-empty category is saved as
   `data/extracted/<battery>/<category>.mat`.
3. **Prepare constant/random data** — `src/data_prep/prepara_random_data.m` loads every raw `.mat` under
   `data/constant/`, `data/random/`, and `data/extracted/*/`, classifies each sample as constant- or
   random-current (see "Experimental data" above), and writes a labeled discharge dataset (`mode` column
   via `bwlabel`, scoped per class) to the matching `data/constant/prepared/` or `data/random/prepared/`
   folder — a single raw file can produce both outputs if it mixes segment types. This is self-contained
   under `data/`; the parent-level `prepared data/` folder (shared with `2024/`) is untouched by this step.
4. **Identify model parameters** (optional, offline) — scripts in `src/identify_parameters/` fit OCV +
   internal resistance polynomial + thermal model coefficients from discharge segments via `lsqnonlin`.
   `identify_model_parameters_nonlinear_all_random_data.m` reads from the parent-level `prepared data/`;
   `identify_model_parameters_random_walk*.m` read directly from `data/constant/`.
5. **Run the degradation-estimation simulation** — `src/estimate_degradation/run_discharge_random.m` or
   `run_discharge_with_kf_real_data_new_parameters_new.m`. These loop over cycles/batteries, run the
   Simulink model via `sim(...)`, and save accumulated results to `results/<date>/<date>_<battery>.mat`.
6. **Plot results** — scripts in `src/plot_results/` load the saved `results/<date>/...mat` files and
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
- **`src/data_prep/`** — two stages. `extract_raw_battery_segments.m` reads the raw multi-step logs and
  filters each battery's `step` struct array by comment keyword into named categories (`random_walk`,
  `low_current`, `reference`, `pulsed`, `other`), saving each as its own `.mat` under `data/extracted/`.
  `prepara_random_data.m` then turns any raw `.mat` (from `data/constant/`, `data/random/`, or
  `data/extracted/*/`) into labeled discharge datasets: for NASA "step"-struct inputs it classifies each
  step by its `comment` field (anything containing "random walk" is random-current; everything else is
  constant-current); for flat `I`/`V`/`RT` inputs with no per-sample label it falls back to a
  current-stability heuristic. Each class gets `mode` via `bwlabel` on the sign of current, computed
  separately so cycle numbering stays meaningful within one current regime.
- **`data/raw/randomized_battery_usage/`** — third-party NASA dataset (raw `.mat`/README per subset); treat
  as read-only input data, not project source. Read by `extract_raw_battery_segments.m` (see above).
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
