function voc = voc_fun(z, params)
%VOC_FUN Open-circuit voltage as a function of SOC.
% Shared by battery_twin.m and observer_lpv.m so the OCV curve only needs
% to be changed in one place.
voc = params(2) - params(3)*log(100 - z) - params(4)/z;
end
