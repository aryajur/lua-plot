-- Plotserver.lua (wxLua + gnuplot version)
-- This file is launched by plot module to create a plotting server
-- All plotting requests go to this file once launched using LuaSocket

-- Load wx module FIRST as a global to ensure proper initialization
wx = require("wx")

-- Initialize globals from command-line args, then environment vars, then defaults
local args = {...}
if not parentPort then
    parentPort = tonumber(args[1]) or tonumber(os.getenv("parentPort")) or 6348
end
if not CHUNKED_LIMIT then
    CHUNKED_LIMIT = tonumber(args[2]) or tonumber(os.getenv("CHUNKED_LIMIT")) or 500000
end
if not MODPATH then
    MODPATH = args[3] or os.getenv("MODPATH") or ""
end
if USE_GNUPLOT == nil then
    if args[4] ~= nil then
        USE_GNUPLOT = (args[4] == "true" or args[4] == true)
    else
        local env_gnuplot = os.getenv("USE_GNUPLOT")
        USE_GNUPLOT = env_gnuplot ~= "false" and env_gnuplot ~= nil
    end
end

--[[io.write("PLOTSERVER: Starting with parentPort=", tostring(parentPort),
         " CHUNKED_LIMIT=", tostring(CHUNKED_LIMIT),
         " USE_GNUPLOT=", tostring(USE_GNUPLOT), "\n")
io.write("PLOTSERVER: MODPATH=", tostring(MODPATH), "\n")
io.write("PLOTSERVER: package.path=", package.path, "\n")
io.flush()

io.write("PLOTSERVER: Requiring wxgnuplot...\n")
io.flush()]]
local wxgnuplot = require("wxgnuplot")
--[[io.write("PLOTSERVER: wxgnuplot loaded\n")
io.flush()

io.write("PLOTSERVER: Requiring tableUtils...\n")
io.flush()]]
local tu = require("tableUtils")
--[[io.write("PLOTSERVER: tableUtils loaded\n")
io.flush()

io.write("PLOTSERVER: Requiring lua-plot.gnuplot-attribute-mapping...\n")
io.flush()]]
local AttributeMapping = require("lua-plot.gnuplot-attribute-mapping")
--[[io.write("PLOTSERVER: AttributeMapping loaded\n")
io.flush()]]

