function cycle_result = simulate_discharge_cycle(cycle_index, datacycle, cfg, params, L, ...
    pho1_min, pho1_max, pho2_min, pho2_max)
%SIMULATE_DISCHARGE_CYCLE Run the pure-MATLAB twin/observer pair over one
%discharge cycle, sample by sample. Shared by simulate_random_discharge_matlab.m
%and simulate_reference_discharge_matlab.m (previously two separate,
%near-identical copies of this loop).
%
% cfg fields: Cr, gamma0, z0, voltage_cutoff.
% datacycle fields (same schema for both callers): relativeTime, current,
% voltage, temperature.

% ---- Reset both persistent states for this new cycle ----
battery_twin([], [], [], [], [], true);
observer_lpv([], [], [], [], [], [], [], true);

time_vector = datacycle.relativeTime;
Ik_signal   = datacycle.current;
n_samples   = length(time_vector);

% Per-cycle initial conditions (do not overwrite cfg's base values)
cycle_param(1) = cfg.gamma0;
cycle_param(2) = cfg.z0;
cycle_param(3) = datacycle.voltage(1);
cycle_param(4) = datacycle.temperature(1);

% Pre-allocate storage
twin_gamma = nan(n_samples, 1);
twin_z     = nan(n_samples, 1);
twin_V     = nan(n_samples, 1);
twin_T     = nan(n_samples, 1);
twin_rint  = nan(n_samples, 1);
twin_voc   = nan(n_samples, 1);

est_gamma = nan(n_samples, 1);
est_zm    = nan(n_samples, 1);
est_Vm    = nan(n_samples, 1);
est_Tm    = nan(n_samples, 1);
est_rint  = nan(n_samples, 1);
I_used    = nan(n_samples, 1);

k_end = n_samples;   % will be updated on early break

for k = 1:n_samples

    Vtrue = datacycle.voltage(k);

    if k == 1
        Tsk = time_vector(2) - time_vector(1);
    else
        Tsk = time_vector(k) - time_vector(k-1);
    end

    % Battery twin
    I_used(k) = Ik_signal(k);
    [g, z, V, T, rint, voc] = battery_twin( ...
        Ik_signal(k), Tsk, cfg.Cr, cycle_param, params);

    % Observer gain
    L_k = calcule_l_observer( ...
        Ik_signal(k), rint, L, pho1_min, pho1_max, pho2_min, pho2_max);

    % State estimation
    [gammam, zm, Vm, Tm, ~, ~, ~, ~, rint] = ...
        observer_lpv(Vtrue, Ik_signal(k), Tsk, cfg.Cr, cycle_param, params, L_k);

    % Store twin
    twin_gamma(k) = g;
    twin_z(k)     = z;
    twin_V(k)     = V;
    twin_T(k)     = T;
    twin_rint(k)  = rint;
    twin_voc(k)   = voc;

    % Store estimates
    est_gamma(k) = gammam;
    est_zm(k)    = zm;
    est_Vm(k)    = Vm;
    est_Tm(k)    = Tm;
    est_rint(k)  = rint;

    % Early stop at cutoff voltage (either the twin's or the observer's
    % voltage crossing it - the more conservative of the two conditions
    % previously used by the two drivers this function replaces)
    if Vtrue <= cfg.voltage_cutoff || Vm <= cfg.voltage_cutoff
        k_end = k;
        break;
    end
end

idx = 1:k_end;

cycle_result.cycle_index = cycle_index;
cycle_result.time        = time_vector(idx);
cycle_result.I_used      = I_used(idx);

cycle_result.twin.gamma = twin_gamma(idx);
cycle_result.twin.z     = twin_z(idx);
cycle_result.twin.V     = twin_V(idx);
cycle_result.twin.T     = twin_T(idx);
cycle_result.twin.rint  = twin_rint(idx);
cycle_result.twin.voc   = twin_voc(idx);

cycle_result.estimate.gamma = est_gamma(idx);
cycle_result.estimate.zm    = est_zm(idx);
cycle_result.estimate.Vm    = est_Vm(idx);
cycle_result.estimate.Tm    = est_Tm(idx);
cycle_result.estimate.rint  = est_rint(idx);
end
