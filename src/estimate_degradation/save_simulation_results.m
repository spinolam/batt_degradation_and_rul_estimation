function save_simulation_results(proj_root, date, battery_name, accum)
%SAVE_SIMULATION_RESULTS Write one battery's accumulated results to
%results/<date>/<date>_<battery_name>.mat, one top-level .mat variable
%per accum field (same schema as before this was factored out).
save_path = fullfile(proj_root, "results", date);
if ~exist(save_path, 'dir')
    mkdir(save_path);
end
save_name = fullfile(save_path, date + "_" + battery_name + ".mat");
save(save_name, '-struct', 'accum');
end