-- Configuration
-- Use data blocks for small datasets, temp files for large datasets
-- With the new set_datablock() API, data blocks work reliably with luacmd terminal
local DATA_INLINE_THRESHOLD = 1000  -- Use data blocks for < 1000 points, temp files for >= 1000
local TEMP_FILE_PREFIX = os.tmpname():match("(.*/)")  or "/tmp/"
local datablock_counter = 0  -- Counter for generating unique datablock names

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
    self.series = {}  -- Array of {xdata, ydata, options, datafile, datablock_name}

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
    parent = parent or self.parent

    -- If panel already exists with the same parent, reuse it
    if self.panel and self.parent == parent then
        return self.panel
    end

    -- If parent changed or no panel exists, create a new wxgnuplot widget
    --[[io.write(string.format("PLOTSERVER: Creating new wxgnuplot panel (parent changed: %s)\n",
                           self.panel and "yes" or "no"))
    io.flush()]]

    -- Store the new parent
    self.parent = parent

    -- Create new wxgnuplot widget with the correct parent
    -- Use wxDefaultSize to let the sizer control the size (important for multi-graph windows)
    self.wxplot = wxgnuplot.new(parent, wx.wxID_ANY, wx.wxDefaultPosition,
                                wx.wxDefaultSize)
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
        --[[print(string.format("PLOTSERVER: addSeries - combined format, %d points", #xdata))
        if #xdata > 0 then
            print(string.format("PLOTSERVER:   first point: (%g, %g)", xdata[1], ydata[1]))
            print(string.format("PLOTSERVER:   last point: (%g, %g)", xdata[#xdata], ydata[#ydata]))
        end]]
    else
        -- Separate arrays
        options = options or {}
        xdata = xvalues
        ydata = yvalues
        --print(string.format("PLOTSERVER: addSeries - separate arrays, x=%d, y=%d points", #xdata, #ydata))
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
        datafile = nil,
        datablock_name = nil
    }

    -- For small datasets, use data blocks; for large datasets, use temp files
    if #xdata < DATA_INLINE_THRESHOLD then
        -- Generate unique datablock name
        datablock_counter = datablock_counter + 1
        series.datablock_name = string.format("$DATA%d", datablock_counter)
        --[[io.write(string.format("PLOTSERVER: Using data block '%s' for %d points\n",
                               series.datablock_name, #xdata))
        io.flush()]]

        -- Build data string
        local data_lines = {}
        for i = 1, math.min(#xdata, #ydata) do
            table.insert(data_lines, string.format("%.15g %.15g", xdata[i], ydata[i]))
        end
        local data_str = table.concat(data_lines, "\n")

        -- Set the datablock using wxgnuplot API
        local success = wxgnuplot.set_datablock(series.datablock_name, data_str)
        if not success then
            --[[io.write(string.format("PLOTSERVER: WARNING - set_datablock failed, falling back to temp file\n"))
            io.flush()]]
            series.datablock_name = nil
            series.datafile = self:writeDataToTempFile(xdata, ydata)
        --[[else
            io.write(string.format("PLOTSERVER: Data block '%s' set successfully\n", series.datablock_name))
            io.flush()]]
        end
    else
        -- Large dataset: use temp file
        series.datafile = self:writeDataToTempFile(xdata, ydata)
    end

    table.insert(self.series, series)
    return #self.series
end

-- Add an expression series (e.g., "sin(x)", "x**2", etc.)
function GnuplotPlot:addExpression(expression, options)
    -- Validate expression
    if type(expression) ~= "string" or expression == "" then
        return nil, "Expression must be a non-empty string"
    end

    options = options or {}

    local series = {
        is_expression = true,
        expression = expression,
        options = options
        -- No xdata, ydata, datafile, or datablock_name for expressions
    }

    table.insert(self.series, series)
    return #self.series
end

-- Write data to temporary file
function GnuplotPlot:writeDataToTempFile(xdata, ydata)
    -- Use os.tmpname() which returns proper /tmp/lua_* paths
    local tempfile = os.tmpname()
    --print(string.format("PLOTSERVER: Creating temp file: '%s'", tempfile))

    local f = io.open(tempfile, "w")
    if not f then
        --print(string.format("PLOTSERVER: ERROR - Cannot create temp file: '%s'", tempfile))
        return nil
    end

    for i = 1, math.min(#xdata, #ydata) do
        f:write(string.format("%.15g %.15g\n", xdata[i], ydata[i]))
    end
    f:close()

    --print(string.format("PLOTSERVER: Wrote %d points to '%s'", math.min(#xdata, #ydata), tempfile))
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
            -- Merge plot-level DS_MODE/DS_LEGEND into series options if not already set
            local effectiveOptions = {}
            for k, v in pairs(series.options) do
                effectiveOptions[k] = v
            end

            -- Apply plot-level DS_MODE as fallback
            if not effectiveOptions.DS_MODE and self.attributes.DS_MODE then
                effectiveOptions.DS_MODE = self.attributes.DS_MODE
                --[[io.write(string.format("PLOTSERVER: Using plot-level DS_MODE='%s' for series %d\n",
                                       self.attributes.DS_MODE, i))
                io.flush()]]
            end

            -- Apply plot-level DS_LEGEND as fallback
            if not effectiveOptions.DS_LEGEND and self.attributes.DS_LEGEND then
                effectiveOptions.DS_LEGEND = self.attributes.DS_LEGEND
            end

            local seriesOptions = AttributeMapping:processSeriesOptions(effectiveOptions)

            -- Check if this is an expression series or data series
            if series.is_expression then
                -- Expression series: plot the expression directly
                table.insert(plotParts, string.format("%s %s",
                                                     series.expression, seriesOptions))
            else
                -- Data series: use datablock if available, otherwise use temp file
                local data_source
                if series.datablock_name then
                    data_source = series.datablock_name
                    --[[io.write(string.format("PLOTSERVER: Building plot command for series %d, using data block '%s'\n",
                                           i, data_source))]]
                else
                    data_source = string.format("'%s'", series.datafile)
                    --[[io.write(string.format("PLOTSERVER: Building plot command for series %d, using temp file '%s'\n",
                                           i, series.datafile or "NIL"))]]
                end
                --io.flush()

                table.insert(plotParts, string.format("%s using 1:2 %s",
                                                     data_source, seriesOptions))
            end
        end

        local plotCmd = "plot " .. table.concat(plotParts, ", ")
        --[[io.write(string.format("PLOTSERVER: Final plot command: %s\n", plotCmd))
        io.flush()]]
        table.insert(commands, plotCmd)
    end

    self.gnuplot_commands = commands
    return commands
end

-- Queue commands to wxgnuplot (only call this when data changes!)
function GnuplotPlot:queueCommandsToWxgnuplot()
    if not self.wxplot then
        --io.write("PLOTSERVER: ERROR - wxgnuplot widget not initialized\n")
        return false
    end

    if not self.gnuplot_commands then
        --io.write("PLOTSERVER: ERROR - No cached gnuplot commands to queue\n")
        return false
    end

    --[[io.write("PLOTSERVER: gnuplot_commands table:\n")
    for i, cmd in ipairs(self.gnuplot_commands) do
        io.write(string.format("  [%d]: %s\n", i, cmd))
    end]]

    -- Clear previous commands
    self.wxplot:clear()

    -- Add reset command
    self.wxplot:cmd("reset")

    -- Add all cached commands (wxgnuplot will handle terminal size automatically)
    for _, cmd in ipairs(self.gnuplot_commands) do
        self.wxplot:cmd(cmd)
    end

    --io.write(string.format("PLOTSERVER: Queued %d commands to wxgnuplot (including reset)\n", #self.gnuplot_commands + 1))
    return true
end

-- Build commands and queue to wxgnuplot (main entry point)
function GnuplotPlot:render()
    --io.write("PLOTSERVER: render() - building commands...\n")

    -- Build gnuplot command list
    self:buildGnuplotCommands()

    --io.write("PLOTSERVER: render() - queuing commands to wxgnuplot...\n")
    -- Queue commands to wxgnuplot
    self:queueCommandsToWxgnuplot()

    --io.write("PLOTSERVER: render() - calling wxplot:execute()...\n")
    -- Execute ONCE (wxgnuplot will handle resize automatically from here)
    local success, err = self.wxplot:execute()

    if not success then
        --io.write("PLOTSERVER: ERROR - wxgnuplot execute failed: " .. tostring(err) .. "\n")
        return false
    end

    --io.write("PLOTSERVER: render() - execute succeeded!\n")
    return true
end

-- Cleanup temp files
function GnuplotPlot:cleanup()
    --io.write("PLOTSERVER: GnuplotPlot:cleanup() called\n")
    for _, tempfile in ipairs(self.tempfiles) do
        --io.write("PLOTSERVER: Removing temp file: " .. tempfile .. "\n")
        os.remove(tempfile)
    end
    self.tempfiles = {}
    --io.write("PLOTSERVER: cleanup() completed\n")
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
    --[[io.write("PLOTSERVER: connectParent() - Requiring socket...\n")
    io.flush()]]
    local socket = require("socket")
    --[[io.write("PLOTSERVER: connectParent() - Connecting to localhost:", tostring(parentPort), "\n")
    io.flush()]]
    local c, msg = socket.connect("localhost", parentPort)
    if not c then
        --[[io.write("PLOTSERVER: connectParent() - FAILED to connect: ", tostring(msg), "\n")
        io.flush()]]
        return nil
    end
    --[[io.write("PLOTSERVER: connectParent() - Connected successfully!\n")
    io.flush()]]
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
            -- Use 0 padding to match single-plot appearance
            winObj.sizers[i]:Add(panel, 1, wx.wxEXPAND + wx.wxALL, 0)
            winObj.slots[i][j] = {panel = panel, plot = nil}
        end

        -- Use 0 padding to match single-plot appearance
        mainSizer:Add(winObj.sizers[i], 1, wx.wxEXPAND + wx.wxALL, 0)
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
			--[[if msg then
				io.write("PLOTSERVER: Received message: " .. msg .. "\n")
			end]]
			
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

				elseif msg[1] == "ADD EXPRESSION" then
					if managedPlots[msg[2]] then
						-- msg[2] is plot index, msg[3] is expression string, msg[4] is options
						local expression = msg[3]
						local options = msg[4] or {}

						local seriesIndex, err = managedPlots[msg[2]]:addExpression(expression, options)
						if seriesIndex then
							sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
						else
							sendMSG(string.format([[{"ERROR","%s"}]], err or "Failed to add expression") .. "\n")
						end
					else
						sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
					end

				elseif msg[1] == "SHOW PLOT" then
					--io.write("PLOTSERVER: Processing SHOW PLOT for plot " .. tostring(msg[2]) .. "\n")
					if managedPlots[msg[2]] then
						local plot = managedPlots[msg[2]]

						if not plot2Dialog[plot] then
							--io.write("PLOTSERVER: Creating new dialog frame...\n")
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

						--io.write("PLOTSERVER: Calling render()...\n")
						plot:render()
						--io.write("PLOTSERVER: Calling Show() directly...\n")
						plot2Dialog[plot]:Show(true)
						--io.write("PLOTSERVER: Calling Raise() to bring window to front...\n")
						plot2Dialog[plot]:Raise()
						--io.write("PLOTSERVER: Show() and Raise() completed\n")
						--io.write("PLOTSERVER: Sending ACKNOWLEDGE\n")
						sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
					else
						--io.write("PLOTSERVER: ERROR - Plot not found\n")
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
					--io.write("PLOTSERVER: DESTROY request for plot " .. tostring(msg[2]) .. "\n")
					if managedPlots[msg[2]] then
						--io.write("PLOTSERVER: Adding plot to destroy queue\n")
						table.insert(destroyQ, managedPlots[msg[2]])
						sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
					else
						--io.write("PLOTSERVER: ERROR - Plot not found for destruction\n")
						sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
					end

				elseif msg[1] == "LIST PLOTS" then
					--[[io.write("PLOTSERVER: Managed Plots:\n")
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
					end]]

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

--[[io.write("PLOTSERVER: Main execution - calling connectParent()...\n")
io.flush()]]

if not connectParent() then
    --[[io.write("PLOTSERVER: Could not connect to parent\n")
    io.flush()]]
    os.exit(1)
end

--[[io.write("PLOTSERVER: Connected to parent successfully\n")
io.flush()

-- Initialize wxgnuplot (required for set_datablock to work)
io.write("PLOTSERVER: Initializing wxgnuplot...\n")
io.flush()]]
if wxgnuplot.init() then
    --[[io.write("PLOTSERVER: wxgnuplot initialized successfully\n")
    io.flush()]]
else
    --[[io.write("PLOTSERVER: WARNING - wxgnuplot.init() failed\n")
    io.flush()]]
end

--[[io.write("PLOTSERVER: Starting wx app...\n")
io.flush()]]

app = wx.wxApp()  -- Make app global to ensure it stays alive
mainTimer = setupTimer(app)  -- Make mainTimer global too
app:MainLoop()
