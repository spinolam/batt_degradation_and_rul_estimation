%% pre-data
%% Pure-MATLAB (non-Simulink) alternate driver for the random-walk pipeline:
%% runs battery_twin.m + observer_lpv.m + calcule_l_observer.m directly,
%% sample-by-sample, over the raw multi-step random-walk log instead of a
%% Simulink model. Operates on RW_Skewed_High_Room_Temp_DataSet_17's raw
%% `random_walk_discharge` steps (grouped into cycles below); compare with
%% simulate_reference_discharge_matlab.m, which runs the same twin/observer
%% pair over the already-cycle-segmented `ref_discharges` data instead.
clear all
this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(fileparts(this_dir)));   % .../src/estimate_degradation/random_walk -> src/estimate_degradation -> src -> project root

date = "1-mars";
battery_list = ["RW_Skewed_High_Room_Temp_DataSet_17"];

%% Run simulation
for b = 1:length(battery_list)
    %% Prepare data
    battery_name = battery_list(b);
    fprintf('=== Simulating %s ===\n', battery_name);

    % Load data
    dataFile = fullfile(proj_root, "data", "random_walk_data", battery_name + "_random.mat");
    load(dataFile);

    % Keep only discharge steps (type == "D")
    all_cycle_nums = cellfun(@(x) x(1), {random_walk_discharge.cycleNum});
    unique_cycles  = unique(all_cycle_nums);
    dataOut = struct([]);

    for k = 1:length(unique_cycles)
        % Get all steps belonging to this cycle
        cycle_steps = random_walk_discharge(all_cycle_nums == unique_cycles(k));

        % Concatenate all steps in the cycle into one struct
        merged = cycle_steps(1);
        for s = 2:length(cycle_steps)
            merged.relativeTime = [merged.relativeTime, merged.relativeTime(end) + cycle_steps(s).relativeTime];
            merged.voltage      = [merged.voltage,      cycle_steps(s).voltage];
            merged.current      = [merged.current,      cycle_steps(s).current];
            merged.temperature  = [merged.temperature,  cycle_steps(s).temperature];
            merged.type         = [merged.type,         cycle_steps(s).type];
            merged.cycleNum     = [merged.cycleNum,     cycle_steps(s).cycleNum];
        end

        if isempty(dataOut)
            dataOut = merged;
        else
            dataOut(end+1) = merged;
        end
    end
    load(fullfile(proj_root, "src", "identify_parameters", "parameters", battery_name), 'params_opt');

    % Initialize results struct array for this battery
    params = params_opt;
    all_results = struct([]);
    max_cycle   = length(dataOut);

    % Simulation parameters
    Ts   = 1;
    seed = 1;
    Cr   = 2.5;
    a    = params(1);
    z0      = 99.5;
    gamma0  = 1;

    % Load model setup
    run(fullfile(this_dir, "lqr_synthesis_observer_gain_scheduled_lpv.m"));

    %% Loop over every discharge step in random_walk_discharge
    for i = 1:5

        datacycle = dataOut(i);

        % Skip low-current cycles
        if ~(mean(datacycle.current) > 0.98) || length(datacycle.relativeTime) < 10
            continue;
        end

        fprintf('  Simulating cycle %d / %d\n', i, max_cycle);

        % ---- Reset both persistent states for this new cycle ----
        battery_twin([], [], [], [], [], true);
        observer_lpv([], [], [], [], [], [], [], true);

        time_vector    = datacycle.relativeTime;
        Ik_signal      = datacycle.current;
        n_samples      = length(time_vector);

        % Per-cycle initial conditions
        cycle_param(1)    = gamma0;
        cycle_param(2)    = z0;
        cycle_param(3)    = datacycle.voltage(1);
        cycle_param(4)    = datacycle.temperature(1);

        % Pre-allocate storage
        twin_gamma  = nan(n_samples, 1);
        twin_z      = nan(n_samples, 1);
        twin_V      = nan(n_samples, 1);
        twin_T      = nan(n_samples, 1);
        twin_rint   = nan(n_samples, 1);
        twin_voc   = nan(n_samples, 1);

        est_gamma   = nan(n_samples, 1);
        est_zm      = nan(n_samples, 1);
        est_Vm      = nan(n_samples, 1);
        est_Tm      = nan(n_samples, 1);
        est_rint    = nan(n_samples, 1);
        I_used      = nan(n_samples, 1);  % <-- add this

        k_end = n_samples;

        for k = 1:n_samples

            Vtrue = datacycle.voltage(k);

            if k == 1
                Tsk = time_vector(2) - time_vector(1);
            else
                Tsk = time_vector(k) - time_vector(k-1);
            end

            % Battery twin
            I_used(k) = Ik_signal(k);
            [g, z, V, T, rint] = battery_twin( ...
                Ik_signal(k), Tsk, Cr, cycle_param, params);

            % Observer gain
            L_k = calcule_l_observer( ...
                Ik_signal(k), rint, L, pho1_min, pho1_max, pho2_min, pho2_max);

            % State estimation
            [gammam, zm, Vm, Tm, xm, error, rho1m, rho2m, rint] = ...
                observer_lpv(Vtrue, Ik_signal(k), Tsk, Cr, cycle_param, params, L_k);

            % Store twin
            twin_gamma(k) = g;
            twin_z(k)     = z;
            twin_V(k)     = V;
            twin_T(k)     = T;
            twin_rint(k)  = rint;

            % Store estimates
            est_gamma(k)  = gammam;
            est_zm(k)     = zm;
            est_Vm(k)     = Vm;
            est_Tm(k)     = Tm;
            est_rint(k)   = rint;

            % Early stop at cutoff voltage
            if Vtrue <= 3.2
                k_end = k;
                break;
            end
        end

        % Trim to simulated length
        idx = 1:k_end;

        % ---- Build cycle result struct ----
        cycle_result.cycle_index = i;
        cycle_result.time        = time_vector(idx);
        cycle_result.I_used = I_used(idx);

        cycle_result.twin.gamma  = twin_gamma(idx);
        cycle_result.twin.z      = twin_z(idx);
        cycle_result.twin.V      = twin_V(idx);
        cycle_result.twin.T      = twin_T(idx);
        cycle_result.twin.rint   = twin_rint(idx);

        cycle_result.estimate.gamma = est_gamma(idx);
        cycle_result.estimate.zm    = est_zm(idx);
        cycle_result.estimate.Vm    = est_Vm(idx);
        cycle_result.estimate.Tm    = est_Tm(idx);
        cycle_result.estimate.rint  = est_rint(idx);

        if isempty(all_results)
            all_results = cycle_result;
        else
            all_results(end+1) = cycle_result;
        end
    end

    %% Visualization — one figure set per simulated cycle
    j = 1;
    r  = all_results(j);
    t  = r.time / 60;
    ci = r.cycle_index;
    raw_t = dataOut(ci).relativeTime / 60;

    figure('Name', sprintf('%s  |  Cycle %d', battery_name, ci));

    subplot(4,1,1);
    plot(t, r.twin.z, t, r.estimate.zm);
    ylabel('SoC (%)'); grid on;
    legend('Twin', 'Estimate');
    title(sprintf('Cycle %d — Twin vs Estimate', ci));

    subplot(4,1,2);
    plot(t, r.twin.V, t, r.estimate.Vm, raw_t, dataOut(ci).voltage);
    ylabel('Voltage (V)'); grid on;
    legend('Twin', 'Estimate', 'Measured');

    subplot(4,1,3);
    plot(t, r.twin.T, t, r.estimate.Tm, raw_t, dataOut(ci).temperature);
    ylabel('Temp (°C)'); xlabel('Time (min)'); grid on;
    legend('Twin', 'Estimate', 'Measured');

    subplot(4,1,4);
    plot(t, r.I_used, 'k');
    ylabel('Current (A)'); grid on;
    legend('I used by model');


    figure('Name', sprintf('%s  |  Cycle %d — Gamma', battery_name, ci));
    plot(t, r.estimate.gamma);
    ylabel('\gamma'); xlabel('Time (min)'); grid on;

    figure('Name', sprintf('%s  |  Cycle %d — Rint vs SoC', battery_name, ci));
    plot(r.estimate.zm, r.estimate.rint);
    xlabel('SoC (%)'); ylabel('R_{int}'); grid on;

    %% Plot all estimated gamma across cycles (continuous time axis)
    figure('Name', sprintf('%s — Gamma (all cycles)', battery_name));

    t_offset = 0;
    hold on;

    for j = 1:length(all_results)
        r = all_results(j);
        t = r.time / 60;
        t_shifted = t - t(1) + t_offset;

        plot(t_shifted, r.estimate.gamma, 'DisplayName', sprintf('Cycle %d', r.cycle_index));

        t_offset = t_shifted(end);
    end

    hold off;
    ylabel('\gamma');
    xlabel('Cumulative time (min)');
    title(sprintf('%s — Estimated \gamma across all cycles', battery_name));
    legend('show', 'Location', 'best');
    grid on;
end
