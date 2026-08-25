%% =========================================================
%  BATTERY PARAMETER IDENTIFICATION
% ==========================================================

clear; clc;

this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(this_dir));    % 2025/src/identify_parameters -> 2025/

%% ===================== LOAD DATA =========================
% RW1 (NASA "Randomized Battery Usage" dataset, in-scope -- see CLAUDE.md).
% Its earliest low-current (~0.04 A) discharge gives a near-OCV trace across
% the full SOC range (I*R is negligible at that current), and its earliest
% HPPC pulse day gives ~1 A pulses at decreasing SOC. Fitting both together
% (instead of one constant-current trace alone) is what breaks the OCV/R
% collinearity a single current level can't: the low-current segment pins
% down OCV(Z), and the ~25x-larger pulse current then pins down R(Z) given
% that OCV.
battery_name = 'RW1';
low_current_data = readtable(fullfile(proj_root, 'data', 'constant', 'prepared', ...
    [battery_name '_low_current_prepared.csv']));
pulsed_data = readtable(fullfile(proj_root, 'data', 'constant', 'prepared', ...
    [battery_name '_pulsed_prepared.csv']));

%% ===================== QUICK OVERVIEW PLOTS ==============
figure(1); clf;

ax1 = subplot(3,1,1);
plot(pulsed_data.temperature_battery);
ylabel('Temperature')

ax2 = subplot(3,1,2);
plot(pulsed_data.current_load);
ylabel('Current')

ax3 = subplot(3,1,3);
plot(pulsed_data.mode);
ylabel('Mode')
xlabel('Samples')

linkaxes([ax1 ax2 ax3],'x');

%% =========================================================
%  EXTRACT DISCHARGE SEGMENTS
% ==========================================================

Z0 = 99.5;       % Initial SOC (%) -- start of the earliest RW1 characterization day
capacity = 2.03; % Battery capacity [Ah] -- integrating current over all 13 pulses of the
                 % characterization day (which ends at the real 3.2V cutoff, not an assumption)
                 % removes 2.03 Ah total, so this is a measured value for this specific cell/day,
                 % not the dataset's general nominal rating.

% OCV-dominant segment: freshest low-current discharge, spans the full SOC
% range.
ocvSeg = extractDischarge(low_current_data, -1, Z0, capacity);

% R-dominant segments: the freshest HPPC pulse day, mode -1 (fresh, ~99.5%
% SOC) through mode -13 (discharge cutoff). Chained rather than restarted
% at Z0 per pulse -- extractDischarge resets SOC at its given Z0, so on its
% own it can't see the charge already removed by earlier pulses the same
% day; each pulse's ending Z is carried forward as the next pulse's Z0.
pulseModeIDs = -1:-1:-13;
pulseTrain = repmat(struct('X',[],'V',[],'V0',[],'I',[],'Z',[],'T',[],'T0',[]), 1, numel(pulseModeIDs));
Zstart = Z0;
for i = 1:numel(pulseModeIDs)
    pulseTrain(i) = extractDischarge(pulsed_data, pulseModeIDs(i), Zstart, capacity);
    Zstart = pulseTrain(i).Z(end);
end

% Every 3rd pulse spans the day's SOC range without the redundancy (and
% lsqnonlin runtime) of fitting all 13 -- they overlap heavily in R(Z).
selectedPulses = 1:3:numel(pulseModeIDs);
seg = [ocvSeg, pulseTrain(selectedPulses)];

% Held-out (out-of-sample) validation segment: a pulse never used in
% fitting, reusing its Z already chained above in pulseTrain -- picking the
% middle of the unused pulses rather than a hardcoded index so this stays
% valid if selectedPulses is ever changed.
heldOutIdx = setdiff(1:numel(pulseModeIDs), selectedPulses);
heldOutPulseNo = heldOutIdx(round(numel(heldOutIdx)/2));
heldOutSeg = pulseTrain(heldOutPulseNo);

