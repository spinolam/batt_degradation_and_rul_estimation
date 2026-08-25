%% Mônica Spinola Felix mai. 2023
%% Code for running many discharge as a sequence of many days
%% with the idea of estimating gamma and degradation parameter
clc;
close all;

this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(this_dir));    % 2025/src/estimate_degradation -> 2025/
parent_root = fileparts(proj_root);            % batt_gamma_estimation/ (shared "prepared data/" lives here)
models_dir = fullfile(proj_root, "src", "models");

% Define list of batteries to simulate
%battery_list = [ "battery00",  "battery01" , "battery10" , "battery11" , "battery20"  ,"battery21" , "battery23" , "battery30",  "battery31" , "battery40" , "battery41" , "battery50" , "battery51",  "battery52"
%];  % Add more as needed
battery_list = ["random"];
%battery_list = [ "battery00"];
date = "24-oct";  % Shared date across all simulations

% Loop over each battery
for b = 1:length(battery_list)
    battery_name = battery_list(b);
    fprintf('=== Simulating %s ===\n', battery_name);

    % Load data
    if battery_name == "random"
       battery_file = battery_name+ ".mat";
       dataFile = fullfile(parent_root, "prepared data", battery_file);
        dataOut = load(dataFile);
        dataOut = dataOut.step;
        dataOut.time = dataOut.relativeTime';
        dataOut.mode = -4*ones(length(dataOut.time),1);
        dataOut.voltage_charger = dataOut.voltage';
        dataOut.temperature_battery = dataOut.temperature';
        dataOut.current_load = dataOut.current';

    else
        battery_file = battery_name+ ".csv";
        dataFile = fullfile(parent_root, "prepared data", battery_file);
        dataOut = readtable(dataFile);
        

    end
    

    % Simulation settings
    Ts = 1;
    seed = 1;
    h_mean = 4;
    Ts_power = 3600;
    gamma_mean = 1.5;

    % Load model setup
    run(fullfile(models_dir, "lqr_synthesis_observer_simple_Lx3x3_no_VOC.m"));

    % Initialize variables (CLEAR before each battery)
    random_params = 0;
    accum = init_simulation_accumulator();
    gamma0 = gamma_mean;
    gamma0_est = gamma_mean;
    max_cycle = -1 * min(dataOut.mode);

    % Simulate cycles
    for i = 1:max_cycle
        disp(i)
        gamma0 = gamma_mean;

        mask_chosen = dataOut.mode == -i;
        if mean(dataOut.current_load(mask_chosen)) > -1000
            time_vector = dataOut.time(mask_chosen);
            time_vector = time_vector - time_vector(1);
            voltage_vector = dataOut.voltage_charger(mask_chosen);
            current_load_vector = dataOut.current_load(mask_chosen);
            temperature_vector = dataOut.temperature_battery(mask_chosen);

            ts_vt_many_cycles = timeseries(voltage_vector, time_vector);
            ts_ik_many_cycles = timeseries(current_load_vector, time_vector);
            ts_tk_many_cycles = timeseries(temperature_vector, time_vector);
            ts_time = timeseries(time_vector, time_vector);

            % Run simulation
            r = sim(fullfile(models_dir, "estimation_data_with_new_parameter_new.slx"));
            gamma0 = r.gammaf(end);
            gamma0_est = r.gammaf_est(end);

            accum = accumulate_cycle_results(accum, i, r);
        end
    end

    % Save results
    save_simulation_results(proj_root, date, battery_name, accum);

    % Optional: Compute RMSE and display
    fprintf('RMSE LPV for %s: %.4f\n', battery_name, ...
        sqrt(mean((movmean(accum.simuation_gamma_est, 1) - accum.simuation_gamma_true).^2)));

    % Optional: Save figures or skip
    % figure(...); print(...);
    % close all; % optional if figures not needed

end
