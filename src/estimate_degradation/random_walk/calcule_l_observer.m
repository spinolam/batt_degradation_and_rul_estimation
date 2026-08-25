function  L_k= calcule_l_observer(Ik,rint,L,pho1_min,pho1_max, pho2_min, pho2_max )
pho1= -Ik;
pho2= -rint*Ik;
% 1. Normalizar los parámetros entre 0 y 1
w1 = (pho1 - pho1_min) / (pho1_max - pho1_min);
w2 = (pho2 - pho2_min) / (pho2_max - pho2_min);

% 2. Calcular los pesos de los 4 vértices (Producto tensorial)
mu1 = (1 - w1) * (1 - w2); % Corresponde a A1 (min, min)
mu2 = (1 - w1) * w2;       % Corresponde a A2 (min, max)
mu3 = w1 * (1 - w2);       % Corresponde a A3 (max, min)
mu4 = w1 * w2;             % Corresponde a A4 (max, max)

% 3. Calcular la Ganancia LPV variante en el tiempo

L_k = mu1*L(:,1)  + mu2*L(:,2) + mu3*L(:,3) + mu4*L(:,4);