%% =========================================================
%  CONFIGURATION -- opt-in OCV model / fit method extensions
% ==========================================================
% Defaults below reproduce the original fit exactly: plain log OCV,
% degree-2 R polynomial, lsqnonlin output-error. Switch either flag to try
% the newer approaches ported from the sibling "Estimacao de baterias"
% project (see README.md/CLAUDE.md for what each does and why).
%
% Benchmarked on RW1 (held-out validation, pulse mode -6, never used in
% fitting) 2026-08-25: neither extension beats the default here, so keep
% 'log'/'lsqnonlin' as the actual default -- treat the others as
% documented-but-not-recommended unless you improve on this:
%   log,      lsqnonlin           (default): V RMSE 0.032 V, T RMSE 0.267 C
%   log_tanh, lsqnonlin:                     V RMSE 0.069 V, T RMSE 0.260 C
%     -- tanh amplitude/rate terms carry ~106% uncertainty; unsupported by this data.
%   log,      fmincon_constrained:           V RMSE 0.615 V, T RMSE 1.431 C
%     -- fmincon genuinely converges (step/constraint tolerances satisfied,
%     not an error) but to a much worse local minimum: Joule-heating p(9)
%     comes out at 413.6 vs. the default fit's physically-sensible 25.8, and
%     the Z^3/Z^4 terms it was meant to make safe converge to ~0 anyway.
%     Likely fmincon's default SQP (finite-difference gradients) is a poor
%     match for this black-box time-domain simulation objective compared to
%     lsqnonlin's trust-region-reflective algorithm -- a better initial
%     guess or different optimizer settings might change this.
%   log_tanh, fmincon_constrained:           V RMSE 0.752 V, T RMSE 0.743 C
cfg.ocvModelType = 'log';        % 'log' (default) | 'log_tanh'
cfg.fitMethod     = 'lsqnonlin';  % 'lsqnonlin' (default) | 'fmincon_constrained'

%% =========================================================
%  PARAMETER INITIAL GUESS
% ==========================================================
% RW1 is a single Li-ion cell (~3.2-4.2 V), unlike the multi-cell pack this
% script used to fit -- OCV scale (p2-p4) and ambient temperature (p10) are
% re-derived for that range, not carried over from the old battery pack fit.
%
% R(Z) is a degree-2 (not degree-4) polynomial by default: with only 5
% disjoint SOC "islands" of high-current (R-informative) data and wide
% unconstrained gaps between them, a degree-4 fit is free to wiggle in
% those gaps -- it produced two spurious local maxima (an "M" shape) with
% lower resistance at both true endpoints than in the interior, the
% opposite of the expected U/W-shaped rise at SOC extremes. Degree-2 can't
% reproduce that wiggle. cfg.fitMethod = 'fmincon_constrained' below is an
% alternative fix: keep degree-4 flexibility but bound R(Z)/OCV(Z) directly
% via nonlcon instead of restricting the polynomial degree.
%
% p1, p8, p9, p10 (AR/thermal coefficients) always use the original
% hardcoded starting guesses below, in every cfg mode -- match_rint/
% match_voc (ported below as deriveRIntInitialGuess/deriveOcvInitialGuess)
% only cover the OCV/R shape parameters. p2-p7 keep their original
% hardcoded numbers too UNLESS an extended mode needs shape parameters
% those numbers don't cover (log_tanh's p13/p14, fmincon_constrained's
% degree-4 p11/p12) -- in that case the corresponding block is instead
% derived by fitting the model's own OCV/R functions to hand-picked
% target-curve points, verified by the plots in figures 20/21.

params0 = zeros(14,1);
params0(1) = 0.3;   % p1  voltage AR coefficient
params0(8) = 0.95;  % p8  thermal AR coefficient
params0(9) = 10;    % p9  Joule-heating coefficient
params0(10) = 18;   % p10 ambient temperature

if strcmp(cfg.ocvModelType,'log_tanh') || strcmp(cfg.fitMethod,'fmincon_constrained')
    [p2,p3,p4] = deriveOcvInitialGuess();
    params0(2) = p2; params0(3) = p3; params0(4) = p4;
else
    params0(2) = 4.2;   % p2  OCV scale term
    params0(3) = 0.05;  % p3  OCV log-term coefficient
    params0(4) = 0.3;   % p4  OCV inverse-SOC coefficient
end

if strcmp(cfg.fitMethod,'fmincon_constrained')
    rInit = deriveRIntInitialGuess(4);        % degree-4 W-shape target fit
    params0(5:7) = rInit(1:3);
    params0(11) = rInit(4);                   % p11 resistance polynomial: Z^3 term
    params0(12) = rInit(5);                   % p12 resistance polynomial: Z^4 term
else
    params0(5) = 0.1;   % p5  resistance polynomial: constant term
    params0(6) = 0;     % p6  resistance polynomial: SOC term
    params0(7) = 0;     % p7  resistance polynomial: SOC^2 term
end

