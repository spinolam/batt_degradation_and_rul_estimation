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

%% =========================================================
%  PARAMETER INITIAL GUESS
% ==========================================================
% RW1 is a single Li-ion cell (~3.2-4.2 V), unlike the multi-cell pack this
% script used to fit -- OCV scale (p2-p4) and ambient temperature (p10) are
% re-derived for that range, not carried over from the old battery pack fit.
%
% R(Z) is a degree-2 (not degree-4) polynomial: with only 5 disjoint SOC
% "islands" of high-current (R-informative) data and wide unconstrained gaps
% between them, a degree-4 fit is free to wiggle in those gaps -- it
% produced two spurious local maxima (an "M" shape) with lower resistance at
% both true endpoints than in the interior, the opposite of the expected
% U/W-shaped rise at SOC extremes. Degree-2 can't reproduce that wiggle.

params0 = [
    0.3     % p1  voltage AR coefficient
    4.2     % p2  OCV scale term
    0.05    % p3  OCV log-term coefficient
    0.3     % p4  OCV inverse-SOC coefficient
    0.1     % p5  resistance polynomial: constant term
    0       % p6  resistance polynomial: SOC term
    0       % p7  resistance polynomial: SOC^2 term
    0.95    % p8  thermal AR coefficient
    10      % p9  Joule-heating coefficient
    18      % p10 ambient temperature
];

%% ===================== ERROR FUNCTION ====================

error_func = @(p) batteryErrorFunction(p, seg);

%% ===================== CONSTRAINTS =======================

lb = -inf(10,1);
ub =  inf(10,1);

lb(1)=0;     ub(1)=0.9;
lb(2)=3.5;   ub(2)=4.5;
lb(5)=0;     ub(5)=1;
lb(8)=0.9;   ub(8)=1;
lb(10)=16;   ub(10)=20;   % measured ambient across segments spans ~17-20 C

%% ===================== OPTIMIZATION ======================

options = optimoptions('lsqnonlin','Display','iter');
[params_opt,resnorm,residual,exitflag,optimOutput,lambda,jacobian] = ...
    lsqnonlin(error_func,params0,lb,ub,options); %#ok<ASGLU>

disp('Optimized Parameters:')
disp(params_opt)
disp('Residual Norm:')
disp(resnorm)

reportArCoefficient('Voltage AR coefficient  p(1)', params_opt(1), lb(1), ub(1));
reportArCoefficient('Thermal AR coefficient  p(8)', params_opt(8), lb(8), ub(8));
reportParameterUncertainty(params_opt, lb, ub, resnorm, jacobian, numel(residual));

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
plot(seg(1).Z,polyResistance(params_opt,seg(1).Z),'LineWidth',2)
xlabel('SOC (%)')
ylabel('Internal Resistance')
grid on

figure(5); clf;
plot(seg(1).Z,ocvModel(params_opt,seg(1).Z),'LineWidth',2)
xlabel('SOC (%)')
ylabel('Open Circuit Voltage')
grid on

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

function err = batteryErrorFunction(p, seg)
    % Output-error (simulation-error) fit: each segment is simulated open-loop from its
    % true initial sample (V0/T0) forward, feeding back the model's own previous
    % prediction rather than the true previous measurement. This is what determines
    % whether the OCV/R (and thermal) submodel is actually predictive, since the
    % downstream EKF observer never gets to see ground truth at each step either.

    err = [];
    for i = 1:numel(seg)
        R = polyResistance(p,seg(i).Z);
        OCV = ocvModel(p,seg(i).Z);
        Vhat = simulateAR(p(1), seg(i).V0, OCV - seg(i).I.*R);
        err = [err; Vhat - seg(i).V]; %#ok<AGROW>
    end

    for i = 1:numel(seg)
        R = polyResistance(p,seg(i).Z);
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
