# `src/estimate_degradation/` — objective, approach, and model

Companion to `estimate_degradation_review.md` (code-level findings). This document is about *why*
the subsystem is built the way it is: what it's trying to estimate, how it goes about it, and the
exact model underneath.

## Objective

The project's stated goal (`CLAUDE.md`) is battery degradation and RUL estimation. Degradation is
captured as a single scalar, `gamma`, and the objective of this subsystem specifically is: **given a
battery's real, variable-current usage history (current/voltage/temperature), produce an online
estimate of `gamma` (together with SOC and terminal voltage) at every sample, without a dedicated
reference discharge.**

That qualifier matters because of how the two experimental regimes split (`CLAUDE.md`,
"Experimental data"):

- Under **constant current**, degradation can be measured directly and model-free — Coulomb-count
  the current over a full discharge and compare capacity to a fresh cell. No estimator is needed.
- Under **variable/random current** (the realistic-usage case this subsystem targets), that direct
  measurement isn't available: the current isn't held fixed, so there's no clean integration window
  and no way to isolate degradation from just observing raw current/voltage. `gamma` has to be
  *inferred* from how the model's predicted voltage disagrees with the measured voltage as the
  battery is driven through whatever load it actually sees.

So the objective is specifically an **online, model-based state/parameter estimation problem** under
arbitrary current excitation — not a curve fit, and not a physical aging law that predicts fade
forward in time on its own (see "What `gamma`'s dynamics are" below).

## Approach

### Two-stage pipeline, this subsystem is stage two

1. **Offline calibration** (`src/identify_parameters/`, reviewed separately) fits the fixed
   equivalent-circuit coefficients — OCV(SOC), R(SOC), thermal coefficients — from constant-current
   data, where they're identifiable.
2. **Online estimation** (this subsystem) holds those coefficients fixed and treats `gamma` as the
   one remaining unknown, estimated sample-by-sample from real variable-current data via a state
   observer.

### Parameter estimation via state augmentation

The standard trick used here: instead of treating `gamma` as a coefficient to fit offline, it's added
as an extra *state* alongside SOC and terminal voltage, `x = [gamma; z; V]`, and estimated by the same
machinery that estimates the physical states. Concretely (`observer_lpv.m`), `gamma`'s own row in the
state transition is a pure integrator:

```
gamma_{k+1} = gamma_k        (no decay law, no cycle-count term — just "held" between corrections)
```

i.e. `gamma` is modeled as a random walk (constant plus whatever the observer's correction term
injects), the textbook formulation for estimating a slowly-varying/unknown parameter jointly with
faster physical states. All of the actual estimation work is done by the correction term
`L*(V_measured - V_predicted)`: whenever the model's predicted terminal voltage disagrees with the
measured one, that residual gets fed back into `gamma` (and SOC, and V) through the observer gain `L`.
Nothing here computes a fade curve or extrapolates future capacity — `gamma`'s value is purely
"whatever level currently makes the model's voltage track the measured voltage." Projecting that
into a remaining-useful-life number would be a further step this subsystem doesn't take.

### Why the observer is gain-scheduled (LPV), not a single fixed gain