if strcmp(cfg.ocvModelType,'log_tanh')
    % Occupies p(11)/p(12) unless fmincon_constrained's own Z^3/Z^4 term
    % already claims those slots, in which case the tanh term shifts to
    % p(13)/p(14) -- see ocvModelExt below, which must agree with this.
    tanhBase = 11 + 2*strcmp(cfg.fitMethod,'fmincon_constrained');
    params0(tanhBase)   = 0.05; % OCV tanh inflection amplitude
    params0(tanhBase+1) = 0.1;  % OCV tanh inflection rate
end

% Trim to the parameters actually in play for this cfg, so lsqnonlin/fmincon
% never see unused trailing zeros.
nParams = 10 + 2*strcmp(cfg.fitMethod,'fmincon_constrained') + 2*strcmp(cfg.ocvModelType,'log_tanh');
params0 = params0(1:nParams);

%% ===================== ERROR FUNCTION ====================

error_func = @(p) batteryErrorFunction(p, seg, cfg);

%% ===================== CONSTRAINTS =======================

lb = -inf(nParams,1);
ub =  inf(nParams,1);

lb(1)=0;     ub(1)=0.9;
lb(2)=3.5;   ub(2)=4.5;
lb(5)=0;     ub(5)=1;
lb(8)=0.9;   ub(8)=1;
lb(10)=16;   ub(10)=20;   % measured ambient across segments spans ~17-20 C

if strcmp(cfg.fitMethod,'fmincon_constrained')
    lb(11) = -1;   ub(11) = 1;   % p11 Z^3 term -- loose box bound, nonlcon does the real work
    lb(12) = -1;   ub(12) = 1;   % p12 Z^4 term
end
if strcmp(cfg.ocvModelType,'log_tanh')
    tanhBase = 11 + 2*strcmp(cfg.fitMethod,'fmincon_constrained');
    lb(tanhBase)   = -0.5; ub(tanhBase)   = 0.5; % tanh amplitude -- a few hundred mV of inflection at most
    lb(tanhBase+1) = 0;    ub(tanhBase+1) = 1;   % tanh rate -- keep the inflection SOC-slow, not a step
end

%% ===================== OPTIMIZATION ======================

switch cfg.fitMethod
    case 'lsqnonlin'
        options = optimoptions('lsqnonlin','Display','iter');
        [params_opt,resnorm,residual,exitflag,optimOutput,lambda,jacobian] = ...
            lsqnonlin(error_func,params0,lb,ub,options); %#ok<ASGLU>

    case 'fmincon_constrained'
        % Shape constraints wrap the SAME output-error model used by
        % error_func above (via polyResistanceExt/ocvModelExt) -- only the
        % optimizer and the R(Z)/OCV(Z) degree change, not the underlying
        % voltage/temperature simulation.
        Q_check = linspace(0.001, 99.5, 500);
        nonlcon = @(p) shapeConstraints(p, Q_check, cfg);
        cost_func = @(p) sum(error_func(p).^2);
        options = optimoptions('fmincon','Display','iter','Algorithm','sqp', ...
            'MaxFunctionEvaluations',100000,'MaxIterations',10000, ...
            'OptimalityTolerance',1e-8,'StepTolerance',1e-10);
        [params_opt, resnorm] = fmincon(cost_func, params0, [],[],[],[], lb, ub, nonlcon, options);
        residual = error_func(params_opt);
        jacobian = [];  % Gauss-Newton uncertainty below needs lsqnonlin's Jacobian;
                         % not produced by fmincon, so uncertainty reporting is skipped
                         % in this mode (see reportParameterUncertainty guard below).
end

disp('Optimized Parameters:')
disp(params_opt)
disp('Residual Norm:')
disp(resnorm)

reportArCoefficient('Voltage AR coefficient  p(1)', params_opt(1), lb(1), ub(1));
reportArCoefficient('Thermal AR coefficient  p(8)', params_opt(8), lb(8), ub(8));
if isempty(jacobian)
    fprintf('\nParameter uncertainty: not available for fitMethod = ''%s'' (no Jacobian).\n', cfg.fitMethod);
else
    reportParameterUncertainty(params_opt, lb, ub, resnorm, jacobian, numel(residual));
end

%% =========================================================
%  MODEL OUTPUT
% ==========================================================

output = [vertcat(seg.V); vertcat(seg.T)] + error_func(params_opt);

nV = arrayfun(@(s) numel(s.V), seg);
vEnd = cumsum(nV);
vStart = [0, vEnd(1:end-1)] + 1;
totalV = vEnd(end);

