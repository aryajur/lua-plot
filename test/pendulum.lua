--
--------------------------------------------------------------------------------
--         File:  simple-pendulum.lua
--
--        Usage:  ./simple-pendulum.lua
--
--  Description:  Solves the problem of the double pendulum using Runge-Kutta 4th order method
--                minth is 7.344e-12 if N = 1e8 and tN = 1.5 (took 114.26s).
--      Options:  ---
-- Requirements:  ---
--         Bugs:  ---
--        Notes:  ---
--       Author:  Brenton Horne (), <brentonhorne77@gmail.com>
-- Organization:  
--      Version:  1.0
--      Created:  16/10/17
--     Revision:  ---
--------------------------------------------------------------------------------
-- Define parameters

local t0        = 0                 -- Initial time
local tN        = 10                -- Finishing time
local theta0    = 0                 -- Angle from positive x axis (theta) at t0
local dtheta0   = 0                 -- Change rate in theta at t0
local N         = 1e6               -- Number of steps
local g         = 9.8               -- Acceleration due to gravity
local l         = 1                 -- Length of pendulum

-- Initiate problem variables
local t         = {}                -- Initialize t array
local theta     = {}                -- Initialize theta array
local dtheta    = {}                -- Initialize dtheta array
t[1]            = t0                -- Initiate t[1] variable
theta[1]        = theta0            -- Initiate theta[1] variable
dtheta[1]       = dtheta0           -- Initiate dtheta[1] variable
h               = (tN - t0) / N     -- define step size
minth           = theta0 + math.pi  -- Define minth at t0

-- Define the d2theta/dt2 = f(g, l, t, theta, dtheta) function
-- Essentially the RHS of the problem
function f(g, l, t, theta, dtheta)
    K = - (g/l) * math.cos(theta)
    return K
end

local k1, l1, k2, l2, k3, l3, k4, l4
-- Loop over time
for i = 1,N do
    -- First approximation
    k1          = h * f(g, l, t[i],       theta[i],            dtheta[i])
    l1          = h * dtheta[i];

    -- Second approximation
    k2          = h * f(g, l, t[i] + h/2, theta[i] + 1/2 * l1, dtheta[i] + 1/2 * k1)
    l2          = h * (dtheta[i] + 1/2 * k1)

    -- Third approximation
    k3          = h * f(g, l, t[i] + h/2, theta[i] + 1/2 * l2, dtheta[i] + 1/2 * k2)
    l3          = h * (dtheta[i] + 1/2 * k2)

    -- Fourth approximation
    k4          = h * f(g, l, t[i] + h,   theta[i] + l3,       dtheta[i] + k3)
    l4          = h * (dtheta[i] + 1/2 * k3)

    -- Updating variables
    t[i+1]      = t[i] + h
    dtheta[i+1] = dtheta[i] + (1 / 6) * (k1 + 2 * k2 + 2 * k3 + k4)
    theta[i+1]  = theta[i]  + (1 / 6) * (l1 + 2 * l2 + 2 * l3 + l4)

    -- Determining pi + theta; at minima it is 0
    diff        = math.abs(theta[i] + math.pi)
 
    -- Checking if diff is smaller than the smallest minth so far and updating it if it is 
    if (diff < minth) then
         minth  = diff
    end
         
end

print(minth)

--Plot theta against t
local nt,ntheta = {},{}
for i = 1,1000000,1 do
	nt[#nt + 1] = t[i] 
	ntheta[#ntheta + 1] = theta[i]
--	nt[#nt + 1] = i
--	ntheta[#ntheta + 1] = 2*i
end

--nt = {1,2,3,4,5}
--ntheta = {10,20,30,4,50}

print(#t,#theta)
lp = require("lua-plot")
p = lp.plot{}
p:AddSeries(nt, ntheta)
p:Show()