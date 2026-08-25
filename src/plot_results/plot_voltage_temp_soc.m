%% Monica Felix 27 sept 2025 - plot results
%% Setup
clear all
close all
this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(this_dir));    % 2025/src/plot_results -> 2025/

result_day = "24-sept";
results_path = string(fullfile(proj_root, "results")) + "/";
cycles = [1 400 850];  % <-- Change this to the cycles you want to include
measurement = "degradation";
colors = hsv(numel(cycles));  % Color map for distinct cycle colors
figure(1); clf; hold on;


if (measurement == "soc" || measurement == "degradation")
    legendEntries = strings(1, numel(cycles));
else
    legendEntries = strings(1, 2 * numel(cycles));
end
save_figure= true;
%% Loop over cycles
for i = 1:numel(cycles)
    cycle = cycles(i);
    result_file = result_day + "/" + result_day + "_" + cycle + "_cycle.mat";
    full_path = results_path + result_file;

    % Load cycle data
    cycle_data = load(full_path);

    % Extract struct if needed (adjust variable name if different)
    if isfield(cycle_data, 'cycle_data')
        cd = cycle_data.cycle_data;
    else
        cd = cycle_data;  % If struct is already flattened
    end

    % Plot estimated and true voltages
    if measurement == "voltage"
        plot(cd.simuation_vt_est, ...
             'LineWidth', 2, 'LineStyle', '-', 'Color', colors(i,:));
        plot(cd.simuation_vt_true, ...
             'LineWidth', 2, 'LineStyle', '--', 'Color', colors(i,:));
        ylabel('Voltage (V)', 'Interpreter', 'latex'); 
    elseif measurement == "temperature"
        plot(cd.simuation_temperature_est, ...
             'LineWidth', 2, 'LineStyle', '-', 'Color', colors(i,:));
        plot(cd.simuation_temperature_true, ...
             'LineWidth', 2, 'LineStyle', '--', 'Color', colors(i,:));
        ylabel('Temperature ($^{\circ}$C )', 'Interpreter', 'latex');
    elseif measurement == "soc"
        plot(cd.simuation_soc_est, ...
             'LineWidth', 2, 'LineStyle', '-', 'Color', colors(i,:));
        ylabel('State-of-charge (%)', 'Interpreter', 'latex');
    elseif measurement == "degradation"
        plot(cd.simuation_gamma_est, ...
             'LineWidth', 2, 'LineStyle', '-', 'Color', colors(i,:));
        plot(movmean(cd.simuation_gamma_est,200), ...
             'LineWidth', 2, 'LineStyle', '--', 'Color', colors(i,:));
        ylabel('parameter $d$', 'Interpreter', 'latex');
    end
    % Legend entries
    if measurement == "soc"
        legendEntries(i) = "Cycle " + cycle + " estimated";
    elseif measurement == "degradation"
        legendEntries(2*i-1) = "Cycle " + cycle + " estimated";
        legendEntries(2*i)   = "Cycle " + cycle + " movmean"; 
    else
        legendEntries(2*i-1) = "Cycle " + cycle + " estimated";
        legendEntries(2*i)   = "Cycle " + cycle + " measured"; 
    end

   
end


%% Format plot
xlabel('Time (s)', 'Interpreter', 'latex');
grid on; box on;
legend(legendEntries, ...
             'Interpreter', 'latex', ...
             'Location', 'best');


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

% Optional: Save figure
if save_figure
    saveas(gcf, results_path+result_day+"cycle_plot_"+measurement+".png");
end

