function [gammam,zm,Vm, Tm, rint, voc]= battery_twin(Ik,Ts, Cr, inital_param, params, reset)
persistent gammak zk Vk Tk

% --- Reset persistent state for a new cycle ---
if nargin < 6
    reset = false;
end
if reset
    gammak = [];
    zk     = [];
    Vk     = [];
    Tk     = [];
    return;
end

% --- initial states ----
if isempty(gammak); gammak = inital_param(1); end
if isempty(zk);     zk     = inital_param(2); end
if isempty(Vk);     Vk     = inital_param(3); end
if isempty(Tk);     Tk     = inital_param(4); end

% Avoid zero division
if zk > 99.9; zk = 99.9; end
if zk < 1;    zk = 1;    end

% --- map functions -----
voc  = (params(2) - params(3)*log(100 - zk) - params(4)/zk);
rint = (params(5) + params(6)*zk + params(7)*zk^2 + params(8)*zk^3 + params(9)*zk^4);

% --- dynamic model -----
gamma1 = 1*gammak;
z1     = zk - Ts*Ik*100*gammak/(3600*Cr);
Ek     = voc - (rint)*Ik*gammak;
V1     = params(1)*Vk + (1-params(1))*Ek;
Tjk    = rint*gammak*Ik^2;
T1     = params(10)*Tk + (1-params(10))*(params(11)*Tjk + inital_param(4));

% --- sensor model ---
noise  = randn*0;
gammam = gammak;
zm     = zk  + noise;
Vm     = Vk  + noise;
Tm     = Tk;

% --- updating ---
gammak = gamma1;
zk     = z1;
Vk     = V1;
Tk     = T1;
