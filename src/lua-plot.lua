-- Module to add plotting functionality
-- This module launches the plot server
local modname = ...

local require = require
local math = math
local setmetatable = setmetatable
local type = type
local pairs = pairs
local table = table

local print = print
local getfenv = getfenv
local tostring = tostring

-- Set this to nil to use llthreads to launch plotserver as a thread
local USE_PROCESS = nil

local llthreads
if not USE_PROCESS then
	llthreads = require("llthreads")
end
local socket = require("socket")
local package = package
local collectgarbage = collectgarbage

local M = {} 
package.loaded[modname] = M
if setfenv then
	setfenv(1,M)
else
	_ENV = M
end

_VERSION = "1.15.09.20"

-- Plot objects
local plots = {}	-- To store the plot objects being handled here indexed by the IDs 
					-- returned by the plotserver which point to the actual graphical plots handled by the plotserver
local plotsmeta = {__mode="v"}
setmetatable(plots,plotsmeta)	-- make plots a weak table for values to track which plots are garbage collected in the user script
local createdPlots = {}	-- To store list of plots created in the plotserver. The value is the index which points the GUI plot object in the plot erver
-- NOTE: if plots[ID] == nil but createdPlots has that ID in its list that means 
		-- the plot object is garbage collected and so it must be destroyed by the plotserver
		-- Which is what the garbageCollect function does
local plotObjectMeta = {}

-- Window objects for combining plots in one window
local windows = {}	-- To store the window objects being handled here indexed by IDs
					-- returned by the plotserver which point to the actual graphical windows handled by the plotserver
local windowsmeta = {__mode="v"}
setmetatable(windows,windowsmeta)	-- make windows a weak table for values to track which windows are garbage collected in the user script
local createdWindows = {}	-- To store the list of windows created in the plotserver. The value is the index which points the GUI window object in the plotserver
-- NOTE: if windows[ID] == nil but createdWindows has that ID in its list that means 
		-- the window object is garbage collected and so it must be destroyed by the plotserver
		-- Which is what the garbageCollect function does
local windowObjectMeta = {}		-- Metatable to identify window objects


local t2s = require("lua-plot.tableToString")

-- Launch the plot server
local port = 6348
local plotservercode = [[
	local args = {...}		-- arguments given by parent
	-- Search for PARENT PORT number and store it in parentPort global variable
	for i=1,#args,2 do
		if args[i] == "PARENT PORT" and args[i+1] and type(args[i+1]) == "number" then
			parentPort = math.floor(args[i+1])
		end
	end
	require("subModSearcher")
	require("lua-plot.plotserver")
]]
local server,stat,conn
server = socket.bind("*",port)
if not server then
	-- Try the next 100 ports
	while not server and port<6348+100 do
		port = port + 1
		server = socket.bind("*",port)
	end
	if not server then
		package.loaded[modname] = nil
		return	-- exit module without loading it
	end
end
--print("PLOT: Starting plotserver by passing port number=",port)
local plotserver
if not USE_PROCESS then
	plotserver = llthreads.new(plotservercode, "PARENT PORT", port)
	stat = plotserver:start(true)	-- Start plotserver in a independent non joinable thread
	if not stat then
		-- Could not start the plotserver as a new thread
		package.loaded[modname] = nil
		return	-- exit module without loading it
	end
end

-- Now wait for the connection
if USE_PROCESS then
	--print("PLOT: Waiting for plotserver to connect on port ".. tostring(port))
	server:settimeout(10)
else
	server:settimeout(2)
end
conn = server:accept()

if not conn then
	-- Did not get connection
	package.loaded[modname] = nil
	return
end
conn:settimeout(2)	-- connection object which is maintaining a link to the plotserver

-- Function to check if a plot object is garbage collected then ask plotserver to destroy it as well
local function garbageCollect()
	-- First run a garbage collection cycle
	collectgarbage()
-- NOTE: if plots[ID] == nil but createdPlots has that ID in its list that means 
-- the plot object is garbage collected and so it must be destroyed by the plotserver
-- NOTE: if windows[ID] == nil but createdWindows has that ID in its list that means 
-- the window object is garbage collected and so it must be destroyed by the plotserver

	local i = 1
