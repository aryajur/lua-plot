-- Module to add plotting functionality
-- This module launches the plot server
local modname = ...

local plots = {}	-- To store the plot objects indexed by the IDs returned by the plotserver which point to the actual graphical plots handled by the plotserver
local plotsmeta = {__mode="v"}
setmetatable(plots,plotsmeta)	-- make plots a weak table for values to track which plots are garbage collected in the user script
local createdPlots = {}	-- To store list of plots created in the plotserver. The value is the index which points the GUI plot in the plot server
-- NOTE: if plots[ID] == nil but createdPlots has that ID in its list that means the plot object is garbage collected and so it must be destroyed by the plotserver
local plotObjectMeta = {}
local require = require
local math = math
local setmetatable = setmetatable
local type = type
local pairs = pairs
local table = table

local print = print
local getfenv = getfenv

require("LuaMath")
local llthreads = require("llthreads")
local socket = require("socket")
local package = package

local M = {} 
package.loaded[modname] = M
if setfenv then
	setfenv(1,M)
else
	_ENV = M
end

local t2s = require("lua-plot.tableToString")

-- Launch the plot server
local port = 6348
local plotservercode = [[
	local args = {...}		-- arguments given by parent
	for i=1,#args,2 do
		if args[i] == "PARENT PORT" and args[i+1] and type(args[i+1]) == "number" then
			parentPort = args[i+1]
		end
	end
	require("LuaMath")
	require("lua-plot.plotserver")
]]
local server,stat,conn
server = socket.bind("*",port)
if not server then
	-- Try the next 100 ports
	while not server do
		port = port + 1
		server = socket.bind("*",port)
	end
	if not server then
		package.loaded[modname] = nil
		return	-- exit module without loading it
	end
end
--print("Starting plotserver by passing port number=",port)
local plotserver = llthreads.new(plotservercode, "PARENT PORT", port)
stat = plotserver:start(true)	-- Start plotserver in a independent non joinable thread
if not stat then
	-- Could not start the plotserver as a new thread
	package.loaded[modname] = nil
	return	-- exit module without loading it
end

-- Now wait for the connection
server:settimeout(2)
conn = server:accept()

if not conn then
	-- Did not get connection
	package.loaded[modname] = nil
	return
end
conn:settimeout(2)

-- Function to check if a plot object is garbage collected then ask plotserver to destroy it as well
function garbageCollect()
-- NOTE: if plots[ID] == nil but createdPlots has that ID in its list that means the plot object is garbage collected and so it must be destroyed by the plotserver
	local i = 1
--	print("CreatedPlots:")
--	for k,v in pairs(createdPlots) do
--		print("-->",k,v)
--	end
	while i <= #createdPlots do
		local inc = true
		if not plots[createdPlots[i]] then
			-- Ask plot server to destroy the plot
			--print("Destroy plot:",createdPlots[i])
			local sendMsg = {"DESTROY",createdPlots[i]}
			if not conn:send(t2s.tableToString(sendMsg).."\n") then
				return nil
			end
			sendMsg = conn:receive("*l")
			if sendMsg then
				sendMsg = t2s.stringToTable(sendMsg)
				if sendMsg and sendMsg[1] == "ACKNOWLEDGE" then
					table.remove(createdPlots,i)	-- Destroyed successfully so remove from the plots list
					inc = false
				end
			end			
		end
		if inc then
			i = i + 1
		end
	end
end

