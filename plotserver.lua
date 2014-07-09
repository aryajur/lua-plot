-- Plotserver.lua
-- This file is launched by plot module to create a plotting server
-- All plotting requests go to this file once launched using LuaSocket
-- This allows user to have plots simultaneously with the lua interpreter 
-- using the standard lua interpreter
-- Milind Gupta 6/6/2014

-- SERVER SOCKET COMMANDS
-- END	- Shutdown and exit
-- PLOT - Create a plot object, 2nd index contains the table of Attributes for the plot
-- ADD DATA - Add data points to a plot, 2nd index is the plot index, 3rd 4th and 5th can be xvalues, yvalues and options or just 3rd and 4th
			-- index parameters can be table of x and y values {{x1,y1},{x2,y2}...{xn,yn}} and options
-- SHOW PLOT- Display the plot on the screen, 2nd index is the plot index
-- REDRAW - Redraw the indicated plot, 2nd index is the plot index
-- SET ATTRIBUTES - Set the plot attributes, 2nd index is the plot index, 3rd index contains the table of Attributes for the plot
-- DESTROY - Command to mark a plot object for destruction
-- LIST PLOTS - List all plot numbers and objects in memory
-- WINDOW - Create a Window object for multiple plots. 2nd index contains a table with 
		-- list of numbers specifying the number of spaces in each row of the window where plots can be shown and key value pairs 
		-- for the window dialog attributes
-- ADD PLOT - Add a plot to a slot in a window, 2nd index contains the window index, 3rd index contains the plot index, 
			-- 4th index contains the coordinate table
-- SHOW WINDOW - Display the window on screen, 2nd index is the index of the window object
-- DESTROY WIN - Command to mark a window object for destruction, 2nd index is the index of the window object
-- EMPTY SLOT - Command to empty a slot in the window, 2nd index is the window index, 3rd index is the coordinate table {row,col}



-- SOCKET COMMAND TO/FROM PARENT STRUCTURE
-- It is a Lua table with the command/Response on index 1 followed by extra arguments on following indices

-- SERVER RESPONSES
-- ACKNOWLEDGE - Command acknowledged and executed
-- ERROR - Error followed by the error message

socket = require("socket")	-- socket is used to communicate with the main program and detect when to shut down
require("LuaMath")
local iup = require("iuplua")
require("iuplua_pplot")
local t2s = require("lua-plot.tableToString")

local timer
local client			-- client socket object connection to parent process
local managedPlots = {}	-- table of plot objects with numeric keys incremented for each new plot. 
						-- The plots may be removed from between if they are garbage collected in 
						-- the parent and closed here without changing the indices of the other plots
local plot2Dialog = {}	-- Mapping from the plot object to the dialog object it is contained in listed in managedDialogs
local managedDialogs = {}	-- Table of created dialogs with numeric keys incremented for each new dialog
							-- When a dialog is closed then the key automatically becomes nil so no need to destroy it.
local managedWindows = {}	-- table of window objects with numeric keys incremented for each new window. 
						-- The windows may be removed from between if they are garbage collected in 
						-- the parent and closed here without changing the indices of the other windows
local exitProg
local DBG

local function connectParent()
	-- Try opening the TCP server
	local msg
	local retmsg = {}
	--print("Connecting to localhost on port",parentPort)
	client,msg = socket.connect("localhost",parentPort)

	if not client then
		return nil
	end	-- if not client then
	client:settimeout(0.01)
	return true
end

function window(tbl)
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
			print("Now destroying "..tostring(dlgObject))
			iup.Destroy(dlgObject)
			managedWindows[dlgIndex] = nil	
			print("destroyed "..tostring(dlgObject))
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

function pplot (tbl)

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

    local plot = iup.pplot(tbl)
    plot.End = iup.PPlotEnd
    plot.Add = iup.PPlotAdd
    function plot.Begin ()
        return iup.PPlotBegin(plot,0)
    end

    function plot:AddSeries(xvalues,yvalues,options)
        plot:Begin()
        if type(xvalues[1]) == "table" then
            options = yvalues
            for i,v in ipairs(xvalues) do
                plot:Add(v[1],v[2])
            end
        else
            for i = 1,#xvalues do
                plot:Add(xvalues[i],yvalues[i])
            end
        end
        plot:End()
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
    end
    function plot:Redraw()
        plot.REDRAW='YES'
    end
    return plot
end

-- Main function to launch the iup loop
local function setupTimer()
	-- Setup timer to run housekeeping
	timer = iup.timer{time = 10, run = "YES"}	-- run timer with every 10ms action
	local retry
	local destroyQ = {}
	function timer:action_cb()
		local err,retmsg
--[[		if DBG then
			print("Stop timer")
			print("DBG: "..tostring(DBG))
		end]]
		timer.run = "NO"
		-- Check if any plots in destroyQ and if they can be destroyed to free up memory
		if #destroyQ > 0 then
			local i = 1
			while i<=#destroyQ do
