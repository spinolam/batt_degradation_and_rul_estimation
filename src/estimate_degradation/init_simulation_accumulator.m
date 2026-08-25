function accum = init_simulation_accumulator()
%INIT_SIMULATION_ACCUMULATOR Empty per-battery result accumulator.
% Field names match the .mat schema written by save_simulation_results.m
% (kept as-is, including the "simuation_" spelling, so existing
% results/<date>/*.mat files and src/plot_results/ scripts stay readable).
accum.simuation_soc_est = [];
accum.simuation_vt_est = [];
accum.simuation_temperature_est = [];
accum.simuation_gamma_true = [];
accum.simuation_soc_true = [];
accum.simuation_vt_true = [];
accum.simuation_temperature_true = [];
accum.simuation_gamma_est = [];
accum.simuation_current_input = [];
accum.count_cycle = [];
accum.capacity_vector = [];
end
