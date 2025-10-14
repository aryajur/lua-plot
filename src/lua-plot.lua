-- Module to add plotting functionality
-- This module launches the plot server
local args = {...}

local modname = args[1]

local require = require
local math = math
local setmetatable = setmetatable
local type = type
local pairs = pairs
local table = table
local assert = assert
local print = print
local getfenv = getfenv
local tostring = tostring
local string = string
local pcall = pcall
local loadstring = loadstring
local load = load

local os = os

-- Set this to nil to use Lua Lanes to launch plotserver as a thread
-- Set to true to use process mode (recommended for wxWidgets/gnuplot)
local USE_PROCESS = nil  -- Try Lua Lanes with proper configuration

-- Set USE_GNUPLOT to true to use gnuplot backend instead of MathGL
-- The gnuplot backend provides more plotting capabilities and better extensibility
local USE_GNUPLOT = true	--false  -- Temporarily test with MathGL

local lanes
if not USE_PROCESS then
    local ok, lanes_module
    ok, lanes_module = pcall(require, "lanes")
    if ok then
        -- Configure lanes properly
        lanes = lanes_module.configure()
        print("PLOT: Lua Lanes configured successfully")
    else
        print("PLOT: ERROR - Lua Lanes not found:", lanes_module)
        print("PLOT: Falling back to process mode")
        USE_PROCESS = true
    end
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

_VERSION = "1.21.07.06"

-- To do
--[[
* Plot should use a known canvas so that drawing can be controlled better
* Automatic margins and tick spacing to prevent tick number overlaps

]]

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


local tu = require("tableUtils")

CHUNKED_LIMIT = 500000

