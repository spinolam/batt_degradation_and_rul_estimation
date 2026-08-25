function accum = accumulate_cycle_results(accum, cycle_index, r)
%ACCUMULATE_CYCLE_RESULTS Append one simulated cycle's Simulink output
%(the sim() return object r, with fields current_input/gammaf/gammaf_est/
%soc/soc_est/vt/vt_est/temperature/temperature_est) to a running
%per-battery accumulator built by init_simulation_accumulator.m.
n = length(r.current_input(:, 1));
accum.count_cycle = [accum.count_cycle, cycle_index * ones(1, n)];

true_capacity = cumsum(-r.current_input(:, 1)) / 3600;
accum.capacity_vector = [accum.capacity_vector, true_capacity(end) * ones(1, n)];

accum.simuation_current_input    = [accum.simuation_current_input,    r.current_input(:, 1)'];
accum.simuation_gamma_est        = [accum.simuation_gamma_est,        r.gammaf_est(:, 1)'];
accum.simuation_gamma_true       = [accum.simuation_gamma_true,       r.gammaf(:, 1)'];
accum.simuation_soc_est          = [accum.simuation_soc_est,          r.soc_est(:, 1)'];
accum.simuation_soc_true         = [accum.simuation_soc_true,         r.soc(:, 1)'];
accum.simuation_vt_est           = [accum.simuation_vt_est,           r.vt_est(:, 1)'];
accum.simuation_vt_true          = [accum.simuation_vt_true,          r.vt(:, 1)'];
accum.simuation_temperature_est  = [accum.simuation_temperature_est,  r.temperature_est(:, 1)'];
accum.simuation_temperature_true = [accum.simuation_temperature_true, r.temperature(:, 1)'];
end
