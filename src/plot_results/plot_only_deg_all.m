%% Monica Felix 4 oct 2025 - plot results
%% Setup
clear all; close all;

this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(this_dir));    % 2025/src/plot_results -> 2025/

% Settings
result_day = "4-oct";
results_path = string(fullfile(proj_root, "results")) + "/";
save_figure = true;
plot_mean = true;

% Define battery groups by type
battery_types = {
    ["battery01","battery11"],     % Type 1
    ["battery31","battery22"],     % Type 2
    ["battery52"],                 % Type 3
    ["battery00","battery10"],     % Type 4
    ["battery20","battery30","battery21"], % Type 5
   % ["battery41","battery51"],     % Type 6
  %  ["battery40","battery50"]      % Type 7
};

legend_types={
    ["9.30 A","9.30 A"],     % Type 1
    ["12.9 A","12.9 A"],     % Type 2
    ["14.3 A"],                 % Type 3
    ["16 A","16 A"],     % Type 4
    ["19 A","19 A","19 A"], % Type 5
   % ["battery41","battery51"],     % Type 6
  %  ["battery40","battery50"]      % Type 7
};

% Define colors for each type (7 types → 7 colors)
type_colors = hsv(length(battery_types)); % built-in MATLAB colormap

% Figure setup
figure(1); clf; hold on;
legendEntries = [];
plot_object = [];

            

% Loop through each battery type
for type_idx = 1:length(battery_types)
    battery_group = battery_types{type_idx};
    discharge_group = legend_types{type_idx};
    base_color = type_colors(type_idx, :);
    
    % Loop through each battery in the current type
    for batt_idx = 1:length(battery_group)
        battery_name = battery_group(batt_idx);
        legend_type = discharge_group(batt_idx);
        
        % Optional: Slight color variation for each battery in group
        % Can be commented out if not needed
        color_variation = base_color * (0.95 + 0.0 * rand());
        color = min(max(color_variation, 0), 1); % Ensure RGB stays valid

        result_file = result_day + "/" + result_day + "_" + battery_name + ".mat";
        full_path = results_path + result_file;

        if isfile(full_path)
            battery_data = load(full_path);
            deg_mean_vector=[];
            for i=2:max(battery_data.count_cycle)+1
                mean_fisrt = mean(battery_data.simuation_gamma_est(battery_data.count_cycle==2));
                deg_mean = 2.5*mean_fisrt/mean(battery_data.simuation_gamma_est(battery_data.count_cycle==i));
                deg_mean_vector = [deg_mean_vector; deg_mean ];
            end

            % Compute plot data
            cum_energy = cumsum(-battery_data.simuation_current_input .* battery_data.simuation_vt_true) / 3600 / 1000;
            filtered = movmean(battery_data.simuation_gamma_est, 1.5e4);
            
            parameter_d = 2.5 * mean_fisrt(1) ./ filtered;

            % Plot with consistent line style and type-specific color

            if plot_mean
                h1=scatter(1:max(battery_data.count_cycle),deg_mean_vector, ...
                   'Marker','.','MarkerEdgeColor',color, 'MarkerFaceColor', color,'LineWidth',0.5);
            else
                h1=plot(cum_energy, parameter_d, ...
                'Color', color, ...
                'LineStyle', '-', ...
                'LineWidth', 1.5);
            end
        else
            warning("File not found: %s", full_path);
        end
    end
    plot_object = [plot_object, h1];
    legendEntries = [legendEntries, legend_type];
end

% Axis labels and legend
if plot_mean
    ylabel('Estimated average capacity $Ah$', 'Interpreter', 'latex');
else
    ylabel('Estimated capacity $Ah$', 'Interpreter', 'latex');
end
xlabel('Cumulated energy (kWh)', 'Interpreter', 'latex');
grid on; box on;

legend(plot_object,legendEntries, ...
    'Interpreter', 'latex', ...
    'Location', 'best');

% Styling
set(gca, ...
    'FontSize', 12, ...
    'FontName', 'Times', ...
    'TickLabelInterpreter', 'latex', ...
    'LineWidth', 1);

set(gcf, ...
    'Units', 'centimeters', ...
    'Position', [2, 2, 20, 10], ...
    'PaperUnits', 'centimeters', ...
    'PaperPosition', [0, 0, 20, 10]);

% Save figure
if save_figure
    if plot_mean
        saveas(gcf, results_path + "battery_comparison_mean_" + result_day + ".png");
    else
        saveas(gcf, results_path + "battery_comparison_" + result_day + ".png");
    end
end

