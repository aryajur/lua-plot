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

local package = package
local collectgarbage = collectgarbage

local tu = require("tableUtils")
local lanes = require "lanes".configure()

local M = {} 
package.loaded[modname] = M
if setfenv then
	setfenv(1,M)
else
	_ENV = M
end

_VERSION = "1.19.09.05"

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

local linda= lanes.linda()

local CHUNKED_LIMIT = 50000

local iup = require("iuplua")
require("iupluacontrols")
require("iuplua_plot")
require("iupluacd")

-- Plot creation and management code
function setupPlotManager()
--	local iup = require("iuplua")
	--require("iuplua_pplot")
--	require("iupluacontrols")
--	require("iuplua_plot")
	--print("All required")

	local managedPlots = {}	-- table of plot objects with numeric keys incremented for each new plot. 
							-- The plots may be removed from between if they are garbage collected in 
							-- the parent and closed here without changing the indices of the other plots
	local plot2Dialog = {}	-- Mapping from the plot object to the dialog object it is contained in listed in managedDialogs
	local managedDialogs = {}	-- Table of created dialogs with numeric keys incremented for each new dialog
								-- When a dialog is closed then the key automatically becomes nil so no need to destroy it.
	local managedWindows = {}	-- table of window objects with numeric keys incremented for each new window. 
							-- The windows may be removed from between if they are garbage collected in 
							-- the parent and closed here without changing the indices of the other windows
							
	local function window(tbl)
		local winObj = {}
		winObj.rowBoxes = {}	-- To hold the hboxes for each row
		winObj.colBoxes	= {}	-- To hold the hboxes for each slot
		winObj.slots = {}	-- Table to map which slot contains which plots
		winObj.colBox = iup.vbox{}		-- One vertical addition box to correspond to number of rows desired
		winObj.colBox.homogeneous = "YES"		-- distribute space evenly
		for i = 1,#tbl do
			winObj.slots[i] = {}
			winObj.rowBoxes[i] = iup.hbox{}
			winObj.rowBoxes[i].homogeneous = "YES"		-- distribute space evenly
			winObj.colBoxes[i] = {}
			for j = 1,tbl[i] do
				winObj.colBoxes[i][j] = iup.hbox{}
				winObj.colBoxes[i][j].expand = "YES"
				iup.Append(winObj.rowBoxes[i],winObj.colBoxes[i][j])
			end
			iup.Append(winObj.colBox,winObj.rowBoxes[i])
		end
		winObj.dialog = iup.dialog{winObj.colBox}
		for k,v in pairs(tbl) do
			if type(k) ~= "number" then
				-- This is a dialog attribute
				winObj.dialog[k] = v
			end
		end
		local dlgObject = winObj.dialog
		function dlgObject:close_cb()
			if winObj.DESTROY then
				-- first detach all the plots
				for j = 1,#winObj.slots do
					for k,v in pairs(winObj.slots[j]) do
						iup.Detach(v)
					end
				end
				local dlgIndex
				for k,v in pairs(managedWindows) do
					if v == winObj then
						dlgIndex = k
						break
					end
				end
				--print("PLOTSERVER: Now destroying "..tostring(dlgObject))
				iup.Destroy(dlgObject)
				managedWindows[dlgIndex] = nil	
				--print("PLOTSERVER: destroyed "..tostring(dlgObject))
			else
				iup.Hide(dlgObject)
			end
			return iup.IGNORE
		end
		--[[
		local dlgObject = winObj.dialog
		function dlgObject:close_cb()
			return iup.IGNORE
		end]]
		return winObj
	end

	local function pplot (tbl)
		if tbl.AXS_BOUNDS then
			local t = tbl.AXS_BOUNDS
			tbl.AXS_XMIN = t[1]
			tbl.AXS_YMIN = t[2]
			tbl.AXS_XMAX = t[3]
			tbl.AXS_YMAX = t[4]
			tbl.AXS_BOUNDS = nil
		end

		-- the defaults for these values are too small, at least on my system!
		if not tbl.MARGINLEFT then tbl.MARGINLEFT = 40 end
		if not tbl.MARGINBOTTOM then tbl.MARGINBOTTOM = 45 end
		if not tbl.MARGINTOP then tbl.MARGINTOP = 45 end
		if not tbl.MARGINRIGHT then tbl.MARGINRIGHT = 40 end
		
		-- Setting these 2 parameters allows axis to be shown even is the origin is not visible in the dataset area
		if not tbl.AXS_XCROSSORIGIN then tbl.AXS_XCROSSORIGIN = "NO" end
		if not tbl.AXS_YCROSSORIGIN then tbl.AXS_YCROSSORIGIN = "NO" end

		-- if we explicitly supply ranges, then auto must be switched off for that direction.
		if tbl.AXS_YMIN then tbl.AXS_YAUTOMIN = "NO" end
		if tbl.AXS_YMAX then tbl.AXS_YAUTOMAX = "NO" end
		if tbl.AXS_XMIN then tbl.AXS_XAUTOMIN = "NO" end
		if tbl.AXS_XMAX then tbl.AXS_XAUTOMAX = "NO" end

		local plot = iup.plot(tbl)
		plot.End = iup.PlotEnd
		plot.Add = iup.PlotAdd
		function plot.Begin ()
			return iup.PlotBegin(plot,0)
		end

		function plot:AddSeries(xvalues,yvalues,options)
			local str
			if type(xvalues[1]) == "table" then
				options = yvalues
				if type(xvalues[1][1]) == "string" then
					plot:Begin(1)
					str = true
				else
					plot:Begin()
				end
				for i,v in ipairs(xvalues) do
					if str then
						plot:AddStr(v[1],v[2])
					else
						plot:Add(v[1],v[2])
					end
				end
			else
				if type(xvalues[1]) == "string" then
					plot:Begin(1)
					str = true
				else
					plot:Begin()
				end
				
				for i = 1,#xvalues do
					if str then
						plot:AddStr(xvalues[i],yvalues[i])
					else
						plot:Add(xvalues[i],yvalues[i])
					end
				end
			end
			local ds = plot:End()
			-- set any series-specific plot attributes
			if options then
				-- mode must be set before any other attributes!
				if options.DS_MODE then
					plot.DS_MODE = options.DS_MODE
					options.DS_MODE = nil
				end
				for k,v in pairs(options) do
					plot[k] = v
				end
			end
			return ds
		end
		function plot:Redraw()
			plot.REDRAW='YES'
		end
		return plot
	end

	-- Main function to launch the iup loop
	local function setupTimer()
		-- Setup timer to run housekeeping
		timer = iup.timer{time = 10, run = "NO"}	-- run timer with every 10ms action
		local retry
		local destroyQ = {}
		function timer:action_cb()
			local err,retmsg
	--[[		if DBG then
				print("PLOTSERVER: Stop timer")
				print("PLOTSERVER: DBG: "..tostring(DBG))
			end]]
			timer.run = "NO"
			-- Check if any plots in destroyQ and if they can be destroyed to free up memory
			if #destroyQ > 0 then
				local i = 1
				while i<=#destroyQ do
	--[[				if DBG then
						print("PLOTSERVER: i is"..i)
					end]]
					-- check if the plot is not tied to any window
					local found
					for k,v in pairs(managedWindows) do
						for n = 1,#v.slots do
							for m,j in pairs(v.slots[n]) do
								if j == destroyQ[i] then
									found = true
									break
								end
							end
							if found then
								break
							end
						end
						if found then
							break
						end
					end
					if not plot2Dialog[destroyQ[i]] and not found then
						--print("PLOTSERVER: Destroy Q length="..#destroyQ)
						--print("PLOTSERVER: Destroying object:"..tostring(destroyQ[i]))
						-- destroy the plot data
						for k,v in pairs(managedPlots) do
							if v == destroyQ[i] then
								managedPlots[k] = nil
								break
							end
						end
						--print("PLOTSERVER: Destroying Plot:"..tostring(destroyQ[i]))
						iup.Destroy(destroyQ[i])
						--DBG = destroyQ[i]
						table.remove(destroyQ,i)
						--print("PLOTSERVER: Both destroyed and entry removed from destroyQ. destroyQ length is now="..#destroyQ)
					else
						i = i + 1
					end
				end
			end		-- if #destroyQ > 0 then
			if retry then
				msg,err = linda:send("MAIN",retry)
				if not msg then
					if err == "closed" then
						exitProg = true
						iup.Close()
					end
				else
					-- message sent successfully
					retry = nil
				end
				timer.run = "YES"
				return
			end
	--[[		if DBG then
				print("PLOTSERVER: Get message from parent")
				print("PLOTSERVER: DBG: "..tostring(DBG))
			end]]
			-- Receive messages from Parent process if any
			msg,err = linda:receive(2,"SERVER")
			--[[if DBG and msg then
				print("PLOTSERVER: Message length is:", #msg)
			end]]
			if msg then
				-- convert msg to table
				--print("PLOTSERVER: "..msg)
				msg = tu.s2t(msg)
				if msg then
					if msg[1] == "END" then
						exitProg = true
						iup.Close()
					elseif msg[1] == "PLOT" then
						-- Create a plot and return the plot index
						local i = 1
						while true do
							if not managedPlots[i] then
								break
							end
							i = i + 1
						end
						managedPlots[i] = pplot(msg[2])
						retmsg = [[{"ACKNOWLEDGE",]]..tostring(i).."}\n"
						--print("PLOTSERVER: Received Plot command. Send ACKNOWLEDGE")
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "ADD DATA" then
						--print("PLOTSERVER ADD DATA")
						if managedPlots[msg[2]] then
							-- Send Acknowledgement of command received
							local data,nmsg
	--[=[						retmsg = [[{"ACKNOWLEDGE"}]].."\n"
							nmsg,err = client:send(retmsg)
							if not nmsg then
								if err == "closed" then
									exitProg = true
									client:close()
									iup.Close()
								elseif err == "timeout" then
									retry = retmsg
								end
							end]=]
							-- Add the data to the plot
							-- Checked whether this is a CHUNKED TRANSFER
							if msg[4] then
								-- This is chunked transfer
								local numT = tonumber(msg[4])
								data = {}
								
								for i = 1,numT-1 do
									data[i],err = linda:receive(2,"SERVER")
									if data[i] then
	--[=[									retmsg = [[{"ACKNOWLEDGE"}]].."\n"
										nmsg,err = client:send(retmsg)
										if not nmsg then
											if err == "closed" then
												exitProg = true
												client:close()
												iup.Close()
											elseif err == "timeout" then
												retry = retmsg
											end
										end]=]
									else
										--print("PLOTSERVER: receive error: "..err)
										retmsg = [[{"ERROR","No Chunk Received"}]].."\n"
										nmsg,err = linda:send("MAIN",retmsg)
										if not nmsg then
											if err == "closed" then
												exitProg = true
												iup.Close()
											elseif err == "timeout" then
												retry = retmsg
											end
										end
									end
									--print("PLOTSERVER: CHUNKED TRANSFER number and size and total "..i.." "..#data[i].." "..numT)
								end
								-- Get the last transfer
								data[#data+1],err = linda:receive(2,"SERVER")
								--print("PLOTSERVER: CHUNKED TRANSFER number and size and total "..numT.." "..#data[#data].." "..numT)
								if data[#data] then
									-- convert msg to table
									--print("PLOTSERVER: "..msg)
									data = tu.s2t(table.concat(data))
									if not data then
										retmsg = [[{"ERROR","Message not understood"}]].."\n"
										msg,err = linda:send("MAIN",retmsg)
										if not msg then
											if err == "closed" then
												exitProg = true
												iup.Close()
											elseif err == "timeout" then
												retry = retmsg
											end
										end
									end
								else
									--print("PLOTSERVER: receive error (last): "..err)
									retmsg = [[{"ERROR","No Chunk Received"}]].."\n"
									nmsg,err = linda:send("MAIN",retmsg)
									if not nmsg then
										if err == "closed" then
											exitProg = true
											iup.Close()
										elseif err == "timeout" then
											retry = retmsg
										end
									end
								end
							else
								-- Just one transfer to get data
								data,err = linda:receive(2,"SERVER")
								if data then
									-- convert msg to table
									--print("PLOTSERVER: "..msg)
									data = tu.s2t(data)
									if not data then
										retmsg = [[{"ERROR","Message not understood"}]].."\n"
										msg,err = linda:send("MAIN",retmsg)
										if not msg then
											if err == "closed" then
												exitProg = true
												iup.Close()
											elseif err == "timeout" then
												retry = retmsg
											end
										end
									end
								end
							end
							--print(#data[1],#data[2])
							local ds = managedPlots[msg[2]]:AddSeries(data[1],data[2],msg[3])
							retmsg = [[{"ACKNOWLEDGE",]]..tostring(ds)..[[}]].."\n"
						else
							retmsg = [[{"ERROR","No Plot present at that index"}]].."\n"
						end
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "SHOW PLOT" then
						if managedPlots[msg[2]] then
							if not msg[3] or not type(msg[3]) == "table" then
								msg[3] = {title="Plot "..tostring(msg[2]),size="HALFxHALF"}
							else
								if msg[3].title then
									msg[3].title = "Plot "..tostring(msg[2])..":"..msg[3].title
								else
									msg[3].title = "Plot "..tostring(msg[2])
								end
								if not msg[3].size then
									msg[3].size = "HALFxHALF"
								end
							end
							local dlgExists
							for k,v in pairs(plot2Dialog) do
								if k == managedPlots[msg[2]] then
									dlgExists = v
									break
								end
							end
							if dlgExists then
								-- Set the dialog of the plot in focus
								iup.SetFocus(dlgExists)
							else
								-- Create new Dialog to show the plot in
								msg[3][1] = iup.hbox{managedPlots[msg[2]]}
								managedDialogs[#managedDialogs + 1] = iup.dialog(msg[3])
								managedDialogs[#managedDialogs]:show()
								--plot2Dialog[msg[3][1]] =  managedDialogs[#managedDialogs]
								plot2Dialog[managedPlots[msg[2]]] =  managedDialogs[#managedDialogs]
								local dlg = #managedDialogs
								local dlgObject = managedDialogs[#managedDialogs]
								function dlgObject:close_cb()
									local plot
									for k,v in pairs(plot2Dialog) do
										if v == dlgObject then
											plot = k
											plot2Dialog[k] = nil
										end
									end
									iup.Detach(plot)
									iup.Destroy(managedDialogs[dlg])
									managedDialogs[dlg] = nil
									return iup.IGNORE
								end
							end
							retmsg = [[{"ACKNOWLEDGE"}]].."\n"
						else
							retmsg = [[{"ERROR","No Plot present at that index"}]].."\n"
						end
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "REDRAW" then
						if managedPlots[msg[2]] then
							managedPlots[msg[2]]:Redraw()
							retmsg = [[{"ACKNOWLEDGE"}]].."\n"
						else
							retmsg = [[{"ERROR","No Plot present at that index"}]].."\n"
						end
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "DESTROY" then
						if managedPlots[msg[2]] then
	--						print("PLOTSERVER: plot2dialog plots")
	--						for k,v in pairs(plot2Dialog) do
	--							print(k,v)
	--						end
							--print("DESTROY "..msg[2])
							-- check if the plot is not tied to any window
							local found
							for k,v in pairs(managedWindows) do
								for i = 1,#v.slots do
									for m,j in pairs(v.slots[i]) do
										if j == managedPlots[msg[2]] then
											found = true
											break
										end
									end
									if found then
										break
									end
								end
								if found then
									break
								end
							end
							-- destroy the plot data
							if not plot2Dialog[managedPlots[msg[2]]] and not found then
								-- Remove the plot
								--print("PLOTSERVER: Destroying plot: "..msg[2])
								iup.Destroy(managedPlots[msg[2]])
								managedPlots[msg[2]] = nil
							else
								--print("PLOTSERVER: Adding plot "..msg[2].." to destroyQ")
								destroyQ[#destroyQ + 1] = managedPlots[msg[2]]
							end
							retmsg = [[{"ACKNOWLEDGE"}]].."\n"
						else
							retmsg = [[{"ERROR","No Plot present at that index"}]].."\n"
						end
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "WINDOW" then
						-- Create a window and return the window index
						if not msg[2] or not type(msg[2]) == "table" then
							msg[2] = {title="Window "..tostring(#managedWindows + 1),size="HALFxHALF"}
						else
							if msg[2].title then
								msg[2].title = "Window "..tostring(#managedWindows + 1)..":"..msg[2].title
							else
								msg[2].title = "Window "..tostring(#managedWindows + 1)
							end
							if not msg[2].size then
								msg[2].size = "HALFxHALF"
							end
							if not msg[2][1] then
								msg[2][1] = 1
							end
						end
						managedWindows[#managedWindows + 1] = window(msg[2])
						retmsg = [[{"ACKNOWLEDGE",]]..tostring(#managedWindows).."}\n"
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "ADD PLOT" then
						if managedWindows[msg[2]] then
							if managedPlots[msg[3]] then
								if not msg[4] or type(msg[4]) ~= "table" then
									-- find the next empty slot
									msg[4] = nil
									for i = 1,#managedWindows[msg[2]].colBoxes do
										for j = 1,#managedWindows[msg[2]].colBoxes[i] do
											if not managedWindows[msg[2]].slots[i][j] then
												msg[4] = {i,j}	-- this slot is empty
												break
											end
										end
										if msg[4] then
											break
										end
									end
								end
								-- Check if the slot is available and empty
								if managedWindows[msg[2]].colBoxes[msg[4][1]] and managedWindows[msg[2]].colBoxes[msg[4][1]][msg[4][2]] and 
								  not managedWindows[msg[2]].slots[msg[4][1]][msg[4][2]] then
									-- slot is empty and available
									-- Now add the indicated plot to the appropriate colBox
									iup.Append(managedWindows[msg[2]].colBoxes[msg[4][1]][msg[4][2]],managedPlots[msg[3]])
									managedWindows[msg[2]].slots[msg[4][1]][msg[4][2]] = managedPlots[msg[3]]
									retmsg = [[{"ACKNOWLEDGE"}]].."\n"
								else
									retmsg = [[{"ERROR","Slot not available."}]].."\n"
								end
							else
								retmsg = [[{"ERROR","No Plot present at that index"}]].."\n"
							end		-- Plot index check
						else
							retmsg = [[{"ERROR","No Window present at that index"}]].."\n"
						end		-- window index check
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "EMPTY SLOT" then
						if managedWindows[msg[2]] then
							if msg[3] and type(msg[3]) == "table" and msg[3][1] and type(msg[3][1])=="number" and msg[3][2] and type(msg[3][2]) == "number"  then
								-- Check if the slot is available and empty
								if managedWindows[msg[2]].colBoxes[msg[4][1]] and managedWindows[msg[2]].colBoxes[msg[4][1]][msg[4][2]] then
									-- slot is present now check if there is a plot there
									if managedWindows[msg[2]].slots[msg[4][1]][msg[4][2]] then
										iup.Detach(managedWindows[msg[2]].slots[msg[4][1]][msg[4][2]])
										managedWindows[msg[2]].slots[msg[4][1]][msg[4][2]] = nil
									end
									retmsg = [[{"ACKNOWLEDGE"}]].."\n"
								else
									retmsg = [[{"ERROR","Slot not present."}]].."\n"
								end
							else
								retmsg = [[{"ERROR","Expecting coordinate vector for slot to empty as the 3rd parameter"}]].."\n"
							end		-- Plot index check
						else
							retmsg = [[{"ERROR","No Window present at that index"}]].."\n"
						end		-- window index check
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "SHOW WINDOW" then
						--print("PLOTSERVER: SHOW WINDOW - "..msg[2])
						if managedWindows[msg[2]] then
							--print("PLOTSERVER: FOUND WINDOW - "..tostring(managedWindows[msg[2]]))
							managedWindows[msg[2]].dialog:show()
							retmsg = [[{"ACKNOWLEDGE"}]].."\n"
						else
							retmsg = [[{"ERROR","No window present at that index"}]].."\n"
						end
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "DESTROY WIN" then
						if managedWindows[msg[2]] then
							if managedWindows[msg[2]].dialog.visible == "NO" then
								-- detach all plots first
								for j = 1,#managedWindows[msg[2]].slots do
									for k,v in pairs(managedWindows[msg[2]].slots[j]) do
										iup.Detach(v)
									end
								end
								--print("PLOTSERVER: Destroy window "..tostring(managedWindows[msg[2]].dialog))
								iup.Destroy(managedWindows[msg[2]].dialog)
								managedWindows[msg[2]] = nil					
							else
								managedWindows[msg[2]].DESTROY = true
							end
							retmsg = [[{"ACKNOWLEDGE"}]].."\n"
						else
							retmsg = [[{"ERROR","No window present at that index"}]].."\n"
						end
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "SET ATTRIBUTES" then
						if managedPlots[msg[2]] then
							if not msg[3] or type(msg[3])~="table" then
								retmsg = [[{"ERROR","Expecting table of attributes for third parameter"}]].."\n"
							end
							if msg[3].AXS_BOUNDS then
								local t = msg[3].AXS_BOUNDS
								msg[3].AXS_XMIN = t[1]
								msg[3].AXS_YMIN = t[2]
								msg[3].AXS_XMAX = t[3]
								msg[3].AXS_YMAX = t[4]
								msg[3].AXS_BOUNDS = nil
							end
							-- mode must be set before any other attributes!
							if msg[3].DS_MODE then
								managedPlots[msg[2]].DS_MODE = msg[3].DS_MODE
								msg[3].DS_MODE = nil
							end
							for k,v in pairs(msg[3]) do
								managedPlots[msg[2]][k] = v
							end
							retmsg = [[{"ACKNOWLEDGE"}]].."\n"
						else
							retmsg = [[{"ERROR","No Plot present at that index"}]].."\n"
						end
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					elseif msg[1] == "LIST PLOTS" then
						collectgarbage()
						print("PLOTSERVER: Plotserver list:")
						print("PLOTSERVER: Plots:")
						for k,v in pairs(managedPlots) do
							print(k,v)
						end
						print("PLOTSERVER: Dialogs:")
						for k,v in pairs(managedDialogs) do
							print(k,v)
						end
						print("PLOTSERVER: Windows:")
						for k,v in pairs(managedWindows) do
							print(k,v)
						end
					else
						retmsg = [[{"ERROR","Command not understood"}]].."\n"
						msg,err = linda:send("MAIN",retmsg)
						if not msg then
							if err == "closed" then
								exitProg = true
								iup.Close()
							elseif err == "timeout" then
								retry = retmsg
							end
						end
					end
				else		-- if msg then (If stringToTable returned something)
					retmsg = [[{"ERROR","Message not understood"}]].."\n"
					msg,err = linda:send("MAIN",retmsg)
					if not msg then
						if err == "closed" then
							exitProg = true
							iup.Close()
						elseif err == "timeout" then
							retry = retmsg
						end
					end
				end		-- if msg then (If stringToTable returned something)
			elseif err == "closed" then
				-- Exit this program as well
				exitProg = true
				iup.Close()
			end
	--[[		if DBG then
				print("PLOTSERVER: restart timer")
			end]]
			timer.run = "YES"
	--[[		if DBG then
				print("PLOTSERVER: Exit function")
			end]]
		end		-- function timer:action_cb() ends
		timer.run = "YES"
	end

	setupTimer()
	--print("PLOTSERVER: Timer is setup. Now starting mainloop")
	while not exitProg do
		iup.MainLoop()
	end
end

local plotserver = lanes.gen("*",setupPlotManager)()

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
			if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
				return nil
			end
			sendMsg = linda:receive(2,"MAIN")
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
			if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
				return nil
			end
			sendMsg = linda:receive(2,"MAIN")
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
		if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = linda:receive(2,"MAIN")
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
		if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = linda:receive(2,"MAIN")
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
		if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = linda:receive(2,"MAIN")
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
		local function checkACK()
			sendMsg = linda:receive(2,"MAIN")
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
			return sendMsg[2]	-- Return the dataset number
		end
		
		--local sendMsg = {"ADD DATA",plotNum,xvalues,yvalues,options}
		local sendMsg = {"ADD DATA",plotNum,options}
		local sendData = {xvalues,yvalues}
		-- If the data is large then it has to be sent in chunks
		local send = tu.t2s(sendData).."\n"
		local sendlen = #send
		if sendlen > CHUNKED_LIMIT then
			sendMsg[4] = math.modf(sendlen/CHUNKED_LIMIT + 1)
			if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
				return nil, "Cannot communicate with plot server"
			end
--[[			local msg,err = checkACK()
			if not msg then 
				conn:settimeout(to)
				return nil,err 
			end]]
			
			local chunkpos = 1
			while chunkpos <= sendlen do
				local lim
				if chunkpos + CHUNKED_LIMIT-1 > sendlen then
					lim = sendlen
				else
					lim = chunkpos+CHUNKED_LIMIT-1
				end
				--print("Size of addseries message: "..#send:sub(chunkpos,lim))
				if not linda:send("SERVER",send:sub(chunkpos,lim)) then
					return nil, "Cannot communicate with plot server"
				end
--[[				local msg,err = checkACK()
				if not msg then 
					conn:settimeout(to)
					return nil,err 
				end]]
				
				chunkpos = lim + 1
			end
		else
			if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
				return nil, "Cannot communicate with plot server"
			end
--[[			local msg,err = checkACK()
			if not msg then 
				conn:settimeout(to)
				return nil,err 
			end]]
			
			if not linda:send("SERVER",send) then
				return nil, "Cannot communicate with plot server"
			end
--[[			local msg,err = checkACK()
			if not msg then 
				conn:settimeout(to)
				return nil,err 
			end]]
		end
		local msg,err = checkACK()
		if not msg then 
			return nil,err 
		end
		return msg	-- Return dataset number
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
		if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = linda:receive(2,"MAIN")
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
		if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = linda:receive(2,"MAIN")
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
		if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
			return nil, "Cannot communicate with plot server"
		end
		sendMsg = linda:receive(2,"MAIN")
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
	if not linda:send("SERVER",tu.t2s(sendMsg).."\n") then
		return nil, "Cannot communicate with plot server"
	end
	sendMsg = linda:receive(2,"MAIN")
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
	local err,msg = linda:send("SERVER",tu.t2s(sendMsg).."\n")
	--print("PLOT: Send plot command:",err,msg)
	if not err then
		return nil, "Cannot communicate with plot server:"..msg
	end
	err,msg = linda:receive(2,"MAIN")
	--print("PLOT: Message from plot server:",err,msg)
	if not err then
		return nil, "No Acknowledgement from plot server:"..(msg or "")
	end
	sendMsg = tu.s2t(err)
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
	linda:send("SERVER",[[{"LIST PLOTS"}]].."\n")
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
