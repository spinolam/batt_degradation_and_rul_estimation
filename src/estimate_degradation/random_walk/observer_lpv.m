function [gammam,zm,Vm, Tm,xm, error, rho1m, rho2m,rint]= observer_lpv(Vtrue, Ik,Ts, Cr, inital_param, params, L, reset)
persistent zk Vk Tk gammak x rho1k rho2k

% --- Reset persistent state for a new cycle ---
if nargin < 8
    reset = false;
end
if reset
    x     = [];
    Tk    = [];
    rho1k = [];
    rho2k = [];
    return;   % nothing else to compute, just clear and exit
end

% --- initial states ----
if isempty(x)
    x    = inital_param(1:3)';
    x(1) = 1;   % Gamma initial equal to 1
end
if isempty(Tk)
    Tk = inital_param(4);
end

% --- map functions -----
gammak = x(1);
zk     = x(2);
Vk     = x(3);

if zk > 99.9; zk = 99.9; end
if zk < 1;    zk = 1;    end

voc  = (params(2) - params(3)*log(100 - zk) - params(4)/zk);
rint = (params(5) + params(6)*zk + params(7)*zk^2 + params(8)*zk^3 + params(9)*zk^4);
eta  = 100/(3600*Cr)*Ts;

if isempty(rho1k)
    rho1k = -Ik;
    rho2k = -rint*Ik;
end

% --- dynamic model -----
rho1 = -Ik;
rho2 = -rint*Ik;

A = [ 1              0  0          ;
      eta*rho1       1  0          ;
      (1-params(1))*rho2  0  params(1) ];
B = [0; 0; (1-params(1))*voc];
C = [0 0 1];

error = (Vtrue - C*x);
x1    = A*x + B*1 + L*error;

% Temperature
Tjk = rint*gammak*Ik^2;
T1  = params(10)*Tk + (1-params(10))*(params(11)*Tjk + inital_param(4));

% ---- sensor model ----
xm     = x;
zm     = zk;
Vm     = Vk;
gammam = gammak;
Tm     = Tk;
rho1m  = rho1k;
rho2m  = rho2k;

% ---- update state ----
x      = x1;
gammak = x1(1);
zk     = x1(2);
Vk     = x1(3);
Tk     = T1;
rho1k  = rho1;
rho2k  = rho2;
