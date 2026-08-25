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
%  EXTRACT DISCHARGE DATA
% ==========================================================

Z0 = 99.5;      % Initial SOC
capacity = 2.5; % Battery capacity [Ah]

% Extract three discharge segments
[X1,Y1,Y1m1,I1,Z1,T1,T1m1] = extractDischarge(battery_data,-2,Z0,capacity);
[X3,Y3,Y3m1,I3,Z3,T3,T3m1] = extractDischarge(battery_data,-3,Z0,capacity);
[X4,Y4,Y4m1,I4,Z4,T4,T4m1] = extractDischarge(battery_data,-4,Z0,capacity);

%% ===================== FILTER TEMPERATURE ================
Y2  = T1(2:end);
Y2m1 = T1m1;
Y5  = T3(2:end);
Y5m1 = T3m1;
Y6  = T4(2:end);
Y6m1 = T4m1;

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

error_func = @(p) batteryErrorFunction(p,...
    Y1,Y1m1,I1,Z1,...
    Y3,Y3m1,I3,Z3,...
    Y4,Y4m1,I4,Z4,...
    Y2,Y2m1,Y5,Y5m1,Y6,Y6m1);

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

%% =========================================================
%  MODEL OUTPUT
% ==========================================================

output = [
    Y1;Y3;Y4;Y2;Y5;Y6
] + error_func(params_opt);

%% ===================== VALIDATION PLOTS ==================

figure(3); clf;
plot(X3,Y3,'r','LineWidth',2); hold on
plot(X3,output(length(Y1)+1:length(Y1)+length(Y3)),'--b','LineWidth',2)
legend('Measured','Model')
xlabel('Time (s)')
ylabel('Voltage (V)')
grid on

figure(4); clf;
plot(Z4,polyResistance(params_opt,Z4),'LineWidth',2)
xlabel('SOC (%)')
ylabel('Internal Resistance')
grid on

figure(5); clf;
plot(Z4,ocvModel(params_opt,Z4),'LineWidth',2)
xlabel('SOC (%)')
ylabel('Open Circuit Voltage')
grid on

figure(6); clf;
plot(X4,Y6,'r','LineWidth',2); hold on
plot(X4,output(end-length(Y6)+1:end),'--b','LineWidth',2)
legend('Measured','Model')
xlabel('Time (s)')
grid on

%% =========================================================
%  ================== LOCAL FUNCTIONS ======================
% ==========================================================

function [X,Y,Ym1,I,Z,T,Tm1] = extractDischarge(data,modeID,Z0,capacity)

    mask = data.mode == modeID;

    Xraw = data.time(mask);
    Vraw = data.voltage_charger(mask);
    Iraw = data.current_load(mask);
    Traw = data.temperature_battery(mask);

    X = Xraw(2:end);
    Y = Vraw(2:end);
    Ym1 = Vraw(1:end-1);
    I = Iraw(2:end);

    T = Traw;
    Tm1 = Traw(1:end-1);

    % SOC calculation
    Z = Z0 * ones(length(Y),1);

    for k = 2:length(Z)
        dt = X(k) - X(k-1);
        Z(k:end) = Z(k-1) - dt*100*I(k)/(3600*capacity);
        Z(Z < 0.001) = 0.001;
    end
end

function err = batteryErrorFunction(p,...
    Y1,Y1m1,I1,Z1,...
    Y3,Y3m1,I3,Z3,...
    Y4,Y4m1,I4,Z4,...
    Y2,Y2m1,Y5,Y5m1,Y6,Y6m1)

    R1 = polyResistance(p,Z1);
    R3 = polyResistance(p,Z3);
    R4 = polyResistance(p,Z4);

    OCV1 = ocvModel(p,Z1);
    OCV3 = ocvModel(p,Z3);
    OCV4 = ocvModel(p,Z4);

    V1 = p(1)*Y1m1 + (1-p(1))*(OCV1 - I1.*R1);
    V3 = p(1)*Y3m1 + (1-p(1))*(OCV3 - I3.*R3);
    V4 = p(1)*Y4m1 + (1-p(1))*(OCV4 - I4.*R4);

    T1 = p(10)*Y2m1 + (1-p(10))*(p(12) + p(11)*I1.^2.*R1);
    T3 = p(10)*Y5m1 + (1-p(10))*(p(12) + p(11)*I3.^2.*R3);
    T4 = p(10)*Y6m1 + (1-p(10))*(p(12) + p(11)*I4.^2.*R4);

    err = [
        V1 - Y1
        V3 - Y3
        V4 - Y4
        T1 - Y2
        T3 - Y5
        T4 - Y6
    ];
end

function R = polyResistance(p,Z)
    R = p(5) + p(6)*Z + p(7)*Z.^2 + p(8)*Z.^3 + p(9)*Z.^4;
end

function OCV = ocvModel(p,Z)
    OCV = p(2) - p(3)*log(100-Z) - p(4)./Z;
end