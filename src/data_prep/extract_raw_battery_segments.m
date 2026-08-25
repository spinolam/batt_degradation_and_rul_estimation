% --- Setup ---
clear all
this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(this_dir));    % 2025/src/data_prep -> 2025/

% Isolate the useful step types out of every raw multi-step battery log --
% the same idea NASA's own MatlabSamplePlots.m reference script uses per
% dataset (filter data.step by comment, e.g. 'reference discharge' or the
% random-walk comments), generalized to run over every raw battery and save
% the result instead of just plotting it.
raw_root = fullfile(proj_root, 'data', 'raw', 'randomized_battery_usage');
raw_files = find_raw_battery_files(raw_root);

categories = {'random_walk', 'low_current', 'reference', 'pulsed'};
% Substring each category's keyword must appear in a step's (lowercased)
% comment. A substring check is deliberately broader than an exact-comment
% whitelist: it also catches phrasing that varies across NASA sub-datasets
% (e.g. "reference power discharge", "rest prior reference discharge",
% "charge (after random walk discharge)") without listing every variant.
keywords = {'random walk', 'low current', 'reference', 'pulsed'};

for k = 1:numel(raw_files)
    rawFile = raw_files{k};
    [~, battery_name, ~] = fileparts(rawFile);
    fprintf('=== %s ===\n', battery_name);

    s = load(rawFile);
    steps = s.data.step;
    comment_lower = lower({steps.comment});

    assigned = false(size(steps));
    for c = 1:numel(categories)
        mask = contains(comment_lower, keywords{c});
        assigned = assigned | mask;
        write_category(steps(mask), proj_root, battery_name, categories{c});
    end

    % Anything not matched by a known keyword is kept, not dropped, so an
    % unrecognized step type doesn't silently disappear.
    write_category(steps(~assigned), proj_root, battery_name, 'other');
end

function raw_files = find_raw_battery_files(raw_root)
    d = dir(fullfile(raw_root, '**', 'data', 'Matlab', 'RW*.mat'));
    raw_files = arrayfun(@(x) fullfile(x.folder, x.name), d, 'UniformOutput', false);
end

function write_category(step, proj_root, battery_name, category)
    if isempty(step)
        return
    end
    out_dir = fullfile(proj_root, 'data', 'extracted', battery_name);
    if ~exist(out_dir, 'dir')
        mkdir(out_dir);
    end
    out_file = fullfile(out_dir, string(category) + ".mat");
    save(out_file, 'step');
    fprintf('  %-12s %5d steps -> %s\n', category, numel(step), out_file);
end
