%% pre-data
%% Pure-MATLAB (non-Simulink) alternate driver for the random-walk pipeline:
%% runs battery_twin.m + observer_lpv.m + calcule_l_observer.m (via the
%% shared simulate_discharge_cycle.m) sample-by-sample, over the raw
%% multi-step random-walk log instead of a Simulink model. Operates on
%% RW_Skewed_High_Room_Temp_DataSet_17's raw `random_walk_discharge` steps
%% (grouped into cycles below); compare with simulate_reference_discharge_matlab.m,
%% which runs the same twin/observer pair over the already-cycle-segmented
%% `ref_discharges` data instead.
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
    cfg.Cr             = Cr;
    cfg.z0              = 99.5;
    cfg.gamma0          = 1;
    cfg.voltage_cutoff  = 3.2;

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

        cycle_result = simulate_discharge_cycle(i, datacycle, cfg, params, L, ...
            pho1_min, pho1_max, pho2_min, pho2_max);

        if isempty(all_results)
            all_results = cycle_result;
        else
            all_results(end+1) = cycle_result;
        end
    end

    %% Visualization
    plot_discharge_results(battery_name, dataOut, all_results);
end