-- Plotserver should be running and the connection socket is establed with conn
-- Now expose the API for plotting
function plotObjectMeta.__index(t,k)
	garbageCollect()
	if k == "AddSeries" then
		return function (plot,xvalues,yvalues,options)
			garbageCollect()
			local plotNum
			for k,v in pairs(plots) do
				if v == t then
					plotNum = k
					break
				end
			end
			local sendMsg = {"ADD DATA",plotNum,xvalues,yvalues,options}
			if not conn:send(t2s.tableToString(sendMsg).."\n") then
				return nil, "Cannot communicate with plot server"
			end
			sendMsg = conn:receive("*l")
			if not sendMsg then
				return nil, "No Acknowledgement from plot server"
			end
			sendMsg = t2s.stringToTable(sendMsg)
			if not sendMsg then
				return nil, "Plotserver not responding correctly"
			end
			if sendMsg[1] == "ERROR" then
				return nil, "Plotserver lost the plot"
			end
			if sendMsg[1] ~= "ACKNOWLEDGE" then
				return nil, "Plotserver not responding correctly"
			end
			return true
		end
	elseif k == "Show" then
		return function(plot,tbl)
			garbageCollect()
			local plotNum
			for k,v in pairs(plots) do
				if v == t then
					plotNum = k
					break
				end
			end
			local sendMsg = {"SHOW PLOT",plotNum,tbl}
			if not conn:send(t2s.tableToString(sendMsg).."\n") then
				return nil, "Cannot communicate with plot server"
			end
			sendMsg = conn:receive("*l")
			if not sendMsg then
				return nil, "No Acknowledgement from plot server"
			end
			sendMsg = t2s.stringToTable(sendMsg)
			if not sendMsg then
				return nil, "Plotserver not responding correctly"
			end
			if sendMsg[1] == "ERROR" then
				return nil, "Plotserver lost the plot"
			end
			if sendMsg[1] ~= "ACKNOWLEDGE" then
				return nil, "Plotserver not responding correctly"
			end	
			return true
		end
	elseif k == "Redraw" then
		return function(plot)
			garbageCollect()
			local plotNum
			for k,v in pairs(plots) do
				if v == t then
					plotNum = k
					break
				end
			end
			local sendMsg = {"REDRAW",plotNum}
			if not conn:send(t2s.tableToString(sendMsg).."\n") then
				return nil, "Cannot communicate with plot server"
			end
			sendMsg = conn:receive("*l")
			if not sendMsg then
				return nil, "No Acknowledgement from plot server"
			end
			sendMsg = t2s.stringToTable(sendMsg)
			if not sendMsg then
				return nil, "Plotserver not responding correctly"
			end
			if sendMsg[1] == "ERROR" then
				return nil, "Plotserver lost the plot"
			end
			if sendMsg[1] ~= "ACKNOWLEDGE" then
				return nil, "Plotserver not responding correctly"
			end	
			return true
		end
	elseif k=="Attributes" then
		return function(plot,tbl)
			garbageCollect()
			local plotNum
			for k,v in pairs(plots) do
				if v==t then 
					plotNum = k
					break
				end
			end
			local sendMsg = {"SET ATTRIBUTES",plotNum,tbl}
			if not conn:send(t2s.tableToString(sendMsg).."\n") then
				return nil, "Cannot communicate with plot server"
			end
			sendMsg = conn:receive("*l")
			if not sendMsg then
				return nil, "No Acknowledgement from plot server"
			end
			sendMsg = t2s.stringToTable(sendMsg)
			if not sendMsg then
				return nil, "Plotserver not responding correctly"
			end
			if sendMsg[1] == "ERROR" then
				return nil, "Plotserver lost the plot"
			end
			if sendMsg[1] ~= "ACKNOWLEDGE" then
				return nil, "Plotserver not responding correctly"
			end	
			return true		
		end
	end		-- if k == "AddSeries" then
end

function plotObjectMeta.__newindex(t,k,v)

end