--	print("PLOT: CreatedPlots:")
--	for k,v in pairs(createdPlots) do
--		print("PLOT: -->",k,v)
--	end
	while i <= #createdPlots do
		local inc = true
		if not plots[createdPlots[i]] then
			-- Ask plot server to destroy the plot
			--print("PLOT: Destroy plot:",createdPlots[i])
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
	i = 1
	-- Now do the same for windows
	while i <= #createdWindows do
		local inc = true
		if not windows[createdWindows[i]] then
			-- Ask plot server to destroy the window
			--print("PLOT: Destroy plot:",createdPlots[i])
			local sendMsg = {"DESTROY WIN",createdWindows[i]}
			if not conn:send(t2s.tableToString(sendMsg).."\n") then
				return nil
			end
			sendMsg = conn:receive("*l")
			if sendMsg then
				sendMsg = t2s.stringToTable(sendMsg)
				if sendMsg and sendMsg[1] == "ACKNOWLEDGE" then
					table.remove(createdWindows,i)	-- Destroyed successfully so remove from the windows list
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
-- Now expose the API for windowing
-- Doing it this way prevents the object API to be overwritten
do
	local windowAPI = {}
	-- Window object functions

	-- ADD PLOT - Add a plot to a slot in a window, 2nd index contains the window index, 3rd index contains the plot index, 
		-- 4th index contains the coordinate table
	function windowAPI.AddPlot(window,plot,coordinate)
		garbageCollect()
		local winNum
		-- Find the window object in windows to get the reference number to send to plotserver
		for k,v in pairs(windows) do
			if v == window then
				winNum = k
				break
			end
		end
		if not winNum then
			return nil, "Could not find the associated window index"
		end
		local plotNum
		-- Find the plot object in plots to get the reference number to send to plotserver
		for k,v in pairs(plots) do
			if v == plot then
				plotNum = k
				break
			end
		end
		if not plotNum then
			return nil, "Could not find the associated plot index"
		end
		if not coordinate or type(coordinate) ~= "table" or not coordinate[1] or not coordinate[2] or type(coordinate[1]) ~= "number" or type(coordinate[2]) ~= "number" then
			coordinate = nil
		end
		local sendMsg = {"ADD PLOT",winNum,plotNum,coordinate}
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
			if sendMsg[2] == "Slot not available." then
				return nil, "Slot not available or already occupied in the window"
			elseif sendMsg[2] == "No Plot present at that index" then
				return nil, "Plotserver lost the plot"
			elseif sendMsg[2] == "No Window present at that index" then
				return nil, "Plotserver lost the Window"
			end
		end
		if sendMsg[1] ~= "ACKNOWLEDGE" then
			return nil, "Plotserver not responding correctly"
		end
		return true			
	end
			
	-- SHOW WINDOW - Display the window on screen, 2nd index is the index of the window object
	function windowAPI.Show(window)
		garbageCollect()
		local winNum
		-- Find the window object in windows to get the reference number to send to plotserver
		for k,v in pairs(windows) do
			if v == window then
				winNum = k
				break
			end
		end
		--print("PLOT: Tell Server to show window number: "..winNum)
		local sendMsg = {"SHOW WINDOW",winNum}
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
			return nil, "Plotserver lost the window"
		end
		if sendMsg[1] ~= "ACKNOWLEDGE" then
			return nil, "Plotserver not responding correctly"
		end	
		return true
	end
			
	-- EMPTY SLOT - Command to empty a slot in the window, 2nd index is the window index, 3rd index is the coordinate table {row,col}
	function windowAPI.ClearSlot(window,coordinate)
		garbageCollect()
		local winNum
		-- Find the window object in windows to get the reference number to send to plotserver
		for k,v in pairs(windows) do
			if v == window then
				winNum = k
				break
			end
		end
		if not winNum then
			return nil, "Could not find the associated window index"
		end
		if not coordinate or type(coordinate) ~= "table" or not coordinate[1] or not coordinate[2] or type(coordinate[1]) ~= "number" or type(coordinate[2]) ~= "number" then
			return nil, "Second argument expected the coordinate of the slot to clear: {row,column}"
		end
		local sendMsg = {"EMPTY SLOT",winNum,coordinate}
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
			if sendMsg[2] == "Slot not present." then
				return nil, "Slot not present in the window"
			elseif sendMsg[2] == "Expecting coordinate vector for slot to empty as the 3rd parameter" then
				return nil, "Coordinate vector not correct"
			elseif sendMsg[2] == "No Window present at that index" then
				return nil, "Plotserver lost the Window"
			end
		end
		if sendMsg[1] ~= "ACKNOWLEDGE" then
			return nil, "Plotserver not responding correctly"
		end
		return true			
	end	

	function windowObjectMeta.__index(t,k)
		garbageCollect()
		return windowAPI[k]
	end

	function windowObjectMeta.__newindex(t,k)
		-- Do nothing so the API is not overwritten
	end
	windowObjectMeta.__metatable = true
end	-- local scope for the windowObjectMeta ends here

