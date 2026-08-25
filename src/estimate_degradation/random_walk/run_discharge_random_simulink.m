%% Mônica Spinola Felix mai. 2023
%% Code for running many discharge as a sequence of many days
%% with the idea of estimating gamma and degradation parameter
%% Simulink-driven driver for the random-walk / gain-scheduled LPV pipeline.
clc;
close all;

this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(fileparts(this_dir)));   % .../src/estimate_degradation/random_walk -> src/estimate_degradation -> src -> project root
models_dir = fullfile(proj_root, "src", "models");

% Define list of batteries to simulate
battery_list = ["RW_Skewed_High_Room_Temp_DataSet_17"];
date = "1-mars";  % Shared date across all simulations

% Loop over each battery
for b = 1:length(battery_list)
    battery_name = battery_list(b);
    fprintf('=== Simulating %s ===\n', battery_name);

    % Load data
    battery_file = battery_name + ".mat";
    dataFile = fullfile(proj_root, "data", "random_walk_data", battery_file);
    dataOut = load(dataFile);
    dataOut = dataOut.ref_discharges;

    % Simulation settings
    Ts = 1;
    seed = 1;
    h_mean = 4;
    gamma_mean = 1.5;

    % Load model setup
    run(fullfile(this_dir, "lqr_synthesis_observer_gain_scheduled_lpv.m"));

    % Initialize variables (CLEAR before each battery)
    random_params = 0;
    simuation_gamma_est = [];
    simuation_gamma_true = [];
    simuation_soc_est = [];
    simuation_soc_true = [];
    simuation_vt_est = [];
    simuation_vt_true = [];
    simuation_temperature_est = [];
    simuation_temperature_true = [];
    simuation_current_input = [];
    count_cycle = [];
    capacity_vector = [];
    gamma0 = gamma_mean;
    gamma0_est = gamma_mean;
    max_cycle = length(dataOut);

    % Simulate cycles
    for i = 1:max_cycle
        disp(i)
        gamma0 = gamma_mean;
        datacycle = dataOut(i);

        mask_chosen = (datacycle.current>0)';

        time_vector = datacycle.time(mask_chosen)';
        time_vector = time_vector - time_vector(1);
        voltage_vector = datacycle.voltage(mask_chosen)';
        current_load_vector = datacycle.current(mask_chosen)';
        temperature_vector = datacycle.temperature(mask_chosen)';

        ts_vt_many_cycles = timeseries(voltage_vector, time_vector);
        ts_ik_many_cycles = timeseries(current_load_vector, time_vector);
        ts_tk_many_cycles = timeseries(temperature_vector, time_vector);
        ts_time = timeseries(time_vector, time_vector);

        % Run simulation
        r = sim(fullfile(models_dir, "estimation_random.slx"));
        gamma0 = r.gammaf(end);
        gamma0_est = r.gammaf_est(end);

        count_cycle = [count_cycle i * ones(1, length(r.current_input(:, 1)))];
        true_capacity = cumsum(-r.current_input(:, 1)) / 3600;
        capacity_vector = [capacity_vector true_capacity(end) * ones(1, length(r.current_input(:, 1)))];

        simuation_current_input = [simuation_current_input r.current_input(:, 1)'];
        simuation_gamma_est = [simuation_gamma_est r.gammaf_est(:, 1)'];
        simuation_gamma_true = [simuation_gamma_true r.gammaf(:, 1)'];
        simuation_soc_est = [simuation_soc_est r.soc_est(:, 1)'];
        simuation_soc_true = [simuation_soc_true r.soc(:, 1)'];
        simuation_vt_est = [simuation_vt_est r.vt_est(:, 1)'];
        simuation_vt_true = [simuation_vt_true r.vt(:, 1)'];
        simuation_temperature_est = [simuation_temperature_est r.temperature_est(:, 1)'];
        simuation_temperature_true = [simuation_temperature_true r.temperature(:, 1)'];
    end

    % Save results
    save_path = fullfile(proj_root, "results", date);
    if ~exist(save_path, 'dir')
        mkdir(save_path);
    end
    save_name = fullfile(save_path, date + "_" + battery_name + ".mat");
    save(save_name, ...
        "simuation_soc_est", "simuation_vt_est", "simuation_temperature_est", ...
        "simuation_gamma_true", "simuation_soc_true", "simuation_vt_true", ...
        "simuation_temperature_true", "simuation_gamma_est", ...
        "simuation_current_input", "count_cycle", "capacity_vector");

    % Optional: Compute RMSE and display
    fprintf('RMSE LPV for %s: %.4f\n', battery_name, ...
        sqrt(mean((movmean(simuation_temperature_est, 1) - simuation_temperature_true).^2)));
end
