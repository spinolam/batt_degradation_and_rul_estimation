function plot_discharge_results(battery_name, dataOut, all_results, cycle_to_plot)
%PLOT_DISCHARGE_RESULTS Standard figure set for a simulate_discharge_cycle
%run: one cycle's twin-vs-estimate-vs-measured traces, gamma and R_int/Voc
%vs SOC for that cycle, and estimated gamma across all cycles. Shared by
%simulate_random_discharge_matlab.m and simulate_reference_discharge_matlab.m.
%
% cycle_to_plot selects which entry of all_results to show in detail
% (defaults to the first).
if nargin < 4
    cycle_to_plot = 1;
end

r  = all_results(cycle_to_plot);
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
ylabel('Current (A)'); xlabel('Time (min)'); grid on;
legend('I used by model');

figure('Name', sprintf('%s  |  Cycle %d — Gamma', battery_name, ci));
plot(t, r.estimate.gamma);
ylabel('\gamma'); xlabel('Time (min)'); grid on;

figure('Name', sprintf('%s  |  Cycle %d — Rint vs SoC', battery_name, ci));
plot(r.estimate.zm, r.estimate.rint);
xlabel('SoC (%)'); ylabel('R_{int}'); grid on;

figure('Name', sprintf('%s  |  Cycle %d — Voc vs SoC', battery_name, ci));
plot(r.twin.z, r.twin.voc);
xlabel('SoC (%)'); ylabel('V_{oc}'); grid on;

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
