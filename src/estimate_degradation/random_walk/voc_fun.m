function voc = voc_fun(z)
%VOC_FUN Summary of this function goes here
%   Detailed explanation goes here
% NOTE: ported as-is from source project — references undefined `params`/`zk`
% (not this function's own args `z`), so calling it will error. Not called by
% any other ported script; kept for parity, not wired into the pipeline.
voc = params(2) - params(3)*log(100 - zk) - params(4)/zk;
end