-- Launch the plot server
local port = 6348
local plotservercode = [[
	io.write("PLOTSERVER: Lane code starting...\n")
	io.flush()
	local args = {...}		-- arguments given by parent
	io.write("PLOTSERVER: Processing arguments...\n")
	io.flush()
	-- Search for PARENT PORT number and store it in parentPort global variable
	for i=1,#args,2 do
		if args[i] == "PARENT PORT" and args[i+1] and type(args[i+1]) == "number" then
			parentPort = math.floor(args[i+1])
		end
		if args[i] == "CHUNKED_LIMIT" and args[i+1] and type(args[i+1]) == "number" then
			CHUNKED_LIMIT = math.floor(args[i+1])
		end
		if args[i] == "MOD PATH" and type(args[i+1]) == "string" then
			MODPATH = args[i+1]
		end
		if args[i] == "USE_GNUPLOT" and args[i+1] ~= nil then
			USE_GNUPLOT = args[i+1]
		end
	end
	io.write("PLOTSERVER: parentPort=" .. tostring(parentPort) .. ", MODPATH=" .. tostring(MODPATH) .. "\n")
	io.flush()
	if package.path:sub(-1,-1) ~= ";" then
		package.path = package.path..";"
	end
	package.path = package.path..MODPATH:gsub("lua%-plot","?")..";"
	-- Add standard Lua library paths for .lua and .so files
	local home = os.getenv("HOME") or "/home/aryajur"
	package.path = package.path..home.."/Lua/?.lua;"..home.."/Lua/?/init.lua;"
	-- Add gnuplotmod path for wxgnuplot widget
	package.path = package.path.."/mnt/g/Milind/Documents/Workspace/gnuplotmod/src/?.lua;"
	-- Set up package.cpath for C modules
	if package.cpath:sub(-1,-1) ~= ";" then
		package.cpath = package.cpath..";"
	end
	package.cpath = package.cpath..home.."/Lua/?.so;"..home.."/Lua/?/?.so;"
	--print("New Package.path is:")
	--print(package.path)
	--print("New Package.cpath is:")
	--print(package.cpath)
	-- Searcher for nested lua modules
	package.searchers[#package.searchers + 1] = function(mod)
		-- Check if this is a multi hierarchy module
		if mod:find(".",1,true) then
			-- Get the top most name 
			local totErr = ""
			local top = mod:sub(1,mod:find(".",1,true)-1)
			local sep = package.config:match("(.-)%s")
			local delim = package.config:match(".-%s+(.-)%s")
			local subst = mod:gsub("%.",sep)
			-- Now loop through all the lua module paths
			for path in package.path:gmatch("(.-)"..delim) do
				if path:sub(-5,-1) == "?.lua" then
					path = path:sub(1,-6)..subst..".lua"
				end
				path = path:gsub("%?",top)
				--print("Search at..."..path)
				-- try loading this file
				local f,err = loadfile(path)
				if not f then
					totErr = totErr.."\n\tno file '"..path.."'"
				else
					--print("FOUND")
					return f
				end
			end
			return totErr
		end
	end
	-- Load the appropriate plotserver backend
	io.write("PLOTSERVER: Loading plotserver backend (USE_GNUPLOT=" .. tostring(USE_GNUPLOT) .. ")...\n")
	io.flush()
	if USE_GNUPLOT then
		require("lua-plot.plotserver-gnuplot")
	else
		require("lua-plot.plotserver")
	end
	io.write("PLOTSERVER: Plotserver backend loaded successfully\n")
	io.flush()
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
	-- Create lane body as a string to avoid upvalue transfer issues
	local plotserver_code = [[
		return function(port_num, chunk_limit, modpath, use_gnuplot)
			io.write("PLOTSERVER: Lane starting with port=" .. tostring(port_num) .. "\n")
			io.flush()

			-- Set global variables that plotserver expects
			parentPort = port_num
			CHUNKED_LIMIT = chunk_limit
			MODPATH = modpath
			USE_GNUPLOT = use_gnuplot

			-- Setup package paths
			if package.path:sub(-1,-1) ~= ";" then
				package.path = package.path..";"
			end
			package.path = package.path..MODPATH:gsub("lua%-plot","?")..";"

			-- Add standard Lua library paths
			local home = os.getenv("HOME") or "/home/aryajur"
			package.path = package.path..home.."/Lua/?.lua;"..home.."/Lua/?/init.lua;"
			-- Add gnuplotmod path
			package.path = package.path.."/mnt/g/Milind/Documents/Workspace/gnuplotmod/src/?.lua;"

			-- Set up C module paths
			if package.cpath:sub(-1,-1) ~= ";" then
				package.cpath = package.cpath..";"
			end
			package.cpath = package.cpath..home.."/Lua/?.so;"..home.."/Lua/?/?.so;"

			io.write("PLOTSERVER: Package paths configured\n")
			io.flush()

			-- Load the plotserver
			if USE_GNUPLOT then
				io.write("PLOTSERVER: Loading gnuplot plotserver...\n")
				io.flush()
				require("lua-plot.plotserver-gnuplot")
			else
				io.write("PLOTSERVER: Loading MathGL plotserver...\n")
				io.flush()
				require("lua-plot.plotserver")
			end

			io.write("PLOTSERVER: Plotserver loaded\n")
			io.flush()
		end
	]]

	-- Load the lane function from string
	local loadfunc = loadstring or load
	local lane_func = loadfunc(plotserver_code)()

	-- Create and start the lane
	-- Use "*" to load all standard libraries
	print("PLOT: Creating lane generator...")
	local lane_gen = lanes.gen("*", lane_func)
	print("PLOT: Starting lane with port", port)
	plotserver = lane_gen(port, CHUNKED_LIMIT, args[2], USE_GNUPLOT)

	if not plotserver then
		print("PLOT: ERROR - Could not start plotserver lane")
		-- Could not start the plotserver as a new lane
		package.loaded[modname] = nil
		return	-- exit module without loading it
	end
	print("PLOT: Lane started successfully")

	-- Check lane status after a short delay to see if it crashed
	local socket_for_sleep = require("socket")
	socket_for_sleep.sleep(0.1)
	local status = plotserver.status
	print("PLOT: Lane status:", status)
	if status == "error" then
		-- Try to get error details using lanes API
		local ok, err_msg = pcall(function() return plotserver:join(0) end)
		if not ok then
			print("PLOT: Lane error (couldn't retrieve):", err_msg)
		else
			print("PLOT: Lane error:", err_msg)
		end
	end
else
	-- Launch plotserver as a separate process
	local plotserver_path = args[2]:gsub("lua%-plot%.lua$", "lua-plot/plotserver-gnuplot.lua")
	local lua_cmd = "lua"
	-- Build command with environment variables
	local cmd = string.format(
		"parentPort=%d CHUNKED_LIMIT=%d MODPATH='%s' USE_GNUPLOT=%s %s '%s' &",
		port, CHUNKED_LIMIT, args[2], tostring(USE_GNUPLOT), lua_cmd, plotserver_path
	)
	print("PLOT: Launching plotserver process:", cmd)
	local ok = os.execute(cmd)
	if not ok then
		print("PLOT: ERROR - Failed to launch plotserver process")
		package.loaded[modname] = nil
		return
	end
end

-- Now wait for the connection
if USE_PROCESS then
	--print("PLOT: Waiting for plotserver to connect on port ".. tostring(port))
	server:settimeout(10)
else
	server:settimeout(10)
end
print("Waiting for server to connect...")
local conn, err = server:accept()
print("Connection object is ", conn)
if err then
	print("Connection error:", err)
end
if not conn then
	-- Did not get connection
	print("PLOT: ERROR - Plotserver did not connect within timeout")
	package.loaded[modname] = nil
	return
end
conn:settimeout(2)	-- connection object which is maintaining a link to the plotserver

-- Function to check if a plot object is garbage collected then ask plotserver to destroy it as well
local function garbageCollect()
	-- First run a garbage collection cycle
--	print("PLOT GB PRE: Plots:")
--	for k,v in pairs(plots) do
--		print(k,v)
--	end
	collectgarbage()
-- NOTE: if plots[ID] == nil but createdPlots has that ID in its list that means 
-- the plot object is garbage collected and so it must be destroyed by the plotserver
-- NOTE: if windows[ID] == nil but createdWindows has that ID in its list that means 
-- the window object is garbage collected and so it must be destroyed by the plotserver

	local i = 1
--	print("PLOT GB: CreatedPlots:")
--	for k,v in pairs(createdPlots) do
--		print("PLOT GB: -->",k,v,plots[createdPlots[i]])
--	end
	while i <= #createdPlots do
		local inc = true
		if not plots[createdPlots[i]] then
			-- Ask plot server to destroy the plot
			--print("PLOT: Destroy plot:",createdPlots[i])
			local sendMsg = {"DESTROY",createdPlots[i]}
			if not conn:send(tu.t2s(sendMsg).."\n") then
				return nil
			end
			sendMsg = conn:receive("*l")
			if sendMsg then
				sendMsg = tu.s2t(sendMsg)
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
			if not conn:send(tu.t2s(sendMsg).."\n") then
				return nil
			end
			sendMsg = conn:receive("*l")
			if sendMsg then
				sendMsg = tu.s2t(sendMsg)
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
		if not conn:send(tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = conn:receive("*l")
		if not sendMsg then
			return nil, "No Acknowledgement from plot server"
		end
		sendMsg = tu.s2t(sendMsg)
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
		if not conn:send(tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = conn:receive("*l")
		if not sendMsg then
			return nil, "No Acknowledgement from plot server"
		end
		sendMsg = tu.s2t(sendMsg)
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
		if not conn:send(tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = conn:receive("*l")
		if not sendMsg then
			return nil, "No Acknowledgement from plot server"
		end
		sendMsg = tu.s2t(sendMsg)
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
		local function checkACK(dataset)
			sendMsg = conn:receive("*l")
			if not sendMsg then
				return nil, "No Acknowledgement from plot server"
			end
			sendMsg = tu.s2t(sendMsg)
			if not sendMsg then
				return nil, "Plotserver not responding correctly"
			end
			if sendMsg[1] == "ERROR" then
				return nil, "Plotserver lost the plot"
			end
			if sendMsg[1] ~= "ACKNOWLEDGE" then
				return nil, "Plotserver not responding correctly"
			end
			if dataset and sendMsg[2] ~= dataset then
				return nil, "Incorrect data set"
			end
			return true	-- Return the dataset number
		end
		
		--local sendMsg = {"ADD DATA",plotNum,xvalues,yvalues,options}
		local sendMsg = {"ADD DATA",plotNum,options}
		local sendData = {xvalues,yvalues}
		-- If the data is large then it has to be sent in chunks
		local send = tu.t2s(sendData).."\n"
		local sendlen = #send
		--print("LUA-PLOT: Data length=",sendlen)
		if sendlen > CHUNKED_LIMIT then
			--print("LUA-PLOT: Doing chunked transfer in "..CHUNKED_LIMIT.." packet size")
			sendMsg[4] = math.modf(sendlen/CHUNKED_LIMIT + 1)
			if not conn:send(tu.t2s(sendMsg).."\n") then
				return nil, "Cannot communicate with plot server"
			end
			local to = conn:gettimeout()
			conn:settimeout(2)	-- 2 second timeout
--[[			local msg,err = checkACK()
			if not msg then 
				conn:settimeout(to)
				return nil,err 
			end]]
			local chunknum = 1
			local chunkpos = 1
			while chunkpos <= sendlen do
				local lim
				if chunkpos + CHUNKED_LIMIT-1 > sendlen then
					lim = sendlen
				else
					lim = chunkpos+CHUNKED_LIMIT-1
				end
				--print("Size of addseries message: "..#send:sub(chunkpos,lim),chunknum)
				if not conn:send(send:sub(chunkpos,lim)) then
					conn:settimeout(to)
					return nil, "Cannot communicate with plot server"
				end
				local msg,err = checkACK(chunknum)
				if not msg then 
					if err == "Incorrect data set" then
						--print("LUA-PLOT: Incorrect dataset ACK.")
						-- cancel transaction
						conn:send("END"..string.rep(" ",CHUNKED_LIMIT-3))
						checkACK()
					else
						--print("LUA-PLOT: ACK not received")
					end
					conn:settimeout(to)
					return nil,err 
				end
				--print("LUA-PLOT: Received ACK for chunk "..tostring(chunknum))
				chunkpos = lim + 1
				chunknum = chunknum + 1
			end
		else
			--print("LUA-PLOT: Doing one transfer.",tu.t2s(sendMsg))
			if not conn:send(tu.t2s(sendMsg).."\n") then
				conn:settimeout(to)
				return nil, "Cannot communicate with plot server"
			end
--[[			local msg,err = checkACK()
			if not msg then 
				conn:settimeout(to)
				return nil,err 
			end]]
			--print("LUA-PLOT: Send data..",send)
			if not conn:send(send) then
				conn:settimeout(to)
				return nil, "Cannot communicate with plot server"
			end
--[[			local msg,err = checkACK()
			if not msg then 
				conn:settimeout(to)
				return nil,err 
			end]]
		end
		conn:settimeout(to)
		local msg,err = checkACK()
		if not msg then 
			return nil,err 
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
		if not conn:send(tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = conn:receive("*l")
		if not sendMsg then
			return nil, "No Acknowledgement from plot server"
		end
		sendMsg = tu.s2t(sendMsg)
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
		if not conn:send(tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = conn:receive("*l")
		if not sendMsg then
			return nil, "No Acknowledgement from plot server"
		end
		sendMsg = tu.s2t(sendMsg)
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
		if not conn:send(tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = conn:receive("*l")
		if not sendMsg then
			return nil, "No Acknowledgement from plot server"
		end
		sendMsg = tu.s2t(sendMsg)
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
	if not conn:send(tu.t2s(sendMsg).."\n") then
		return nil, "Cannot communicate with plot server"
	end
	sendMsg = conn:receive("*l")
	if not sendMsg then
		return nil, "No Acknowledgement from plot server"
	end
	sendMsg = tu.s2t(sendMsg)
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
	local err,msg = conn:send(tu.t2s(sendMsg).."\n")
	--print("PLOT: Send plot command:",err,msg)
	assert(err,"Cannot communicate with plot server:"..(msg or ""))
	err,msg = conn:receive("*l")
	assert(err,"No Acknowledgement from plot server:"..(msg or ""))
	--print("PLOT: Message from plot server:",err,msg)
	sendMsg = assert(tu.s2t(err),"Plotserver not responding correctly:"..err)
	assert(sendMsg[1] ~= "ERROR", "Plotserver Error: "..sendMsg[2])
	assert(sendMsg[1] == "ACKNOWLEDGE","Plotserver not responding correctly:"..sendMsg[1])
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
-- .ini = starting frequency of the plot in Hz (default = 0.01Hz)
-- .finfreq = ending frequency of the plot Hz (default = 1MHz)
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
	local lg = tbl.func(math.i*2*math.pi*ini)
	mag[#mag+1] = {ini,20*math.log(math.abs(lg),10)}
	if math.abs(mag[#mag][2]) == math.huge then
		mag[#mag][2] = 0
	end	
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
			lg = func(math.i*2*math.pi*(ini+i*(fin-ini)/steps))
			m[#m+1] = {ini+i*(fin-ini)/steps,20*math.log(math.abs(lg),10)}
			p[#p+1] = {ini+i*(fin-ini)/steps,180/math.pi*math.atan2(lg.i,lg.r)}
			if math.abs(m[#m][2]) == math.huge then
				m[#m][2] = mmin
			end
			--print(m[#m][2],lg,lg~=0)
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
			lg = func(math.i*2*math.pi*ini)
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