nT = arrayfun(@(s) numel(s.T), seg);
tEnd = totalV + cumsum(nT);
tStart = [totalV, tEnd(1:end-1)] + 1;

%% ===================== VALIDATION PLOTS ==================

figure(3); clf;
plot(seg(1).X,seg(1).V,'r','LineWidth',2); hold on
plot(seg(1).X,output(vStart(1):vEnd(1)),'--b','LineWidth',2)
legend('Measured','Model')
xlabel('Time (s)')
ylabel('Voltage (V)')
title('Voltage fit -- OCV segment (low current)')
grid on

figure(4); clf;
plot(seg(1).Z,polyResistanceExt(params_opt,seg(1).Z,cfg),'LineWidth',2)
xlabel('SOC (%)')
ylabel('Internal Resistance')
grid on

figure(5); clf;
plot(seg(1).Z,ocvModelExt(params_opt,seg(1).Z,cfg),'LineWidth',2)
xlabel('SOC (%)')
ylabel('Open Circuit Voltage')
grid on
title(sprintf('OCV model: %s', cfg.ocvModelType))

figure(6); clf;
plot(seg(end).X,seg(end).T,'r','LineWidth',2); hold on
plot(seg(end).X,output(tStart(end):tEnd(end)),'--b','LineWidth',2)
legend('Measured','Model')
xlabel('Time (s)')
ylabel('Temperature (C)')
title('Temperature fit -- pulse segment (strongest thermal excitation)')
grid on

figure(7); clf;
plot(seg(2).X,seg(2).V,'r','LineWidth',2); hold on
plot(seg(2).X,output(vStart(2):vEnd(2)),'--b','LineWidth',2)
legend('Measured','Model')
xlabel('Time (s)')
ylabel('Voltage (V)')
title('Voltage fit -- pulse segment')
grid on

%% ============== HELD-OUT (OUT-OF-SAMPLE) VALIDATION ==============
% heldOutSeg (built above, from pulse mode heldOutPulseNo) was excluded
% from `seg` and never touched by the optimizer -- a genuine out-of-sample
% check, unlike figures 3/6/7 above which all replot segments used in
% fitting.
heldOutErr = batteryErrorFunction(params_opt, heldOutSeg, cfg);
nVheld = numel(heldOutSeg.V);
Vhat_heldOut = heldOutErr(1:nVheld) + heldOutSeg.V;
That_heldOut = heldOutErr(nVheld+1:end) + heldOutSeg.T;

fprintf('\nHeld-out validation (pulse mode %d, never used in fitting):\n', pulseModeIDs(heldOutPulseNo));
fprintf('  Voltage RMSE     = %.4f V\n', rms(Vhat_heldOut - heldOutSeg.V));
fprintf('  Temperature RMSE = %.4f C\n', rms(That_heldOut - heldOutSeg.T));

figure(8); clf;
plot(heldOutSeg.X, heldOutSeg.V, 'r', 'LineWidth', 2); hold on
plot(heldOutSeg.X, Vhat_heldOut, '--b', 'LineWidth', 2)
legend('Measured','Model')
xlabel('Time (s)')
ylabel('Voltage (V)')
title('HELD-OUT validation -- pulse never used in fitting')
grid on

%% =========================================================
%  ================== LOCAL FUNCTIONS ======================
% ==========================================================

function s = extractDischarge(data,modeID,Z0,capacity)

    mask = data.mode == modeID;

    Xraw = data.time(mask);
    Vraw = data.voltage_charger(mask);
    Iraw = data.current_load(mask);
    Traw = data.temperature_battery(mask);

    s.X = Xraw(2:end);
    s.V = Vraw(2:end);
    s.V0 = Vraw(1);    % initial condition for the voltage simulation below
    s.I = Iraw(2:end);

    s.T = Traw(2:end);
    s.T0 = Traw(1);    % initial condition for the temperature simulation below

    % SOC calculation (Coulomb counting)
    s.Z = Z0 * ones(length(s.V),1);
    for k = 2:length(s.Z)
        dt = s.X(k) - s.X(k-1);
        s.Z(k) = max(s.Z(k-1) - dt*100*s.I(k)/(3600*capacity), 0.001);
    end
end