-- Plotserver should be running and the connection socket is establed with conn
-- Now expose the API for plotting
do
	local plotAPI = {}
	function plotAPI.AddSeries(plot,xvalues,yvalues,options)
		garbageCollect()
		local plotNum
		-- Find the plot object in plots to get the reference number to send to plotserver
		for k,v in pairs(plots) do
			if v == plot then
				plotNum = k
				break
			end
		end
		if not plotNum then
			return nil, "Could not find the associated plot index"
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
			
	function plotAPI.Show(plot,tbl)
		garbageCollect()
		local plotNum
		-- Find the plot object in plots to get the reference number to send to plotserver
		for k,v in pairs(plots) do
			if v == plot then
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
			
	function plotAPI.Redraw(plot)
		garbageCollect()
		local plotNum
		-- Find the plot object in plots to get the reference number to send to plotserver
		for k,v in pairs(plots) do
			if v == plot then
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
			
	function plotAPI.Attributes(plot,tbl)
		garbageCollect()
		local plotNum
		-- Find the plot object in plots to get the reference number to send to plotserver
		for k,v in pairs(plots) do
			if v==plot then 
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
			
	function plotObjectMeta.__index(t,k)
		garbageCollect()
		return plotAPI[k]
	end

	function plotObjectMeta.__newindex(t,k,v)
		-- Do nothing to prevent the plot object API from being overwritten
	end
	plotObjectMeta.__metatable = true
end	-- Local scope for plotObjectMeta ends here
	
function window(tbl)
	garbageCollect()
	local sendMsg = {"WINDOW",tbl}
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
	local newWin = {}
	setmetatable(newWin,windowObjectMeta)
	-- Put this in plots
	windows[sendMsg[2]] = newWin
	createdWindows[#createdWindows+1] = sendMsg[2]
	return newWin
end

function plot (tbl)
	garbageCollect()
	if not tbl then
		return nil,"Need a the attributes table to create a plot"
	end
	local sendMsg = {"PLOT",tbl}
	local err,msg = conn:send(t2s.tableToString(sendMsg).."\n")
	--print("PLOT: Send plot command:",err,msg)
	if not err then
		return nil, "Cannot communicate with plot server:"..msg
	end
	err,msg = conn:receive("*l")
	--print("PLOT: Message from plot server:",err,msg)
	if not err then
		return nil, "No Acknowledgement from plot server:"..msg
	end
	sendMsg = t2s.stringToTable(err)
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
	garbageCollect()
	print("PLOT: Local List:")
	print("PLOT: Plots:")
	for k,v in pairs(plots) do
		print(k,v)
	end
	print("PLOT: Windows:")
	for k,v in pairs(windows) do
		print(k,v)
	end
	conn:send([[{"LIST PLOTS"}]].."\n")
end

-- Function to return a Bode plot function
-- tbl is the table containing all the parameters
-- .func = single parameter function of the complex frequency s from which the magnitude and phase can be computed
-- .ini = starting frequency of the plot (default = 0.01)
-- .finfreq = ending frequency of the plot (default = 1MHz)
-- .steps = number of steps per decade for the plot (default=50)
function bodePlot(tbl)
	garbageCollect()
	if not tbl or type(tbl) ~= "table" then
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
		--print("PLOT: fin=",fin,fin<=1e6)
	until fin > finfreq
--	local magPlot = plot {TITLE = "Magnitude", GRID="YES", GRIDLINESTYLE = "DOTTED", AXS_XSCALE="LOG10", AXS_XMIN=tbl.ini or 0.01, AXS_YMAX = magmax+20, AXS_YMIN=magmin-20}
--	local phasePlot = plot {TITLE = "Phase", GRID="YES", GRIDLINESTYLE = "DOTTED", AXS_XSCALE="LOG10", AXS_XMIN=tbl.ini or 0.01, AXS_YMAX = phasemax+10, AXS_YMIN = phasemin-10}
	-- AXS_BOUNDS takes xmin,ymin,xmax,ymax
	local magPlot = plot {TITLE = "Magnitude", GRID="YES", GRIDLINESTYLE = "DOTTED", AXS_XSCALE="LOG10", AXS_BOUNDS={tbl.ini or 0.01, magmin-20,finfreq,magmax+20}}
	local phasePlot = plot {TITLE = "Phase", GRID="YES", GRIDLINESTYLE = "DOTTED", AXS_XSCALE="LOG10", AXS_BOUNDS={tbl.ini or 0.01, phasemin-10,finfreq,phasemax+10}}
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
	-- Return the bode plot object
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
				--print("PLOT: fin=",fin,fin<=1e6)
			until fin > finfreq
			bp.mag:AddSeries(mag)
			bp.phase:AddSeries(phase)
			if legend then
				bp.mag:Attributes{DS_LEGEND = legend,AXS_XAUTOMIN="YES", AXS_XAUTOMAX="YES", AXS_YAUTOMIN="YES", AXS_YAUTOMAX="YES"}
				bp.phase:Attributes{DS_LEGEND = legend,AXS_XAUTOMIN="YES", AXS_XAUTOMAX="YES", AXS_YAUTOMIN="YES", AXS_YAUTOMAX="YES"}
			end
		end
	}
end
