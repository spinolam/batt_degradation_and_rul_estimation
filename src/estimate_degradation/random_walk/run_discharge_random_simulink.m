%% Mônica Spinola Felix mai. 2023
%% Code for running many discharge as a sequence of many days
%% with the idea of estimating gamma and degradation parameter
%% Simulink-driven driver for the random-walk / gain-scheduled LPV pipeline.
clc;
close all;

this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(fileparts(this_dir)));   % .../src/estimate_degradation/random_walk -> src/estimate_degradation -> src -> project root
models_dir = fullfile(proj_root, "src", "models");
addpath(fullfile(proj_root, "src", "estimate_degradation"));  % init_simulation_accumulator / accumulate_cycle_results / save_simulation_results

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

    % Load fitted equivalent-circuit parameters (base-workspace var "params",
    % read by the .slx model's blocks; also needed here for Cr/a below)
    load(fullfile(proj_root, "src", "identify_parameters", "parameters", battery_name), 'params_opt');
    params = params_opt;

    % Simulation settings
    Ts = 1;
    seed = 1;
    h_mean = 4;
    gamma_mean = 1.5;
    Cr = 2.5;
    a = params(1);

    % Load model setup
    run(fullfile(this_dir, "lqr_synthesis_observer_gain_scheduled_lpv.m"));

    % Initialize variables (CLEAR before each battery)
    random_params = 0;
    accum = init_simulation_accumulator();
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

        accum = accumulate_cycle_results(accum, i, r);
    end

    % Save results
    save_simulation_results(proj_root, date, battery_name, accum);

    % Optional: Compute RMSE and display
    fprintf('RMSE LPV for %s: %.4f\n', battery_name, ...
        sqrt(mean((movmean(accum.simuation_temperature_est, 1) - accum.simuation_temperature_true).^2)));
end
