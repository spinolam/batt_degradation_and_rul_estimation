%% Mônica Spinola Felix Oct. 2023
%% Code for project of synthesis of robust LQR observer for estimating gamma
% Gain-scheduled LPV variant: synthesizes 4 vertex gains L1..L4 (one per
% polytope corner) instead of a single robust gain, so the observer gain is
% interpolated at runtime via calcule_l_observer.m. This is the PRIMARY
% design for the random-walk pipeline (see random_walk/README.md); the
% single-gain script in src/models/ remains dedicated to the constant-current
% pipeline — the two are tuned for different data regimes (note the different
% Voc/Rint/current ranges below vs. the constant-current script) and are not
% interchangeable.
% Model
% Run this if necessary
cvx_startup
%clear
format long
%%
Idescargamax=2;
Idescargamin=1;
b=1;
%L=[-0.270468799102130 0.551733258663858 0.289617027889015];
eta=Ts*100/(3600*Cr);
Rmin=0.2;
Rmax=1.2;
pho1_min= -Idescargamin;
pho1_max= -Idescargamax;
pho2_min= -Idescargamin*Rmin;
pho2_max= -Idescargamax*Rmax;
Voc_max=4.6;
Voc_min=3.5;
pho3_max= Voc_max/1;
pho3_min= Voc_min/99;
A1 = [b 0 0;
    eta*pho1_min 1 0;
   (1-a)*pho2_min 0 a];
A2 = [b 0 0;
    eta*pho2_min 1 0;
   (1-a)*pho2_max 0 a];
A3 = [b 0 0;
    eta*pho1_max 1 0;
   (1-a)*pho2_min 0 a];
A4 = [b 0 0;
    eta*pho1_max 1 0;
   (1-a)*pho2_max 0 a];
% A5 = [b 0 0;
%     eta*pho1_min 1 0;
%    (1-a)*pho2_min (1-a)*pho3_max a];
% A6 = [b 0 0;
%     eta*pho1_min 1 0;
%    (1-a)*pho2_max (1-a)*pho3_max a];
% A7 = [b 0 0;
%     eta*pho1_max 1 0;
%    (1-a)*pho2_min (1-a)*pho3_max a];
% A8 = [b 0 0;
%     eta*pho1_max 1 0;
%    (1-a)*pho2_max (1-a)*pho3_max a];
C=[0 0 1];
%%
%B=[1;0];

[n,m]=size(C'); % n states and c controls
%% Writen the previous LMI such that A appears affine (useful for polytopic synthesis)
 cvx_clear
 [n,m]=size(C');

Q = diag([1 0 0]);
R =0.1;

 N=[Q^(1/2); zeros(m,n)];
 D=[zeros(n,m); R^(1/2)];
 cvx_begin sdp %quiet

    variable P(n,n) symmetric
    variable Y1(m,n) % one Y is one robust controller
    variable Y2(m,n) % one Y is one robust controller
    variable Y3(m,n) % one Y is one robust controller
    variable Y4(m,n) % one Y is one robust controller
    variable W(n+m,n+m)

    minimize(trace(W))
    subject to
       P >= 1e-6 * eye(n); % Garantizar definida positiva

       [W             N*P+D*Y1;
        (N*P+D*Y1)'       P ] >= 0;
       [W             N*P+D*Y2;
        (N*P+D*Y2)'       P ] >= 0;
       [W             N*P+D*Y3;
        (N*P+D*Y3)'       P ] >= 0;
       [W             N*P+D*Y4;
        (N*P+D*Y4)'       P ] >= 0;

       [-P+Q          A1'*P-C'*Y1;
         (A1'*P-C'*Y1)'     -P ]  <= 0;
       [-P+Q          A2'*P-C'*Y2;
         (A2'*P-C'*Y2)'     -P ]  <= 0;
       [-P+Q          A3'*P-C'*Y3;
         (A3'*P-C'*Y3)'     -P ]  <= 0;
       [-P+Q          A4'*P-C'*Y4;
         (A4'*P-C'*Y4)'     -P ]  <= 0;
%        [-P+Q          A5'*P-B'*Y;
%          (A5'*P-B'*Y)'     -P ]  <= 0;
%        [-P+Q          A6'*P-B'*Y;
%          (A6'*P-B'*Y)'     -P ]  <= 0;
%        [-P+Q          A7'*P-B'*Y;
%          (A7'*P-B'*Y)'     -P ]  <= 0;
%        [-P+Q          A8'*P-B'*Y;
%          (A8'*P-B'*Y)'     -P ]  <= 0;

cvx_end
%L3=Y*inv(P)
L1 = (Y1 * inv(P))'
L2 = (Y2 * inv(P))'
L3 = (Y3 * inv(P))'
L4 = (Y4 * inv(P))'
L = [L1 L2 L3 L4]
