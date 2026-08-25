%% Mônica Spinola Felix Oct. 2023
%% Code for project of synthesis of robust LQR observer for estimating gamma
% Model 

% Run this if necessary
cvx_startup
%clear 
format long
%%
Idescargamax=19;
Idescargamin=9;


%L=[-0.270468799102130 0.551733258663858 0.289617027889015];
eta=1*100/(3600*2.5);
Rmin=0.02;
Rmax=0.06;

pho1_min= -Idescargamin;
pho1_max= -Idescargamax;
pho2_min= -Idescargamin*Rmin;
pho2_max= -Idescargamax*Rmax;
Voc_max=8.6;
Voc_min=5.5;
pho3_max= 0*Voc_max/1;
pho3_min= 0*Voc_min/99;

b=1;
a=0.90;
A1 = [b 0 0;
    eta*pho1_min 1 0;
   (1-a)*pho2_min (1-a)*pho3_min a];


A2 = [b 0 0;
    eta*pho1_min 1 0;
   (1-a)*pho2_max (1-a)*pho3_min a];

A3 = [b 0 0;
    eta*pho1_max 1 0;
   (1-a)*pho2_min (1-a)*pho3_min a];


A4 = [b 0 0;
    eta*pho1_max 1 0;
   (1-a)*pho2_max (1-a)*pho3_min a];

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




B=[0 0 1];

%%
%B=[1;0];
 

[n,m]=size(B'); % n states and c controls

%% Writen the previous LMI such that A appears affine (useful for polytopic synthesis)
 cvx_clear
 [n,m]=size(B');
 
Q = diag([1 0 20]);
R =1e2;
 
 C=[Q^(1/2); zeros(m,n)];
 D=[zeros(n,m); R^(1/2)];


 cvx_begin sdp %quiet 
 
    variable P(n,n) symmetric
    variable Y(m,n) % one Y is one robust controller
    variable W(n+m,n+m) 
    
    minimize(trace(W))  

    subject to
       P >= 0;

     
       [W             C*P+D*Y;
        (C*P+D*Y)'       P ] >= 0;


   
       [-P+Q          A1'*P-B'*Y;
         (A1'*P-B'*Y)'     -P ]  <= 0; 
       [-P+Q          A2'*P-B'*Y;
         (A2'*P-B'*Y)'     -P ]  <= 0; 
       [-P+Q          A3'*P-B'*Y;
         (A3'*P-B'*Y)'     -P ]  <= 0; 
       [-P+Q          A4'*P-B'*Y;
         (A4'*P-B'*Y)'     -P ]  <= 0; 
%        [-P+Q          A5'*P-B'*Y;
%          (A5'*P-B'*Y)'     -P ]  <= 0; 
%        [-P+Q          A6'*P-B'*Y;
%          (A6'*P-B'*Y)'     -P ]  <= 0; 
%        [-P+Q          A7'*P-B'*Y;
%          (A7'*P-B'*Y)'     -P ]  <= 0; 
%        [-P+Q          A8'*P-B'*Y;
%          (A8'*P-B'*Y)'     -P ]  <= 0; 



    
cvx_end

L3=Y*inv(P)