function err = batteryErrorFunction(p, seg, cfg)
    % Output-error (simulation-error) fit: each segment is simulated open-loop from its
    % true initial sample (V0/T0) forward, feeding back the model's own previous
    % prediction rather than the true previous measurement. This is what determines
    % whether the OCV/R (and thermal) submodel is actually predictive, since the
    % downstream EKF observer never gets to see ground truth at each step either.
    if nargin < 3
        cfg = struct('ocvModelType','log','fitMethod','lsqnonlin');
    end

    err = [];
    for i = 1:numel(seg)
        R = polyResistanceExt(p,seg(i).Z,cfg);
        OCV = ocvModelExt(p,seg(i).Z,cfg);
        Vhat = simulateAR(p(1), seg(i).V0, OCV - seg(i).I.*R);
        err = [err; Vhat - seg(i).V]; %#ok<AGROW>
    end

    for i = 1:numel(seg)
        R = polyResistanceExt(p,seg(i).Z,cfg);
        That = simulateAR(p(8), seg(i).T0, p(10) + p(9)*seg(i).I.^2.*R);
        err = [err; That - seg(i).T]; %#ok<AGROW>
    end
end

function yhat = simulateAR(a, y0, forcing)
    % yhat(k) = a*yhat(k-1) + (1-a)*forcing(k), seeded from the true sample y0.
    yhat = zeros(size(forcing));
    prev = y0;
    for k = 1:numel(forcing)
        yhat(k) = a*prev + (1-a)*forcing(k);
        prev = yhat(k);
    end
end

function R = polyResistance(p,Z)
    R = p(5) + p(6)*Z + p(7)*Z.^2;
end

function OCV = ocvModel(p,Z)
    OCV = p(2) - p(3)*log(100-Z) - p(4)./Z;
end

function R = polyResistanceExt(p, Z, cfg)
    % Degree-2 base (polyResistance above) plus, opt-in via
    % cfg.fitMethod = 'fmincon_constrained', a Z^3/Z^4 extension -- ported
    % from the sibling project's degree-4 fit, made safe there by
    % shapeConstraints below instead of the degree limit.
    R = polyResistance(p, Z);
    if strcmp(cfg.fitMethod, 'fmincon_constrained')
        R = R + p(11)*Z.^3 + p(12)*Z.^4;
    end
end

function OCV = ocvModelExt(p, Z, cfg)
    % Plain log-OCV base (ocvModel above) plus, opt-in via
    % cfg.ocvModelType = 'log_tanh', an S-curve inflection term for the
    % mid-SOC plateau -- ported from the sibling project's
    % ocvModel_alternative.m. Occupies p(11)/p(12) unless
    % cfg.fitMethod = 'fmincon_constrained' also claims those slots for its
    % own Z^3/Z^4 term, in which case the tanh term shifts to p(13)/p(14)
    % (must agree with the params0/lb/ub setup above).
    OCV = ocvModel(p, Z);
    if strcmp(cfg.ocvModelType, 'log_tanh')
        tanhBase = 11 + 2*strcmp(cfg.fitMethod,'fmincon_constrained');
        OCV = OCV + p(tanhBase)*tanh(p(tanhBase+1)*(Z-50));
    end
end

function [c, ceq] = shapeConstraints(p, Q, cfg)
    % Bounds R(Z)/OCV(Z) continuously across the whole SOC range so a
    % degree-4 R polynomial (which has room to wiggle between the sparse
    % R-informative pulse islands, see the comment above params0) stays
    % physically sensible without falling back to a lower degree. Ported
    % from the sibling project's nonlcon, corrected to match its own
    % stated bounds (its code used OCV <= 5 while its comment/plots said
    % 4.2 V) and retargeted to RW1's actual cell range (3.2 V cutoff,
    % 4.2 V full charge) instead of that project's pack-level range.
    %
    % These numeric bounds are a starting point, not a measured fact for
    % this cell -- check them against seg's own pulse-derived R(Z) once
    % you have a fit, and tighten/loosen as needed.
    R = polyResistanceExt(p, Q, cfg);
    OCV = ocvModelExt(p, Q, cfg);
    Rlb = 0.02; Rub = 0.5;
    OCVlb = 3.0; OCVub = 4.3;
    c = [R(:) - Rub; Rlb - R(:); OCV(:) - OCVub; OCVlb - OCV(:)];
    ceq = [];
end