The state matrix that the correction term `L` has to work against isn't constant — it depends on the
present current `I` and on `R(SOC)*I` (`observer_lpv.m`'s `rho1 = -I`, `rho2 = -R(SOC)*I`), both of
which swing over a wide range for a random/variable discharge (unlike the constant-current pipeline,
where a single fixed current makes a single fixed observer gain adequate — that's what
`src/models/lqr_synthesis_observer_simple_Lx3x3_no_VOC.m` designs). Rather than adapting the gain
online (more expensive, harder to certify), the design:

1. Treats `(rho1, rho2)` as bounded within a known box (the 4 corners = the assumed current/resistance
   extremes).
2. Synthesizes, **offline**, one observer gain per corner (`L1..L4`) via a convex LMI problem, using a
   single shared Lyapunov matrix `P` across all four — the shared `P` is what makes the resulting
   family of gains jointly stable across the *whole* box, not just at each corner individually.
3. At runtime, interpolates those four gains bilinearly (`calcule_l_observer.m`) based on where the
   instantaneous `(rho1, rho2)` actually sits in the box.

This is a **gain-scheduled LPV observer**: linear at every instant, but with the linear model's
parameters ("plant" varying with current/resistance) scheduled by measured signals, and a
stability/performance guarantee that holds across the declared operating envelope rather than at one
operating point.

### Not a stochastic Kalman filter, despite the "EKF-style" framing

`CLAUDE.md` describes the approach as "LPV/EKF-style," which captures the *shape* of the estimator
(recursive, correction-from-residual, state-augmented) but not the synthesis method actually used.
`lqr_synthesis_observer_gain_scheduled_lpv.m` minimizes `trace(W)` subject to LMI constraints built
from an `H2`/LQR-type cost (`Q`, `R` as performance weights on the estimation error and gain
magnitude) — a **deterministic robust-control design**, dual to an LQR state-feedback problem. There
are no noise covariances anywhere in it. A genuine (extended) Kalman filter would instead compute its
gain from process/measurement noise covariances via a Riccati recursion, adapted at every step. This
design instead front-loads all of the "how much to trust the model vs. the measurement" tuning into
`Q`/`R` once, offline, and only re-computes the *interpolation weights* (not the gains themselves)
online.

### Two execution paths, one model

The same twin (`battery_twin.m`) and observer (`observer_lpv.m`) equations are exercised two ways —
as Simulink block diagrams (`estimation_random.slx`, run once per cycle from
`run_discharge_random_simulink.m`) and as a direct, sample-by-sample MATLAB loop
(`simulate_random_discharge_matlab.m` / `simulate_reference_discharge_matlab.m`). The Simulink path is
the one used for batch runs across many cycles/batteries; the pure-MATLAB path exists to inspect a
handful of cycles in detail (per-sample twin vs. estimate vs. measured plots) without needing
Simulink open.

## Model

### State and signals

- **Estimated state**: `x = [gamma; z; V]` — degradation factor, SOC (%), terminal voltage.
- **Tracked alongside** (not part of the LPV correction, updated by its own first-order relaxation):
  temperature `T`.
- **Inputs**: load current `I_k`, sample time `Ts` (or per-sample `dt` from timestamps in the
  pure-MATLAB path).
- **Measurement**: terminal voltage `V_true`; the residual `V_true - C*x` (with `C = [0 0 1]`, i.e.
  only `V` is directly observed) drives the correction.

### Equivalent-circuit submodels

- **Open-circuit voltage**: `voc(z) = p2 - p3*log(100 - z) - p4/z`
- **Internal resistance**: `Rint(z) = p5 + p6*z + p7*z^2 + p8*z^3 + p9*z^4` — a **degree-4** polynomial
  in SOC (5 coefficients, `p5..p9`).
- **SOC update (Coulomb counting, scaled by `gamma`)**: `z_{k+1} = z_k - Ts*I_k*100*gamma_k /
  (3600*Cr)` — `gamma` directly scales how fast current draw depletes the counted SOC, which is the
  mechanism by which a degraded (`gamma` far from its nominal value) cell shows up as faster apparent
  SOC depletion for the same current.
- **Terminal voltage**: first-order relaxation toward the instantaneous open-circuit-minus-ohmic-drop
  potential, also scaled by `gamma`: `E_k = voc(z_k) - Rint(z_k)*I_k*gamma_k`,
  `V_{k+1} = a*V_k + (1-a)*E_k`.
- **Temperature**: first-order relaxation toward ambient plus Joule heating, heating term also scaled
  by `gamma`: `T_jk = Rint(z_k)*gamma_k*I_k^2`, `T_{k+1} = p10*T_k + (1-p10)*(p11*T_jk + T_ambient)` —
  here `T_ambient` is taken as the discharge cycle's own initial measured temperature
  (`inital_param(4)`), not a separately fitted global ambient.

So `gamma` isn't a single independent "health" number bolted on afterward — it multiplies the current
in *both* the SOC-depletion term and the ohmic/heating terms, i.e. it's modeled as jointly degrading
apparent capacity and increasing effective loss, and the observer is what disentangles it from SOC/V
using the voltage residual.

### LPV observer form (`observer_lpv.m`)

```
rho1 = -I_k,  rho2 = -Rint(z_k)*I_k
A(rho) = [ 1                    0   0 ;
           eta*rho1              1   0 ;
           (1-a)*rho2            0   a ],   eta = 100*Ts/(3600*Cr)
B(rho) = [0; 0; (1-a)*voc(z_k)]
C      = [0 0 1]

x_{k+1} = A(rho)*x_k + B(rho)*1 + L_k*(V_true_k - C*x_k)
```

`L_k` is the bilinearly-interpolated gain from `calcule_l_observer.m`. The `gamma` row of `A` being
`[1 0 0]` is exactly the random-walk assumption described above — its only "dynamics" are whatever the
`L_k*error` correction contributes.

### Cross-check against the parameter-identification stage

`battery_twin.m`/`observer_lpv.m` index `params(1)` through `params(11)` with `Rint(z)` as a
**degree-4** polynomial (`params(5..9)`, 5 coefficients) and thermal terms at `params(10)`/`params(11)`.
`identify_model_parameters.m`'s **documented default** fit (see `parameter_identification_review.md`)
produces exactly **10** parameters with `R(z)` as **degree-2** (`params(5..7)`, 3 coefficients) —
`fmincon_constrained`/degree-4 is an opt-in alternative there, and that review's benchmark found the
default degree-2 fit to be the better one (lower held-out error) of the two.

That means the `params_opt` file this subsystem actually loads
(`src/identify_parameters/parameters/<battery>.mat`) for a given battery must have 11 entries in the
degree-4-resistance layout to be consumable here — i.e. it has to have come from the
`fmincon_constrained` path, or from an older/different version of the identification script, not from
running today's default `identify_model_parameters.m` as documented. If a battery's `params_opt` were
ever regenerated with the current default (10 entries, degree-2), `battery_twin.m`/`observer_lpv.m`
would either index out of bounds on `params(8..11)` or (worse, if the array happened to be long enough
for unrelated reasons) silently pick up the wrong coefficients for the thermal terms. This is worth
confirming directly against whatever `params_opt` file the random-walk drivers currently load, and
noting in `identify_parameters/` which fit variant each saved `params_opt` corresponds to, so the two
stages don't silently drift apart.
