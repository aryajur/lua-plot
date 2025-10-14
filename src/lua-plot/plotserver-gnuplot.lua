-- Plotserver.lua (wxLua + gnuplot version)
-- This file is launched by plot module to create a plotting server
-- All plotting requests go to this file once launched using LuaSocket

-- Load wx module FIRST as a global to ensure proper initialization
wx = require("wx")

-- Initialize globals from environment or args (for process mode)
if not parentPort then
    parentPort = tonumber(os.getenv("parentPort")) or (... and select(2, ...)) or 6348
end
if not CHUNKED_LIMIT then
    CHUNKED_LIMIT = tonumber(os.getenv("CHUNKED_LIMIT")) or 50
end
if not MODPATH then
    MODPATH = os.getenv("MODPATH") or ""
end
if USE_GNUPLOT == nil then
    local env_gnuplot = os.getenv("USE_GNUPLOT")
    USE_GNUPLOT = env_gnuplot ~= "false" and env_gnuplot ~= nil
end

local wxgnuplot = require("wxgnuplot")
local tu = require("tableUtils")
local AttributeMapping = require("lua-plot.gnuplot-attribute-mapping")

-- Configuration
-- IMPORTANT: Data blocks do NOT work with luacmd terminal (only with file terminals like png/svg)
-- The luacmd terminal is for capturing drawing commands, not for processing data blocks
-- Therefore, we MUST use temp files for all data
local DATA_INLINE_THRESHOLD = 0  -- Always use temp files (data blocks don't work with luacmd)
local TEMP_FILE_PREFIX = os.tmpname():match("(.*/)")  or "/tmp/"

-- ============================================================================
-- GnuplotPlot Class
-- ============================================================================

local GnuplotPlot = {}
GnuplotPlot.__index = GnuplotPlot

function GnuplotPlot:new(parent, attributes, w, h)
    local self = setmetatable({}, GnuplotPlot)

    self.width = w or 600
    self.height = h or 400
    self.parent = parent

    -- Store attributes
    self.attributes = attributes or {}

    -- Data series
    self.series = {}  -- Array of {xdata, ydata, options, datafile}

    -- Auto-ranging data
    self.xmin = math.huge
    self.xmax = -math.huge
    self.ymin = math.huge
    self.ymax = -math.huge

    -- Gnuplot state
    self.tempfiles = {}  -- Track temp files for cleanup
    self.gnuplot_commands = nil  -- Cached gnuplot commands for re-rendering on resize

    -- wxgnuplot widget (created lazily)
    self.wxplot = nil
    self.panel = nil

    return self
end

function GnuplotPlot:ensurePanel(parent)
    if self.panel then return self.panel end

    parent = parent or self.parent

    -- Use wxgnuplot widget which handles resize automatically
    self.wxplot = wxgnuplot.new(parent, wx.wxID_ANY, wx.wxDefaultPosition,
                                wx.wxSize(self.width, self.height))
    self.panel = self.wxplot:getPanel()

    return self.panel
end

function GnuplotPlot:getPanel(parent)
    return self:ensurePanel(parent)
end

-- Add a data series
function GnuplotPlot:addSeries(xvalues, yvalues, options)
    -- Detect format: single table of {x,y} pairs or separate x,y arrays
    local xdata, ydata

    if type(xvalues[1]) == "table" then
        -- Combined format {{x1,y1}, {x2,y2}, ...}
        options = yvalues or {}
        xdata = {}
        ydata = {}
        for i = 1, #xvalues do
            xdata[i] = xvalues[i][1]
            ydata[i] = xvalues[i][2]
        end
        print(string.format("PLOTSERVER: addSeries - combined format, %d points", #xdata))
        if #xdata > 0 then
            print(string.format("PLOTSERVER:   first point: (%g, %g)", xdata[1], ydata[1]))
            print(string.format("PLOTSERVER:   last point: (%g, %g)", xdata[#xdata], ydata[#ydata]))
        end
    else
        -- Separate arrays
        options = options or {}
        xdata = xvalues
        ydata = yvalues
        print(string.format("PLOTSERVER: addSeries - separate arrays, x=%d, y=%d points", #xdata, #ydata))
    end

    -- Update ranges for auto-ranging
    for i = 1, #xdata do
        if xdata[i] then
            if xdata[i] < self.xmin then self.xmin = xdata[i] end
            if xdata[i] > self.xmax then self.xmax = xdata[i] end
        end
    end
    for i = 1, #ydata do
        if ydata[i] then
            if ydata[i] < self.ymin then self.ymin = ydata[i] end
            if ydata[i] > self.ymax then self.ymax = ydata[i] end
        end
    end

    local series = {
        xdata = xdata,
        ydata = ydata,
        options = options,
        datafile = nil
    }

    -- For large datasets, write to temp file
    if #xdata >= DATA_INLINE_THRESHOLD then
        series.datafile = self:writeDataToTempFile(xdata, ydata)
    end

    table.insert(self.series, series)
    return #self.series
end

-- Write data to temporary file
function GnuplotPlot:writeDataToTempFile(xdata, ydata)
    -- Use os.tmpname() which returns proper /tmp/lua_* paths
    local tempfile = os.tmpname()
    print(string.format("PLOTSERVER: Creating temp file: '%s'", tempfile))

    local f = io.open(tempfile, "w")
    if not f then
        print(string.format("PLOTSERVER: ERROR - Cannot create temp file: '%s'", tempfile))
        return nil
    end

    for i = 1, math.min(#xdata, #ydata) do
        f:write(string.format("%.15g %.15g\n", xdata[i], ydata[i]))
    end
    f:close()

    print(string.format("PLOTSERVER: Wrote %d points to '%s'", math.min(#xdata, #ydata), tempfile))
    table.insert(self.tempfiles, tempfile)
    return tempfile
end

-- Update plot attributes
function GnuplotPlot:setAttributes(attributes)
    -- Merge new attributes
    for k, v in pairs(attributes) do
        self.attributes[k] = v
    end

    -- Handle REMOVE attribute
    if attributes.REMOVE then
        if attributes.REMOVE == "CURRENT" and #self.series > 0 then
            local removed = table.remove(self.series)
            if removed.datafile then
                os.remove(removed.datafile)
            end
        elseif attributes.REMOVE == "ALL" then
            -- Clean up all temp files
            for _, series in ipairs(self.series) do
                if series.datafile then
                    os.remove(series.datafile)
                end
            end
            self.series = {}
            self.xmin = math.huge
            self.xmax = -math.huge
            self.ymin = math.huge
            self.ymax = -math.huge
        end
    end

    -- Re-compute ranges if auto-ranging requested
    if attributes.AXS_XAUTOMIN == "YES" or attributes.AXS_XAUTOMAX == "YES" or
       attributes.AXS_YAUTOMIN == "YES" or attributes.AXS_YAUTOMAX == "YES" then
        self:recomputeRanges()
    end

    return true
end

-- Recompute data ranges
function GnuplotPlot:recomputeRanges()
    self.xmin = math.huge
    self.xmax = -math.huge
    self.ymin = math.huge
    self.ymax = -math.huge

    for _, series in ipairs(self.series) do
        for i = 1, #series.xdata do
            if series.xdata[i] and series.xdata[i] < self.xmin then
                self.xmin = series.xdata[i]
            end
            if series.xdata[i] and series.xdata[i] > self.xmax then
                self.xmax = series.xdata[i]
            end
        end
        for i = 1, #series.ydata do
            if series.ydata[i] and series.ydata[i] < self.ymin then
                self.ymin = series.ydata[i]
            end
            if series.ydata[i] and series.ydata[i] > self.ymax then
                self.ymax = series.ydata[i]
            end
        end
    end
end

-- Build gnuplot command list (cached for re-rendering on resize)
function GnuplotPlot:buildGnuplotCommands()
    local commands = {}

    -- Generate plot-level commands from attributes
    local context = {}
    local attrCommands, ctx = AttributeMapping:processAttributes(self.attributes, context)

    -- Apply auto-ranging if requested
    if ctx.autorange then
        if ctx.autorange.xmin then
            self.attributes.AXS_XMIN = self.xmin
        end
        if ctx.autorange.xmax then
            self.attributes.AXS_XMAX = self.xmax
        end
        if ctx.autorange.ymin then
            self.attributes.AXS_YMIN = self.ymin
        end
        if ctx.autorange.ymax then
            self.attributes.AXS_YMAX = self.ymax
        end
        -- Regenerate commands with computed ranges
        attrCommands, ctx = AttributeMapping:processAttributes(self.attributes, context)
    end

    -- Add setup commands
    for _, cmd in ipairs(attrCommands) do
        table.insert(commands, cmd)
    end

    -- Check if we have bar plots to adjust baseline
    local hasBarPlot = false
    for _, series in ipairs(self.series) do
        if series.options.DS_MODE == "BAR" then
            hasBarPlot = true
            break
        end
    end

    -- For bar plots with positive data, ensure ymin is 0
    if hasBarPlot and self.ymin >= 0 and not self.attributes.AXS_YMIN then
        table.insert(commands, "set yrange [0:*]")
    end

    -- Generate plot command
    if #self.series > 0 then
        local plotParts = {}
        for i, series in ipairs(self.series) do
            local seriesOptions = AttributeMapping:processSeriesOptions(series.options)
            -- All series use temp files (DATA_INLINE_THRESHOLD = 0)
            print(string.format("PLOTSERVER: Building plot command for series %d, datafile='%s'", i, series.datafile or "NIL"))
            table.insert(plotParts, string.format("'%s' using 1:2 %s",
                                                 series.datafile, seriesOptions))
        end

        local plotCmd = "plot " .. table.concat(plotParts, ", ")
        print(string.format("PLOTSERVER: Final plot command: %s", plotCmd))
        table.insert(commands, plotCmd)
    end

    self.gnuplot_commands = commands
    return commands
end

-- Queue commands to wxgnuplot (only call this when data changes!)
function GnuplotPlot:queueCommandsToWxgnuplot()
    if not self.wxplot then
        io.write("PLOTSERVER: ERROR - wxgnuplot widget not initialized\n")
        return false
    end

    if not self.gnuplot_commands then
        io.write("PLOTSERVER: ERROR - No cached gnuplot commands to queue\n")
        return false
    end

    io.write("PLOTSERVER: gnuplot_commands table:\n")
    for i, cmd in ipairs(self.gnuplot_commands) do
        io.write(string.format("  [%d]: %s\n", i, cmd))
    end

    -- Clear previous commands
    self.wxplot:clear()

    -- Add reset command
    self.wxplot:cmd("reset")

    -- Add all cached commands (wxgnuplot will handle terminal size automatically)
    for _, cmd in ipairs(self.gnuplot_commands) do
        self.wxplot:cmd(cmd)
    end

    io.write(string.format("PLOTSERVER: Queued %d commands to wxgnuplot (including reset)\n", #self.gnuplot_commands + 1))
    return true
end

-- Build commands and queue to wxgnuplot (main entry point)
function GnuplotPlot:render()
    io.write("PLOTSERVER: render() - building commands...\n")

    -- Build gnuplot command list
    self:buildGnuplotCommands()

    io.write("PLOTSERVER: render() - queuing commands to wxgnuplot...\n")
    -- Queue commands to wxgnuplot
    self:queueCommandsToWxgnuplot()

    io.write("PLOTSERVER: render() - calling wxplot:execute()...\n")
    -- Execute ONCE (wxgnuplot will handle resize automatically from here)
    local success, err = self.wxplot:execute()

    if not success then
        io.write("PLOTSERVER: ERROR - wxgnuplot execute failed: " .. tostring(err) .. "\n")
        return false
    end

    io.write("PLOTSERVER: render() - execute succeeded!\n")
    return true
end

-- Cleanup temp files
function GnuplotPlot:cleanup()
    io.write("PLOTSERVER: GnuplotPlot:cleanup() called\n")
    for _, tempfile in ipairs(self.tempfiles) do
        io.write("PLOTSERVER: Removing temp file: " .. tempfile .. "\n")
        os.remove(tempfile)
    end
    self.tempfiles = {}
    io.write("PLOTSERVER: cleanup() completed\n")
end

local client
local managedPlots = {}
local plot2Dialog = {}
local managedDialogs = {}
local managedWindows = {}
local exitProg = false

-- ============================================================================
-- Connect to Parent
-- ============================================================================

local function connectParent()
    local socket = require("socket")
    local c, msg = socket.connect("localhost", parentPort)
    if not c then return nil end
    c:settimeout(0.01)
    client = c
    return true
end

-- ============================================================================
-- Window Management
-- ============================================================================

local function window(tbl)
    local winObj = {}
    winObj.slots = {}
    winObj.sizers = {}

    -- Create main frame
    winObj.frame = wx.wxFrame(wx.NULL, wx.wxID_ANY, tbl.title or "Window",
        wx.wxDefaultPosition, wx.wxSize(800, 600))

    -- Create main sizer (vertical box for rows)
    local mainSizer = wx.wxBoxSizer(wx.wxVERTICAL)

    -- Create rows
    for i = 1, #tbl do
        winObj.slots[i] = {}
        winObj.sizers[i] = wx.wxBoxSizer(wx.wxHORIZONTAL)

        -- Create columns in this row
        for j = 1, tbl[i] do
            local panel = wx.wxPanel(winObj.frame, wx.wxID_ANY)
            panel.slotSizer = wx.wxBoxSizer(wx.wxVERTICAL)
            panel:SetSizer(panel.slotSizer)
            winObj.sizers[i]:Add(panel, 1, wx.wxEXPAND + wx.wxALL, 5)
            winObj.slots[i][j] = {panel = panel, plot = nil}
        end

        mainSizer:Add(winObj.sizers[i], 1, wx.wxEXPAND + wx.wxALL, 5)
    end

    winObj.frame:SetSizer(mainSizer)
    winObj.frame:Layout()

    -- Close handler
    winObj.frame:Connect(wx.wxEVT_CLOSE_WINDOW, function(event)
        if winObj.DESTROY then
            winObj.frame:Destroy()
        else
            winObj.frame:Hide()
        end
    end)

    return winObj
end

-- ============================================================================
-- Plot Creation
-- ============================================================================

local function pplot(tbl)
    local plot = GnuplotPlot:new(nil, tbl, 600, 400)
    return plot
end

-- ============================================================================
-- Message Processing
-- ============================================================================

local function setupTimer(app)
    local ID_TIMER = wx.wxNewId()
    local timer = wx.wxTimer(app, ID_TIMER)
    local retry
    local destroyQ = {}

    local function sendMSG(retmsg)
        local msg, err = client:send(retmsg)
        if not msg then
            if err == "closed" then
                exitProg = true
                client:close()
                app:ExitMainLoop()
            elseif err == "timeout" then
                retry = retmsg
                return nil
            end
        end
        return true
    end

    app:Connect(ID_TIMER, wx.wxEVT_TIMER, function(event)
		--io.write("Timer fired!\n")
        timer:Stop()

        local ok, err = pcall(function()

			-- Handle destroy queue
			if #destroyQ > 0 then
				local i = 1
				while i <= #destroyQ do
					local found = false
					for k, v in pairs(managedWindows) do
						for n = 1, #v.slots do
							for m, j in pairs(v.slots[n]) do
								if j.plot == destroyQ[i] then
									found = true
									break
								end
							end
							if found then break end
						end
						if found then break end
					end

					if not plot2Dialog[destroyQ[i]] and not found then
						for k, v in pairs(managedPlots) do
							if v == destroyQ[i] then
								v:cleanup()
								managedPlots[k] = nil
								break
							end
						end
						table.remove(destroyQ, i)
					else
						i = i + 1
					end
				end
			end

			-- Retry send if needed
			if retry then
				if sendMSG(retry) then
					retry = nil
				end
				return
			end

			-- Receive message
			local msg, err = client:receive("*l")
			if msg then
				io.write("PLOTSERVER: Received message: " .. msg .. "\n")
			end
			
			if err == "closed" then
                exitProg = true
                client:close()
                app:ExitMainLoop()
			end
			if msg then
				msg = tu.s2t(msg)
				if not msg then return end

				local retmsg

				if msg[1] == "END" then
					exitProg = true
					client:close()
					wx.wxGetApp():ExitMainLoop()

				elseif msg[1] == "PLOT" then
					local i = 1
					while managedPlots[i] do i = i + 1 end
					managedPlots[i] = pplot(msg[2])
					sendMSG([[{"ACKNOWLEDGE",]] .. tostring(i) .. "}\n")

				elseif msg[1] == "ADD DATA" then
					if managedPlots[msg[2]] then
						local data
						local to = client:gettimeout()
						client:settimeout(2)

						-- Handle chunked transfer (same as original)
						if msg[4] then
							data = {}
							for i = 1, msg[4]-1 do
								data[i], err = client:receive(CHUNKED_LIMIT)
								if not data[i] then
									sendMSG([[{"ERROR","No Chunk Received"}]] .. "\n")
								else
									sendMSG([[{"ACKNOWLEDGE",]] .. tostring(i) .. [[}]] .. "\n")
									if data[i]:gsub(" ", "") == "END" then
										break
									end
								end
							end
							data[#data+1] = client:receive("*l")
							if data[#data] then
								sendMSG([[{"ACKNOWLEDGE",]] .. tostring(msg[4]) .. [[}]] .. "\n")
								data = tu.s2t(table.concat(data))
							end
						else
							data, err = client:receive("*l")
							if data then
								data = tu.s2t(data)
							end
						end

						client:settimeout(to)

						if data then
							managedPlots[msg[2]]:addSeries(data[1], data[2], msg[3])
							sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
						else
							sendMSG([[{"ERROR","Data not received"}]] .. "\n")
						end
					else
						sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
					end

				elseif msg[1] == "SHOW PLOT" then
					io.write("PLOTSERVER: Processing SHOW PLOT for plot " .. tostring(msg[2]) .. "\n")
					if managedPlots[msg[2]] then
						local plot = managedPlots[msg[2]]

						if not plot2Dialog[plot] then
							io.write("PLOTSERVER: Creating new dialog frame...\n")
							local opts = msg[3] or {}
							local dlg = wx.wxFrame(wx.NULL, wx.wxID_ANY,
								opts.title or "Plot",
								wx.wxDefaultPosition,
								wx.wxSize(plot.width + 20, plot.height + 40))

							local sizer = wx.wxBoxSizer(wx.wxVERTICAL)
							sizer:Add(plot:getPanel(dlg), 1, wx.wxEXPAND + wx.wxALL, 0)
							dlg:SetSizer(sizer)
							dlg:Layout()

							dlg:Connect(wx.wxEVT_CLOSE_WINDOW, function(event)
								plot2Dialog[plot] = nil
								for k, v in pairs(managedDialogs) do
									if v == dlg then
										managedDialogs[k] = nil
										break
									end
								end
								dlg:Destroy()
							end)

							local i = 1
							while managedDialogs[i] do i = i + 1 end
							managedDialogs[i] = dlg
							plot2Dialog[plot] = dlg
						end

						io.write("PLOTSERVER: Calling render()...\n")
						plot:render()
						io.write("PLOTSERVER: Calling Show() directly...\n")
						plot2Dialog[plot]:Show(true)
						io.write("PLOTSERVER: Calling Raise() to bring window to front...\n")
						plot2Dialog[plot]:Raise()
						io.write("PLOTSERVER: Show() and Raise() completed\n")
						io.write("PLOTSERVER: Sending ACKNOWLEDGE\n")
						sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
					else
						io.write("PLOTSERVER: ERROR - Plot not found\n")
						sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
					end

				elseif msg[1] == "REDRAW" then
					if managedPlots[msg[2]] then
						managedPlots[msg[2]]:render()
						sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
					else
						sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
					end

				elseif msg[1] == "SET ATTRIBUTES" then
					if managedPlots[msg[2]] then
						managedPlots[msg[2]]:setAttributes(msg[3])
						sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
					else
						sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
					end

				elseif msg[1] == "DESTROY" then
					io.write("PLOTSERVER: DESTROY request for plot " .. tostring(msg[2]) .. "\n")
					if managedPlots[msg[2]] then
						io.write("PLOTSERVER: Adding plot to destroy queue\n")
						table.insert(destroyQ, managedPlots[msg[2]])
						sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
					else
						io.write("PLOTSERVER: ERROR - Plot not found for destruction\n")
						sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
					end

				elseif msg[1] == "LIST PLOTS" then
					io.write("PLOTSERVER: Managed Plots:\n")
					for k, v in pairs(managedPlots) do
						io.write("  " .. tostring(k) .. " = " .. tostring(v) .. "\n")
					end
					io.write("PLOTSERVER: Managed Dialogs:\n")
					for k, v in pairs(managedDialogs) do
						io.write("  " .. tostring(k) .. " = " .. tostring(v) .. "\n")
					end
					io.write("PLOTSERVER: Managed Windows:\n")
					for k, v in pairs(managedWindows) do
						io.write("  " .. tostring(k) .. " = " .. tostring(v) .. "\n")
					end

				elseif msg[1] == "WINDOW" then
					local i = 1
					while managedWindows[i] do i = i + 1 end
					managedWindows[i] = window(msg[2])
					sendMSG([[{"ACKNOWLEDGE",]] .. tostring(i) .. "}\n")

				elseif msg[1] == "ADD PLOT" then
					if managedWindows[msg[2]] and managedPlots[msg[3]] then
						local win = managedWindows[msg[2]]
						local plot = managedPlots[msg[3]]
						local coord = msg[4]

						if win.slots[coord[1]] and win.slots[coord[1]][coord[2]] then
							local slot = win.slots[coord[1]][coord[2]]
							if slot.plot then
								slot.panel.slotSizer:Detach(slot.plot:getPanel(slot.panel))
							end
							slot.plot = plot
							slot.panel.slotSizer:Add(plot:getPanel(slot.panel), 1, wx.wxEXPAND)
							plot:render()
							slot.panel:Layout()
							sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
						else
							sendMSG([[{"ERROR","Slot not available."}]] .. "\n")
						end
					else
						sendMSG([[{"ERROR","Window or Plot not found"}]] .. "\n")
					end

				elseif msg[1] == "SHOW WINDOW" then
					if managedWindows[msg[2]] then
						managedWindows[msg[2]].frame:Show(true)
						managedWindows[msg[2]].frame:Raise()
						sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
					else
						sendMSG([[{"ERROR","No Window present at that index"}]] .. "\n")
					end

				elseif msg[1] == "DESTROY WIN" then
					if managedWindows[msg[2]] then
						managedWindows[msg[2]].DESTROY = true
						managedWindows[msg[2]].frame:Close()
						managedWindows[msg[2]] = nil
						sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
					else
						sendMSG([[{"ERROR","No Window present at that index"}]] .. "\n")
					end

				elseif msg[1] == "EMPTY SLOT" then
					if managedWindows[msg[2]] then
						local win = managedWindows[msg[2]]
						local coord = msg[3]
						if win.slots[coord[1]] and win.slots[coord[1]][coord[2]] then
							local slot = win.slots[coord[1]][coord[2]]
							if slot.plot then
								slot.panel.slotSizer:Detach(slot.plot:getPanel())
								slot.plot = nil
								slot.panel:Layout()
							end
							sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
						else
							sendMSG([[{"ERROR","Slot not present."}]] .. "\n")
						end
					else
						sendMSG([[{"ERROR","No Window present at that index"}]] .. "\n")
					end
				end
			end
        end)

        if not ok then
            io.write("PLOTSERVER: ERROR in timer callback: " .. tostring(err) .. "\n")
        end
		--print("TIMER RUNNING")
		timer:Start(10)
    end)

    timer:Start(10)
    return timer
end

-- ============================================================================
-- Main Execution
-- ============================================================================

if not connectParent() then
    print("PLOTSERVER: Could not connect to parent")
    os.exit(1)
end

app = wx.wxApp()  -- Make app global to ensure it stays alive
mainTimer = setupTimer(app)  -- Make mainTimer global too
app:MainLoop()