function [p2,p3,p4] = deriveOcvInitialGuess()
    % Ported from the sibling project's match_voc.m: fit the plain log-OCV
    % model's own shape (not a separate curve family) to a handful of
    % hand-picked S-curve target points, instead of a bare hardcoded
    % guess -- gives the nonconvex fit below a sensibly-shaped starting
    % point. Target points assume RW1's single-cell range (~3.2-4.2 V);
    % adjust if fitting a different cell.
    Q_targets = [0.1, 5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 99];
    V_targets = [3.2, 3.3, 3.4, 3.55, 3.62, 3.65, 3.68, 3.72, 3.80, 3.92, 4.05, 4.2];

    ocv_residual = @(p) p(1) - p(2)*log(100 - Q_targets) - p(3)./Q_targets - V_targets;
    p0 = [4.2, 0.05, 0.3];
    p_fit = lsqnonlin(ocv_residual, p0, [], [], optimoptions('lsqnonlin','Display','off'));

    p2 = p_fit(1); p3 = p_fit(2); p4 = p_fit(3);

    Q_test = linspace(0.001, 99.5, 500);
    figure(20); clf;
    plot(Q_test, p2 - p3*log(100-Q_test) - p4./Q_test, 'b', 'LineWidth', 2); hold on
    plot(Q_targets, V_targets, 'ro', 'MarkerSize', 8, 'DisplayName', 'Target points');
    xlabel('SOC (%)'); ylabel('OCV (V)'); grid on; legend;
    title('Derived OCV initial guess vs. target S-curve');
end

function rInit = deriveRIntInitialGuess(degree)
    % Ported from the sibling project's match_rint.m: fit a polynomial of
    % the requested degree to hand-picked W-shape target points (high at
    % low SOC, dip, plateau, rise near full charge), used as the initial
    % guess for the R(Z) polynomial coefficients (p5.. in ascending power
    % of Z) instead of a bare hardcoded guess.
    Q_targets = [0, 20, 40, 60, 80, 99];
    R_targets = [0.3, 0.08, 0.05, 0.06, 0.05, 0.15];

    p_fit = polyfit(Q_targets, R_targets, degree);
    rInit = fliplr(p_fit);   % polyfit returns highest degree first; we want ascending

    Q_test = linspace(0.001, 99.5, 500);
    figure(21); clf;
    plot(Q_test, polyval(p_fit, Q_test), 'b', 'LineWidth', 2); hold on
    plot(Q_targets, R_targets, 'ro', 'MarkerSize', 8, 'DisplayName', 'Target points');
    xlabel('SOC (%)'); ylabel('R (Ohm)'); grid on; legend;
    title(sprintf('Derived R(Z) initial guess vs. target W-curve (degree %d)', degree));
end

function reportArCoefficient(label, value, lb, ub)
    tol = 0.02*(ub-lb);
    physicalWeight = 1 - value;
    fprintf('%s = %.4f  (bounds [%.4f, %.4f], physical-model weight (1-p) = %.4f)\n', ...
        label, value, lb, ub, physicalWeight);
    if (value - lb) < tol || (ub - value) < tol
        warning(['%s is within 2%% of its bound. The physical OCV/R (or thermal) ' ...
                 'submodel may be getting little leverage in this fit -- treat the ' ...
                 'validation plots with caution.'], label);
    end
end

function reportParameterUncertainty(p, lb, ub, resnorm, jacobian, nObservations)
    % Gauss-Newton approximate parameter covariance: sigma^2 = resnorm/dof,
    % Cov = sigma^2 * pinv(J'*J). Two caveats on top of the usual asymptotic
    % assumptions: (1) it's only valid at an unconstrained stationary point
    % of the least-squares objective -- a parameter sitting at its bound is
    % flagged instead of given a (meaningless) confidence interval, same
    % caveat as reportArCoefficient above; (2) it assumes independent
    % residuals, but the output-error simulation makes consecutive residuals
    % serially correlated (each sample's error carries over from the last
    % via the AR feedback) -- the true uncertainty is larger than this
    % reports, likely by a wide margin given how many samples (tens of
    % thousands) are packed into a handful of continuous segments.
    J = full(jacobian);
    dof = nObservations - numel(p);
    sigma2 = resnorm / dof;
    covariance = sigma2 * pinv(J'*J);
    se = sqrt(diag(covariance));

    fprintf('\nParameter uncertainty (Gauss-Newton approx., %d dof; likely optimistic -- see comment):\n', dof);
    for i = 1:numel(p)
        atBound = (p(i)-lb(i)) < 1e-9 || (ub(i)-p(i)) < 1e-9;
        if atBound
            fprintf('  p(%2d) = %11.4f  [at bound -- SE not meaningful]\n', i, p(i));
        else
            fprintf('  p(%2d) = %11.4f  +/- %10.2e  (95%% CI +/- %.2e, CV = %.2f%%)\n', ...
                i, p(i), se(i), 1.96*se(i), 100*se(i)/abs(p(i)));
        end
    end
end