function pplot (tbl)
	garbageCollect()
	local sendMsg = {"PLOT",tbl}
	if not conn:send(t2s.tableToString(sendMsg).."\n") then
		return nil, "Cannot communicate with plot server"
	end
	sendMsg = conn:receive("*l")
	if not sendMsg then
		return nil, "No Acknowledgement from plot server"
	end
	sendMsg = t2s.stringToTable(sendMsg)
	if not sendMsg then
		return nil, "Plotserver not responding correctly"
	end
	if sendMsg[1] ~= "ACKNOWLEDGE" then
		return nil, "Plotserver not responding correctly"
	end
	-- Create the plot reference object here
	local newPlot = {}
	setmetatable(newPlot,plotObjectMeta)
	-- Put this in plots
	plots[sendMsg[2]] = newPlot
	createdPlots[#createdPlots+1] = sendMsg[2]
	return newPlot
end

function listPlots()
	print("Local List:")
	for k,v in pairs(plots) do
		print(k,v)
	end
	conn:send([[{"LIST PLOTS"}]].."\n")
end

-- Function to return a Bode plot function
-- tbl is the table containing all the parameters
-- .func = single parameter function of the complex frequency s from which the magnitude and phase can be computed
-- .ini = starting frequency of the plot (default = 0.01)
-- .finfreq = ending frequency of the plot (default = 1MHz)
-- .steps = number of steps per decade for the plot
function bodePlot(tbl)
	garbageCollect()
	if type(tbl) ~= "table" then
		return nil, "Expected table argument"
	end
	require "complex"

	if not tbl.func or not(type(tbl.func) == "function") then
		return nil, "Expected func key to contain a function in the table"
	end

	local ini = tbl.ini or 0.01
	local fin = 10*ini
	local finfreq = tbl.finfreq or 1e6
	local mag = {}
	local phase = {}
	local lg = tbl.func(math.i*ini)
	mag[#mag+1] = {ini,20*math.log(math.abs(lg),10)}
	phase[#phase+1] = {ini,180/math.pi*math.atan2(lg.i,lg.r)}
	local magmax = mag[1][2]
	local magmin = mag[1][2]
	local phasemax = phase[1][2]
	local phasemin = phase[1][2]
	local steps = tbl.steps or 50	-- 50 points per decade
	local function addPoints(func,ini,fin,m,p,mmax,mmin,pmax,pmin)
		-- Loop to calculate all points in the present decade starting from ini
		local lg
		for i=1,steps do
			lg = func(math.i*(ini+i*(fin-ini)/steps))
			m[#m+1] = {ini+i*(fin-ini)/steps,20*math.log(math.abs(lg),10)}
			p[#p+1] = {ini+i*(fin-ini)/steps,180/math.pi*math.atan2(lg.i,lg.r)}
			if m[#m][2]>mmax then
				mmax = m[#mag][2]
			end
			if p[#p][2] > pmax then
				pmax=p[#p][2]
			end
			if m[#m][2]<mmin then
				mmin = m[#m][2]
			end
			if p[#p][2] < pmin then
				pmin=p[#p][2]
			end
			--print(i,mag[#mag][1],mag[#mag][2])
		end	
		return mmax,mmin,pmax,pmin
	end
	repeat
		magmax,magmin,phasemax,phasemin = addPoints(tbl.func,ini,fin,mag,phase,magmax,magmin,phasemax,phasemin)
		ini = fin
		fin = ini*10
		--print("fin=",fin,fin<=1e6)
	until fin > finfreq
--	local magPlot = pplot {TITLE = "Magnitude", GRID="YES", GRIDLINESTYLE = "DOTTED", AXS_XSCALE="LOG10", AXS_XMIN=tbl.ini or 0.01, AXS_YMAX = magmax+20, AXS_YMIN=magmin-20}
--	local phasePlot = pplot {TITLE = "Phase", GRID="YES", GRIDLINESTYLE = "DOTTED", AXS_XSCALE="LOG10", AXS_XMIN=tbl.ini or 0.01, AXS_YMAX = phasemax+10, AXS_YMIN = phasemin-10}
	-- AXS_BOUNDS takes xmin,ymin,xmax,ymax
	local magPlot = pplot {TITLE = "Magnitude", GRID="YES", GRIDLINESTYLE = "DOTTED", AXS_XSCALE="LOG10", AXS_BOUNDS={tbl.ini or 0.01, magmin-20,finfreq,magmax+20}}
	local phasePlot = pplot {TITLE = "Phase", GRID="YES", GRIDLINESTYLE = "DOTTED", AXS_XSCALE="LOG10", AXS_BOUNDS={tbl.ini or 0.01, phasemin-10,finfreq,phasemax+10}}
	magPlot:AddSeries(mag)
	phasePlot:AddSeries(phase)
	if tbl.legend then
		magPlot:Attributes{DS_LEGEND = tbl.legend}
		phasePlot:Attributes{DS_LEGEND = tbl.legend}
	end
	mag = nil
	phase = nil
	lg = nil
	--plotmag:AddSeries({{0,0},{10,10},{20,30},{30,45}})
	--return iup.vbox {plotmag,plotphase}
	return {mag=magPlot,phase=phasePlot,
		addplot = function(bp,func,legend)
			if not func then
				func = tbl.func
			end
			ini = tbl.ini or 0.01
			fin = 10*ini
			mag = {}
			phase = {}
			lg = func(math.i*ini)
			mag[#mag+1] = {ini,20*math.log(math.abs(lg),10)}
			phase[#phase+1] = {ini,180/math.pi*math.atan2(lg.i,lg.r)}
			magmax = mag[1][2]
			magmin = mag[1][2]
			phasemax = phase[1][2]
			phasemin = phase[1][2]
			repeat
				magmax,magmin,phasemax,phasemin = addPoints(func,ini,fin,mag,phase,magmax,magmin,phasemax,phasemin)
				ini = fin
				fin = ini*10
				--print("fin=",fin,fin<=1e6)
			until fin > finfreq
			bp.mag:AddSeries(mag)
			bp.phase:AddSeries(phase)
			if legend then
				bp.mag:Attributes{DS_LEGEND = legend}
				bp.phase:Attributes{DS_LEGEND = legend}
			end
		end
	}
end