--[[				if DBG then
					print("i is"..i)
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
					--print("Destroy Q length="..#destroyQ)
					--print("Destroying object:"..tostring(destroyQ[i]))
					-- destroy the plot data
					for k,v in pairs(managedPlots) do
						if v == destroyQ[i] then
							managedPlots[k] = nil
							break
						end
					end
					--print("Destroying Plot:"..tostring(destroyQ[i]))
					iup.Destroy(destroyQ[i])
					--DBG = destroyQ[i]
					table.remove(destroyQ,i)
					--print("Both destroyed and entry removed from destroyQ. destroyQ length is now="..#destroyQ)
				else
					i = i + 1
				end
			end
		end		-- if #destroyQ > 0 then
		if retry then
			msg,err = client:send(retry)
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
			print("Get message from parent")
			print("DBG: "..tostring(DBG))
		end]]
		-- Receive messages from Parent process if any
		msg,err = client:receive("*l")
		--[[if DBG and msg then
			print("Message is:"..msg)
		end]]
		if msg then
			-- convert msg to table
			--print(msg)
			msg = t2s.stringToTable(msg)
			if msg then
				if msg[1] == "END" then
					exitProg = true
					iup.Close()
				elseif msg[1] == "PLOT" then
					-- Create a plot and return the plot index
					managedPlots[#managedPlots + 1] = pplot(msg[2])
					retmsg = [[{"ACKNOWLEDGE",]]..tostring(#managedPlots).."}\n"
					msg,err = client:send(retmsg)
					if not msg then
						if err == "closed" then
							exitProg = true
							iup.Close()
						elseif err == "timeout" then
							retry = retmsg
						end
					end
				elseif msg[1] == "ADD DATA" then
					if managedPlots[msg[2]] then
						-- Add the data to the plot
						managedPlots[msg[2]]:AddSeries(msg[3],msg[4],msg[5])
						retmsg = [[{"ACKNOWLEDGE"}]].."\n"
					else
						retmsg = [[{"ERROR","No Plot present at that index"}]].."\n"
					end
					msg,err = client:send(retmsg)
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
							msg[3][1] = managedPlots[msg[2]]
							managedDialogs[#managedDialogs + 1] = iup.dialog(msg[3])
							managedDialogs[#managedDialogs]:show()
							plot2Dialog[msg[3][1]] =  managedDialogs[#managedDialogs]
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
					msg,err = client:send(retmsg)
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
					msg,err = client:send(retmsg)
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
							--print("Destroying plot: "..msg[2])
							iup.Destroy(managedPlots[msg[2]])
							managedPlots[msg[2]] = nil
						else
							--print("Adding plot "..msg[2].." to destroyQ")
							destroyQ[#destroyQ + 1] = managedPlots[msg[2]]
						end
						retmsg = [[{"ACKNOWLEDGE"}]].."\n"
					else
						retmsg = [[{"ERROR","No Plot present at that index"}]].."\n"
					end
					msg,err = client:send(retmsg)
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
					msg,err = client:send(retmsg)
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
					msg,err = client:send(retmsg)
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
					msg,err = client:send(retmsg)
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
					msg,err = client:send(retmsg)
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
							print("Destroy window "..tostring(managedWindows[msg[2]].dialog))
							iup.Destroy(managedWindows[msg[2]].dialog)
							managedWindows[msg[2]] = nil					
						else
							managedWindows[msg[2]].DESTROY = true
						end
						retmsg = [[{"ACKNOWLEDGE"}]].."\n"
					else
						retmsg = [[{"ERROR","No window present at that index"}]].."\n"
					end
					msg,err = client:send(retmsg)
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
					msg,err = client:send(retmsg)
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
					print("Plotserver list:")
					print("Plots:")
					for k,v in pairs(managedPlots) do
						print(k,v)
					end
					print("Dialogs:")
					for k,v in pairs(managedDialogs) do
						print(k,v)
					end
					print("Windows:")
					for k,v in pairs(managedWindows) do
						print(k,v)
					end
				else
					retmsg = [[{"ERROR","Command not understood"}]].."\n"
					msg,err = client:send(retmsg)
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
				msg,err = client:send(retmsg)
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
			print("restart timer")
		end]]
		timer.run = "YES"
--[[		if DBG then
			print("Exit function")
		end]]
	end		-- function timer:action_cb() ends
end

--print("Starting plotserver")
--print("Parent Port number=",parentPort)
if parentPort then
	if connectParent() then
		setupTimer()
		--print("Timer is setup. Now starting mainloop")
		while not exitProg do
			iup.MainLoop()
		end
	else
		--print("Connect Parent unsuccessful")
	end
end 	-- if parentPort and port then ends





