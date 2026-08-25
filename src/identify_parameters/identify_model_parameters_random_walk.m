new_run=1;
if new_run
    clc
    clear all
    this_dir = fileparts(mfilename('fullpath'));
    proj_root = fileparts(fileparts(this_dir));    % 2025/src/identify_parameters -> 2025/
    battery_name='low_current.mat';
    dataFile = fullfile(proj_root, 'data', 'constant', battery_name);
    battery_data = open(dataFile);
    print_on=0;
end

%% Plot discharges 
battery_data.time =  battery_data.RT;
battery_data.voltage_charger =  battery_data.V;
battery_data.current_load =  battery_data.I;


figure(1)
ax1=subplot(2,1,1);
plot(battery_data.RT)
ax2=subplot(2,1,2);
plot(battery_data.I)
linkaxes([ax1 ax2],'x')

%% Select discharge
chosen_discharge=2;
mask_discharge=ones(size(battery_data.I));

X  = battery_data.time;
X  = X(2:end);

Voltage = battery_data.voltage_charger;
Y1     = Voltage(2:end);
Y1m1   = Voltage(1:end-1);

I      = battery_data.current_load;
I      = I(2:end);

figure(2)
subplot(2,1,1); plot(X,Y1); hold on; plot(X,Y1m1); hold off;
subplot(2,1,2); plot(X,I);

%% Compute SOC (no temperature)
Z0=99.5;
Z=Z0*ones(size(Y1,1),1);
for i=2:length(Z)
    ts= X(i)-X(i-1);
    Z(i:end)=Z(i-1)-ts*100*I(i)/3600/2.5;
    if Z(i:end)<0, Z(i:end)=0; end
end

%% Additional discharges (3 and 4)
mask_chosen2=battery_data.mode==-3;
Voltage = battery_data.voltage_charger(mask_chosen2);
Y3     = Voltage(2:end);
Y3m1   = Voltage(1:end-1);
X3     = battery_data.time(mask_chosen2); X3=X3(2:end);
I3     = battery_data.current_load(mask_chosen2); I3=I3(2:end);

Z3=Z0*ones(size(Y3,1),1);
for i=2:length(Z3)
    ts=X3(i)-X3(i-1);
    Z3(i:end)=Z3(i-1)-ts*100*I3(i)/3600/2.5;
    if Z3(i:end)<0.001, Z3(i:end)=0.001; end
end

mask_chosen3=battery_data.mode==-4;
Voltage = battery_data.voltage_charger(mask_chosen3);
Y4     = Voltage(2:end);
Y4m1   = Voltage(1:end-1);
X4     = battery_data.time(mask_chosen3); X4=X4(2:end);
I4     = battery_data.current_load(mask_chosen3); I4=I4(2:end);

Z4=Z0*ones(size(Y4,1),1);
for i=2:length(Z4)
    ts=X4(i)-X4(i-1);
    Z4(i:end)=Z4(i-1)-ts*100*I4(i)/3600/2.5;
    if Z4(i:end)<0.001, Z4(i:end)=0.001; end
end

%% ---- PARAMETER ESTIMATION: NO TEMPERATURE MODEL ----
% params = [a_ocv, b1, b2, b3, r0, r1, r2, r3, r4]

params0 = [
    0.90      % a
    8.4       % OCV constant
    0.05      % coeff log term
    0.32      % coeff 1/Z
    0.07      % internal R poly
    -0.0017
    0.000043
    -0.00000067
    0.0000000035
];

error_func = @(params) [
    params(1)*Y1m1 + (1-params(1))*( params(2) - params(3)*log(100-Z) - params(4)*(1./Z) ...
     - I .*(params(5)+params(6)*Z+params(7)*Z.^2+params(8)*Z.^3+params(9)*Z.^4 ) ) - Y1;
    params(1)*Y3m1 + (1-params(1))*( params(2) - params(3)*log(100-Z3) - params(4)*(1./Z3) ...
     - I3.*(params(5)+params(6)*Z3+params(7)*Z3.^2+params(8)*Z3.^3+params(9)*Z3.^4 ) ) - Y3;
    params(1)*Y4m1 + (1-params(1))*( params(2) - params(3)*log(100-Z4) - params(4)*(1./Z4) ...
     - I4.*(params(5)+params(6)*Z4+params(7)*Z4.^2+params(8)*Z4.^3+params(9)*Z4.^4 ) ) - Y4;
];

lb = -inf(9,1);
ub =  inf(9,1);

lb(1)=0.0;   ub(1)=0.99;
lb(2)=8.0;   ub(2)=8.6;
lb(5)=0.0;   ub(5)=1.0;

options = optimoptions('lsqnonlin','Display','iter');
[params_opt,resnorm] = lsqnonlin(error_func,params0,lb,ub,options);

params_opt
resnorm

output = [Y1;Y3;Y4] + error_func(params_opt);

%% Plot comparison
figure(3)
plot(X3,Y3,'-r',X3,output(size(Y1,1)+1 : size(Y1,1)+size(Y3,1)),'--b','LineWidth',2)
legend('Measured','Model')
grid on
ylabel('Terminal Voltage (V)')
xlabel('Time (s)')

figure(4)
plot(Z4, params_opt(5)+params_opt(6)*Z4+params_opt(7)*Z4.^2+params_opt(8)*Z4.^3+params_opt(9)*Z4.^4, 'b','LineWidth',2)
grid on
ylabel('Internal Resistance (Ohm)')
xlabel('SOC (%)')

figure(5)
plot(Z4, [ones(size(Z4)) -log(100-Z4) -1./Z4] * params_opt(2:4),'b','LineWidth',2)
grid on
ylabel('OCV (V)')
xlabel('SOC (%)')

