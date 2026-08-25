% --- Setup ---
clear all
this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(this_dir));    % 2025/src/data_prep -> 2025/

% Every raw .mat under data/constant/ and data/random/ gets loaded, its samples
% are classified constant- vs. random-current (see classify_random below), and
% each non-empty class is written out under the matching data/<class>/prepared/
% folder -- regardless of which of the two input folders the raw file came from.
input_dirs = {fullfile(proj_root, 'data', 'constant'), fullfile(proj_root, 'data', 'random')};

mat_files = {};
for i = 1:numel(input_dirs)
    d = dir(fullfile(input_dirs{i}, '*.mat'));
    for j = 1:numel(d)
        mat_files{end+1} = fullfile(d(j).folder, d(j).name); %#ok<AGROW>
    end
end

for k = 1:numel(mat_files)
    matFile = mat_files{k};
    [~, base, ~] = fileparts(matFile);
    fprintf('=== Processing %s ===\n', base);

    tbl = load_segments_table(matFile);
    is_random = classify_random(tbl);

    write_bucket(tbl(~is_random, :), fullfile(proj_root, 'data', 'constant', 'prepared'), base);
    write_bucket(tbl(is_random, :),  fullfile(proj_root, 'data', 'random',   'prepared'), base);
end

function tbl = load_segments_table(matFile)
% Normalize either raw .mat shape into one per-sample table with columns
% time/voltage/current/temperature/comment.
    s = load(matFile);
    if isfield(s, 'step')
        % NASA "step" format: a struct array, one element per cycling step,
        % each with its own comment/type label and its own time/voltage/
        % current/temperature vectors. Concatenate across all elements
        % (plain `s.step.field` on a struct array only keeps the first
        % element's data, which silently dropped everything but one step).
        steps = s.step;
        time_c = arrayfun(@(st) st.relativeTime(:), steps, 'UniformOutput', false);
        voltage_c = arrayfun(@(st) st.voltage(:), steps, 'UniformOutput', false);
        current_c = arrayfun(@(st) st.current(:), steps, 'UniformOutput', false);
        temperature_c = arrayfun(@(st) st.temperature(:), steps, 'UniformOutput', false);
        comment_c = arrayfun(@(st) repmat({st.comment}, numel(st.relativeTime), 1), steps, 'UniformOutput', false);

        time = vertcat(time_c{:});
        voltage = vertcat(voltage_c{:});
        current = vertcat(current_c{:});
        temperature = vertcat(temperature_c{:});
        comment = vertcat(comment_c{:});
    else
        % Flat I/V/RT export (e.g. the low-current samples) -- no per-sample
        % step label is available.
        current = s.I(:);
        voltage = s.V(:);
        temperature = s.RT(:);
        time = (1:numel(current))';
        comment = repmat({'unlabeled'}, numel(current), 1);
    end
    tbl = table(time, voltage, current, temperature, comment);
end

function is_random = classify_random(tbl)
% Constant-current segments are fixed commanded setpoints (low-current OCV
% discharge, reference charge/discharge, pulsed load/charge, and their rest
% periods); random-current segments are the random-walk steps, whose setpoint
% is redrawn at random every <=5 minutes. Where the source data carries a
% step comment, that vocabulary settles the question directly.
    is_random = false(height(tbl), 1);
    labeled = ~strcmp(tbl.comment, 'unlabeled');
    is_random(labeled) = contains(tbl.comment(labeled), 'random walk');

    unlabeled = ~labeled;
    if any(unlabeled)
        % No step comment available (flat I/V/RT export): fall back to a
        % current-stability heuristic. A random-walk setpoint changes to an
        % unrelated level every <=5 minutes and stays there, while a
        % constant/reference profile holds one level for the entire trace
        % (save for occasional single-sample sensor glitches, e.g. a
        % one-sample ramp-up transient at the very start of a discharge).
        % Median-smooth first so an isolated glitch can't drag a whole
        % window's worth of neighbors into the "random" class, then flag a
        % sample "random" if its current still swings by more than a small
        % tolerance within a trailing window.
        I = tbl.current(unlabeled);
        I_smooth = movmedian(I, min(5, numel(I)));
        win = min(301, numel(I));
        local_range = movmax(I_smooth, win) - movmin(I_smooth, win);
        tol = 0.1 * max(abs(I)) + 1e-6;
        is_random(unlabeled) = local_range > tol;
    end
end

function write_bucket(tbl, out_dir, base)
% Keep only discharge samples (current > 0) and number them into cycles via
% bwlabel, same convention the rest of the pipeline expects from a "mode"
% column, then write one CSV per non-empty class.
    if isempty(tbl)
        return
    end
    is_discharge = tbl.current > 0;
    if ~any(is_discharge)
        return
    end

    [discharge_count_mask, count_cycles] = bwlabel(is_discharge);
    mode = discharge_count_mask * -1;

    battery_prepared = struct();
    battery_prepared.time = tbl.time(is_discharge);
    battery_prepared.voltage_charger = tbl.voltage(is_discharge);
    battery_prepared.current_load = tbl.current(is_discharge);
    battery_prepared.temperature_battery = tbl.temperature(is_discharge);
    battery_prepared.mode = mode(is_discharge);

    if ~exist(out_dir, 'dir')
        mkdir(out_dir);
    end
    out_file = fullfile(out_dir, string(base) + "_prepared.csv");
    writetable(struct2table(battery_prepared), out_file);
    fprintf('  -> %s: %d discharge samples across %d cycles\n', out_file, sum(is_discharge), count_cycles);
end
