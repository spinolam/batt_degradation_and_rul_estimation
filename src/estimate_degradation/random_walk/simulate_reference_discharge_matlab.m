%% pre-data
%% Pure-MATLAB (non-Simulink) driver for the random-walk pipeline, operating
%% on the already-cycle-segmented `ref_discharges` data (see
%% simulate_random_discharge_matlab.m for the raw-log counterpart). Both
%% drivers share their per-cycle simulation loop (simulate_discharge_cycle.m)
%% and plotting (plot_discharge_results.m).
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
    dataFile = fullfile(proj_root, "data", "random_walk_data", battery_name + ".mat");
    load(dataFile, "ref_discharges");
    dataOut = ref_discharges;

    load(fullfile(proj_root, "src", "identify_parameters", "parameters", battery_name), 'params_opt');
    % Initialize results struct array for this battery
    params = params_opt;
    all_results = struct([]);
    max_cycle   = length(dataOut);
    % Simulation parameters
    Ts   = 30;
    seed = 1;
    Cr   = 2.5;
    a    = params(1);
    cfg.Cr             = Cr;
    cfg.z0              = 99.5;
    cfg.gamma0          = 1;
    cfg.voltage_cutoff  = 3.2;

    % Load model setup
    run(fullfile(this_dir, "lqr_synthesis_observer_gain_scheduled_lpv.m"));

    %% Loop over every cycle in ref_discharges
    for i = 1:1

        datacycle = dataOut(i);

        % Skip non-discharge or low-current cycles
        if ~(mean(datacycle.current) > 0.98 && strcmp(datacycle.type, "D"))
            continue;
        end

        fprintf('  Simulating cycle %d / %d\n', i, max_cycle);

        cycle_result = simulate_discharge_cycle(i, datacycle, cfg, params, L, ...
            pho1_min, pho1_max, pho2_min, pho2_max);

        % Append to battery-level struct array
        if isempty(all_results)
            all_results = cycle_result;
        else
            all_results(end+1) = cycle_result;
        end
    end

    %% Visualization
    plot_discharge_results(battery_name, dataOut, all_results);
end
