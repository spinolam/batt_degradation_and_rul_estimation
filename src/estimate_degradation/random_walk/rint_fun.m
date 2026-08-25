function rint = rint_fun(z, params)
%RINT_FUN Internal resistance (degree-4 polynomial) as a function of SOC.
% Shared by battery_twin.m and observer_lpv.m so the R(SOC) curve only
% needs to be changed in one place.
rint = params(5) + params(6)*z + params(7)*z^2 + params(8)*z^3 + params(9)*z^4;
end
