%% =========================================================
%  BATTERY PARAMETER IDENTIFICATION
% ==========================================================

clear; clc;

this_dir = fileparts(mfilename('fullpath'));
proj_root = fileparts(fileparts(this_dir));    % 2025/src/identify_parameters -> 2025/
parent_root = fileparts(proj_root);            % batt_gamma_estimation/ (shared "prepared data/" lives here)

%% ===================== LOAD DATA =========================
battery_name = 'battery01.csv';
dataFile = fullfile(parent_root, 'prepared data', battery_name);
battery_data = readtable(dataFile);

%% ===================== QUICK OVERVIEW PLOTS ==============
figure(1); clf;

ax1 = subplot(3,1,1);
plot(battery_data.temperature_battery);
ylabel('Temperature')

ax2 = subplot(3,1,2);
plot(battery_data.current_load);
ylabel('Current')

ax3 = subplot(3,1,3);
plot(battery_data.mode);
ylabel('Mode')
xlabel('Samples')

linkaxes([ax1 ax2 ax3],'x');

%% =========================================================
%  EXTRACT DISCHARGE SEGMENTS
% ==========================================================

Z0 = 99.5;      % Initial SOC
capacity = 2.5; % Battery capacity [Ah]

modeIDs = [-2, -3, -4];
seg = repmat(struct('X',[],'V',[],'Vm1',[],'I',[],'Z',[],'T',[],'Tm1',[]), 1, numel(modeIDs));
for i = 1:numel(modeIDs)
    seg(i) = extractDischarge(battery_data, modeIDs(i), Z0, capacity);
end

%% =========================================================
%  PARAMETER INITIAL GUESS
% ==========================================================

params0 = [
    0.907066127550203
    8.4
    0.053030385264628
    0.322086183557108
    0.076649168306210
   -0.001670514522271
    0.000043481555886
   -0.000000670561209
    0.000000003521356
    0.999
    16
    23
];

%% ===================== ERROR FUNCTION ====================

error_func = @(p) batteryErrorFunction(p, seg);

%% ===================== CONSTRAINTS =======================

lb = -inf(12,1);
ub =  inf(12,1);

lb(1)=0;      ub(1)=0.9;
lb(2)=8;      ub(2)=8.6;
lb(5)=0;      ub(5)=1;
lb(10)=0.9;   ub(10)=1;
lb(12)=23;    ub(12)=23;

%% ===================== OPTIMIZATION ======================

options = optimoptions('lsqnonlin','Display','iter');
[params_opt,resnorm] = lsqnonlin(error_func,params0,lb,ub,options);

disp('Optimized Parameters:')
disp(params_opt)
disp('Residual Norm:')
disp(resnorm)

reportArCoefficient('Voltage AR coefficient  p(1)', params_opt(1), lb(1), ub(1));
reportArCoefficient('Thermal AR coefficient  p(10)', params_opt(10), lb(10), ub(10));

%% =========================================================
%  MODEL OUTPUT
% ==========================================================

output = [vertcat(seg.V); vertcat(seg.T)] + error_func(params_opt);

%% ===================== VALIDATION PLOTS ==================

figure(3); clf;
plot(seg(2).X,seg(2).V,'r','LineWidth',2); hold on
plot(seg(2).X,output(numel(seg(1).V)+1:numel(seg(1).V)+numel(seg(2).V)),'--b','LineWidth',2)
legend('Measured','Model')
xlabel('Time (s)')
ylabel('Voltage (V)')
grid on

figure(4); clf;
plot(seg(3).Z,polyResistance(params_opt,seg(3).Z),'LineWidth',2)
xlabel('SOC (%)')
ylabel('Internal Resistance')
grid on

figure(5); clf;
plot(seg(3).Z,ocvModel(params_opt,seg(3).Z),'LineWidth',2)
xlabel('SOC (%)')
ylabel('Open Circuit Voltage')
grid on

figure(6); clf;
plot(seg(3).X,seg(3).T,'r','LineWidth',2); hold on
plot(seg(3).X,output(end-numel(seg(3).T)+1:end),'--b','LineWidth',2)
legend('Measured','Model')
xlabel('Time (s)')
grid on

%% =========================================================
%  ================== LOCAL FUNCTIONS ======================
% ==========================================================

function s = extractDischarge(data,modeID,Z0,capacity)

    mask = data.mode == modeID;

    Xraw = data.time(mask);
    Vraw = data.voltage_charger(mask);
    Iraw = data.current_load(mask);
    Traw = data.temperature_battery(mask);

    s.X = Xraw(2:end);
    s.V = Vraw(2:end);
    s.Vm1 = Vraw(1:end-1);
    s.I = Iraw(2:end);

    s.T = Traw(2:end);
    s.Tm1 = Traw(1:end-1);

    % SOC calculation (Coulomb counting)
    s.Z = Z0 * ones(length(s.V),1);
    for k = 2:length(s.Z)
        dt = s.X(k) - s.X(k-1);
        s.Z(k) = max(s.Z(k-1) - dt*100*s.I(k)/(3600*capacity), 0.001);
    end
end

function err = batteryErrorFunction(p, seg)

    err = [];
    for i = 1:numel(seg)
        R = polyResistance(p,seg(i).Z);
        OCV = ocvModel(p,seg(i).Z);
        V = p(1)*seg(i).Vm1 + (1-p(1))*(OCV - seg(i).I.*R);
        err = [err; V - seg(i).V]; %#ok<AGROW>
    end

    for i = 1:numel(seg)
        R = polyResistance(p,seg(i).Z);
        T = p(10)*seg(i).Tm1 + (1-p(10))*(p(12) + p(11)*seg(i).I.^2.*R);
        err = [err; T - seg(i).T]; %#ok<AGROW>
    end
end

function R = polyResistance(p,Z)
    R = p(5) + p(6)*Z + p(7)*Z.^2 + p(8)*Z.^3 + p(9)*Z.^4;
end

function OCV = ocvModel(p,Z)
    OCV = p(2) - p(3)*log(100-Z) - p(4)./Z;
end

function reportArCoefficient(label, value, lb, ub)
    tol = 0.02*(ub-lb);
    physicalWeight = 1 - value;
    fprintf('%s = %.4f  (bounds [%.4f, %.4f], physical-model weight (1-p) = %.4f)\n', ...
        label, value, lb, ub, physicalWeight);
    if (value - lb) < tol || (ub - value) < tol
        warning(['%s is within 2%% of its bound. The physical OCV/R (or thermal) ' ...
                 'submodel may be getting little leverage in this fit -- treat the ' ...
                 'validation plots with caution.'], label);
    end
end
