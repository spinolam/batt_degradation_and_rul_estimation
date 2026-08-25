# `src/estimate_degradation/random_walk/` — observability of the `gamma` state

Companion to `estimate_degradation_approach.md` (what the model and observer are) and
`estimate_degradation_review.md` (code-level findings). This is a from-first-principles check of a
question neither of those documents answered: **is `gamma` actually observable from the one thing
this design measures — terminal voltage — and if so, how strongly?** Numbers below were computed
directly from `observer_lpv.m`'s state-space matrices and this project's real fitted parameters for
`RW_Skewed_High_Room_Temp_DataSet_17` (`src/identify_parameters/parameters/RW_Skewed_High_Room_Temp_DataSet_17.mat`),
not estimated by hand.

## The state-space pair being analyzed

`observer_lpv.m` builds, at every sample:

```
A(rho) = [ 1                0   0 ;
           eta*rho1         1   0 ;
           (1-a)*rho2       0   a ],   C = [0 0 1]
```

for state `x = [gamma; z; V]` (`z` = SOC), scheduling variables `rho1 = -I`, `rho2 = -R(SOC)*I`, and
`a = params(1)` the fitted voltage AR/relaxation coefficient. `C = [0 0 1]` because only `V` is
measured.

## Finding 1 — the 3-state system is never fully observable, by construction

Column 2 of `A` — how `z` feeds into the *other* states' next value — is `[0; 1; 0]` for every
`(rho1, rho2)`, not just at particular operating points: `z`'s own row updates it, but no other row
has a `z`-dependent term. Building `O = [C; C*A; C*A^2]` at all 4 LMI polytope vertices (with
`Ts=30`, `Cr=2.5`, `a=0.9899`, the real fitted value) confirms it numerically:

| vertex | `(rho1, rho2)` | `rank(O)` | `cond(O)` |
|---|---|---|---|
| V1 (min,min) | (-1.000, -0.200) | 2 | ~1.1e17 |
| V2 (min,max) | (-1.000, -2.400) | 2 | ~1.1e17 |
| V3 (max,min) | (-2.000, -0.200) | 2 | ~1.1e17 |
| V4 (max,max) | (-2.000, -2.400) | 2 | ~1.1e17 |

`rank(O) = 2` (out of 3) at every vertex, and `cond(O)` at the level of `1/eps` is exact numerical
singularity, not "ill-conditioned." This isn't specific to these four corners — since column 2 of `A`
is identically zero everywhere in `(rho1, rho2)`, the pair `(A(rho), C)` is **never** fully observable
for any scheduling point.

**Consequence.** SOC has no path back into future voltage predictions inside this state-space
realization. Its correction comes entirely from the observer gain's second row, `L(2)`, applied
directly to the voltage residual — not from any internal dynamic coupling. That's likely fine in
practice (SOC also has Coulomb counting as an independent backstop, and doesn't strictly need the
observer to reconstruct it from scratch), but it means the claim "the LMI certifies observer
convergence" is, strictly, a certificate over a 2-D observable subspace containing `(gamma, V)` — not
over the full 3-state estimation error. See Finding 3 for *why* `A` ends up this way.

## Finding 2 — `gamma` is observable, but the channel is weak, and the weakness is quantifiable

Dropping the structurally-decoupled `z`, the reduced pair `Ar = [1 0; (1-a)*rho2, a]`, `Cr = [0 1]`
has `det([Cr; Cr*Ar]) = -(1-a)*rho2`. Evaluated at the 4 vertices with `a = 0.9899`:

| vertex | `rho2` | `det(gamma,V observability)` |
|---|---|---|
| V1 | -0.200 | 0.0020 |
| V2 | -2.400 | 0.0242 |
| V3 | -0.200 | 0.0020 |
| V4 | -2.400 | 0.0242 |

Nonzero, so `gamma` is structurally observable whenever current flows (`rho2 ≠ 0`) — but small. The
determinant scales with `(1-a)`, and this battery's fitted `a = 0.9899` (already flagged in
`parameter_identification_review.md` as "converged to its bound," `p1` saturating at 0.9 as a
consequence of the degree-2-vs-degree-4 `R(SOC)` trade-off documented there) makes `(1-a) = 0.0101`:
**only ~1% of the raw current×resistance signal reaches the channel that carries information about
`gamma`.** A poorly-conditioned offline OCV/R fit doesn't just mean "the electrical submodel explains
less voltage variance" (as that review already noted) — it directly and quantifiably starves this
downstream degradation estimator of the one signal path it needs.

**Cross-check against the actual synthesized gains.** Re-running `lqr_synthesis_observer_gain_scheduled_lpv.m`
for this battery (`Ts=30`, `Cr=2.5`, `a=0.9899`) after the `A2`-vertex-bug fix gives:

```
L1 = [-0.888; -12.75;  0.067]      L2 = [-2.825;  49.13;  0.325]
L3 = [-0.888;  56.17;  0.067]      L4 = [-2.825;  51.59;  0.325]
```

Row 1 (`gamma`'s own correction gain) sits at magnitude 1–3; row 2 (`z`'s correction gain) sits at
13–56 — **10 to 50 times larger**. That's the H2-optimal LMI solution correctly recognizing, given
this model, that a voltage residual barely constrains `gamma` and routing almost all of the
correction into SOC instead. The LMI is doing its job correctly; the model it was handed is what's
under-informative about `gamma`.

## Finding 3 — a separate, compounding gap: this isn't a tangent-linearized (EKF-style) observer

`voc(z) = p2 - p3*log(100-z) - p4/z` is nonlinear, with slope
`∂voc/∂z = p3/(100-z) + p4/z²`. With this battery's fitted `p3 = 0.148`, `p4 = 11.09`, that slope is
~0.007–0.03 V per %SOC through mid-range and grows sharply near the SOC extremes (as `z → 0` or
`z → 100`). A true local linearization (a genuine EKF Jacobian) would place that slope in `A(3,2)`.
`observer_lpv.m` doesn't: it evaluates `voc` at the current `z` estimate and injects the *value* as an
exogenous term in `B`, never differentiating it with respect to `z`. That's mechanically why column 2
of `A` is exactly zero (Finding 1) — the design is a "frozen-parameter" quasi-LPV realization, scheduled
on the current best estimate of `z`, not a tangent-linearized one.

This is independent of Finding 2: adding the missing `∂voc/∂z` term would restore a genuine dynamical
observability path for SOC (rather than relying solely on the injected gain `L(2)`), but it would not
rescue `gamma`'s weak channel, whose bottleneck is the `(1-a)` factor, not the missing SOC Jacobian.

## Bottom line

The design is sound in principle — `gamma` is structurally reachable from voltage whenever current
flows — but it's currently operating in a low-signal regime almost entirely because of `a ≈ 0.99` in
the offline fit. That means the highest-leverage next step isn't anything in the observer or LMI
machinery; it's revisiting *why* the AR coefficient saturates at its bound in
`identify_model_parameters.m` (the degree-2-vs-degree-4 `R(SOC)` trade-off already flagged, unresolved,
in `parameter_identification_review.md`). A tighter fit that moves `a` away from its bound — the
review's own degree-4 experiment saw `a` settle around `0.34` instead — would improve `gamma`'s
observability determinant by roughly two orders of magnitude (`(1-a)`: `0.01 → 0.66`) for free, before
touching the LMI synthesis or the gain-scheduling structure at all.
