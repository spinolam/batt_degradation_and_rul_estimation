% --- Load ---
clear all
this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(this_dir));    % 2025/src/data_prep -> 2025/
parent_root = fileparts(proj_root);            % batt_gamma_estimation/ (shared "prepared data/" lives here)

data_name = "random";
battery_data = open(fullfile(proj_root, "data", "random", data_name + ".mat"));

if data_name == "low_current"
    temperature = battery_data.RT;
    voltage = battery_data.V;
    current = battery_data.I;
    time = (1:length(current)); % or load it if available
else
    temperature = battery_data.step.temperature;
    voltage = battery_data.step.voltage;
    current = battery_data.step.current;
    time = battery_data.step.relativeTime;
end

% --- Process ---
is_charge = current < 0;
is_discharge = current > 0;

[discharge_count_mask, count_cycles] = bwlabel(is_discharge);

mode = discharge_count_mask * -1;  % or any labeling logic you need

plot(mode)
title('Battery Operating Mode')
xlabel('Sample Index')
ylabel('Mode')

% --- Save ---
% Column vectors, one row per sample, named to match the schema every
% downstream script expects (time, voltage_charger, current_load,
% temperature_battery, mode).
battery_random = struct();
battery_random.time = time(is_discharge)';
battery_random.voltage_charger = voltage(is_discharge)';
battery_random.current_load = current(is_discharge)';
battery_random.temperature_battery = temperature(is_discharge)';
battery_random.mode = mode(is_discharge)';
%
figure
plot(mode)

battery_name = data_name + "_prepared.csv";
writetable(struct2table(battery_random), fullfile(parent_root, "prepared data", battery_name));

disp("Saved processed battery data as " + battery_name)

