-- Plotserver.lua (wxLua + MathGL version)
-- This file is launched by plot module to create a plotting server
-- All plotting requests go to this file once launched using LuaSocket

local wx = require("wx")
local mathgl = require("mathgl")
local tu = require("tableUtils")

-- Copy EfficientMathGL_v2 code inline to avoid external dependency
local MathGLPlot = {}
MathGLPlot.__index = MathGLPlot

function MathGLPlot:new(parent, w, h)
	local self = setmetatable({}, MathGLPlot)

	self.width = w or 600
	self.height = h or 400
	self.parent = parent  -- Store parent for later panel creation

	-- Create graph object ONCE
	self.gr = mathgl.mglGraph()
	self.gr:SetSize(self.width, self.height)
	self.gr:SetQuality(2)

	-- Plot attributes
	self.title = ""
	self.grid = false
	self.gridStyle = ";"
	self.xscale = "LINEAR"
	self.bounds = nil

	-- Data series
	self.series = {}

	-- Auto-ranging
	self.xmin = math.huge
	self.xmax = -math.huge
	self.ymin = math.huge
	self.ymax = -math.huge

	-- Panel will be created later when needed
	self.panel = nil
	self.bitmap = nil
	self.imgBuffer = nil  -- Reusable image buffer

	return self
end

function MathGLPlot:ensurePanel(parent)
	if self.panel then return self.panel end

	-- Create panel with the correct parent
	parent = parent or self.parent
	self.panel = wx.wxPanel(parent, wx.wxID_ANY, wx.wxDefaultPosition, wx.wxSize(self.width, self.height))

	-- Paint event
	self.panel:Connect(wx.wxEVT_PAINT, function(event)
		local dc = wx.wxPaintDC(self.panel)
		if self.bitmap and self.bitmap:IsOk() then
			dc:DrawBitmap(self.bitmap, 0, 0, false)
		end
		dc:delete()
	end)

	return self.panel
end

function MathGLPlot:addSeries(xvalues, yvalues, options)
	-- Detect format: AddSeries({{x,y},...}, options) or AddSeries(xarray, yarray, options)
	local x, y
	if type(xvalues[1]) == "table" then
		-- Combined format {{x1,y1}, {x2,y2}, ...}
		options = yvalues or {}
		x = mathgl.mglData(#xvalues)
		y = mathgl.mglData(#xvalues)
		for i = 1, #xvalues do
			x:SetVal(xvalues[i][1], i-1)
			y:SetVal(xvalues[i][2], i-1)
			if xvalues[i][1] < self.xmin then self.xmin = xvalues[i][1] end
			if xvalues[i][1] > self.xmax then self.xmax = xvalues[i][1] end
			if xvalues[i][2] < self.ymin then self.ymin = xvalues[i][2] end
			if xvalues[i][2] > self.ymax then self.ymax = xvalues[i][2] end
		end
	else
		-- Separate x and y arrays
		options = options or {}
		x = mathgl.mglData(#xvalues)
		y = mathgl.mglData(#yvalues)
		for i = 1, #xvalues do
			if xvalues[i] then
				x:SetVal(xvalues[i], i-1)
				if xvalues[i] < self.xmin then self.xmin = xvalues[i] end
				if xvalues[i] > self.xmax then self.xmax = xvalues[i] end
			end
		end
		for i = 1, #yvalues do
			if yvalues[i] then
				y:SetVal(yvalues[i], i-1)
				if yvalues[i] < self.ymin then self.ymin = yvalues[i] end
				if yvalues[i] > self.ymax then self.ymax = yvalues[i] end
			end
		end
	end

	local colors = {"r", "b", "g", "m", "c", "y", "k", "R", "B", "G"}
	local series = {
		x = x,
		y = y,
		mode = options.DS_MODE or "LINE",
		legend = options.DS_LEGEND or "",
		color = colors[((#self.series) % #colors) + 1]
	}

	table.insert(self.series, series)
	return #self.series
end

function MathGLPlot:setAttributes(tbl)
	-- Handle REMOVE attribute
	if tbl.REMOVE then
		if tbl.REMOVE == "CURRENT" and #self.series > 0 then
			table.remove(self.series, #self.series)
		elseif tbl.REMOVE == "ALL" then
			self.series = {}
			self.xmin = math.huge
			self.xmax = -math.huge
			self.ymin = math.huge
			self.ymax = -math.huge
		end
	end

	if tbl.TITLE then self.title = tbl.TITLE end
	if tbl.GRID then self.grid = (tbl.GRID == "YES") end
	if tbl.GRIDLINESTYLE then
		self.gridStyle = (tbl.GRIDLINESTYLE == "DOTTED") and ";" or "-"
	end
	if tbl.AXS_XSCALE then self.xscale = tbl.AXS_XSCALE end
	if tbl.AXS_BOUNDS then self.bounds = tbl.AXS_BOUNDS end

	-- Handle auto-ranging
	if tbl.AXS_XAUTOMIN == "YES" or tbl.AXS_XAUTOMAX == "YES" or
	   tbl.AXS_YAUTOMIN == "YES" or tbl.AXS_YAUTOMAX == "YES" then
		self.xmin = math.huge
		self.xmax = -math.huge
		self.ymin = math.huge
		self.ymax = -math.huge
		for _, s in ipairs(self.series) do
			for i = 0, s.x:GetNx()-1 do
				local xv = s.x:GetVal(i)
				local yv = s.y:GetVal(i)
				if xv < self.xmin then self.xmin = xv end
				if xv > self.xmax then self.xmax = xv end
				if yv < self.ymin then self.ymin = yv end
				if yv > self.ymax then self.ymax = yv end
			end
		end
	end

	-- Handle explicit axis ranges
	if tbl.AXS_XMIN or tbl.AXS_XMAX or tbl.AXS_YMIN or tbl.AXS_YMAX then
		if not self.bounds then
			self.bounds = {self.xmin, self.ymin, self.xmax, self.ymax}
		end
		if tbl.AXS_XMIN then self.bounds[1] = tbl.AXS_XMIN end
		if tbl.AXS_YMIN then self.bounds[2] = tbl.AXS_YMIN end
		if tbl.AXS_XMAX then self.bounds[3] = tbl.AXS_XMAX end
		if tbl.AXS_YMAX then self.bounds[4] = tbl.AXS_YMAX end
	end

	-- Update legend/mode for last series
	if tbl.DS_LEGEND and #self.series > 0 then
		self.series[#self.series].legend = tbl.DS_LEGEND
	end
	if tbl.DS_MODE and #self.series > 0 then
		self.series[#self.series].mode = tbl.DS_MODE
	end

	return true
end

function MathGLPlot:render()
	self.gr:Clf()

	-- Check if we have any bar plots
	local hasBarPlot = false
	for _, series in ipairs(self.series) do
		if series.mode == "BAR" then
			hasBarPlot = true
			break
		end
	end

	-- Only call DefaultPlotParam for non-bar plots
	if not hasBarPlot then
		self.gr:DefaultPlotParam()
	end

	-- Set ranges
	local xmin, xmax, ymin, ymax
	if self.bounds then
		xmin, ymin, xmax, ymax = self.bounds[1], self.bounds[2], self.bounds[3], self.bounds[4]
	else
		xmin, xmax = self.xmin, self.xmax
		ymin, ymax = self.ymin, self.ymax
		local xpad = (xmax - xmin) * 0.05
		local ypad = (ymax - ymin) * 0.05
		if xpad == 0 then xpad = 0.5 end
		if ypad == 0 then ypad = 0.5 end
		xmin, xmax = xmin - xpad, xmax + xpad

		-- For bar plots with all positive values, keep ymin at 0
		if hasBarPlot and ymin >= 0 then
			print(string.format("PLOTSERVER: Bar plot detected, setting ymin=0 (was %.2f)", ymin))
			ymin = 0
			ymax = ymax + ypad
		else
			ymin, ymax = ymin - ypad, ymax + ypad
		end
	end

	self.gr:SetRanges(xmin, xmax, ymin, ymax)
	print(string.format("PLOTSERVER: SetRanges(%.2f, %.2f, %.2f, %.2f)", xmin, xmax, ymin, ymax))
	-- Set origin to 0 for bar plots
	local yOrigin = hasBarPlot and 0 or ymin
	print(string.format("PLOTSERVER: SetOrigin(0, %.2f, 0), hasBarPlot=%s", yOrigin, tostring(hasBarPlot)))
	self.gr:SetOrigin(0, yOrigin, 0)

	-- Grid and axes
	if self.grid then
		self.gr:Grid("xy", self.gridStyle)
	end

	if self.xscale == "LOG10" then
		self.gr:SetFunc("lg(x)", "")
	end
	self.gr:Axis()

	-- Title
	if self.title ~= "" then
		self.gr:Title(self.title, "", -2)
	end

	-- Draw series
	for _, series in ipairs(self.series) do
		local style = series.color
		if series.mode == "MARK" then
			self.gr:Plot(series.x, series.y, style .. "o")
		elseif series.mode == "BAR" then
			-- DEBUG: Print bar data
			print(string.format("PLOTSERVER: Drawing bars, x size=%d, y size=%d", series.x:GetNx(), series.y:GetNx()))
			for i = 0, math.min(4, series.x:GetNx()-1) do
				print(string.format("  x[%d]=%.2f, y[%d]=%.2f", i, series.x:GetVal(i), i, series.y:GetVal(i)))
			end
			-- For bar plots, use BarChart which starts from zero/baseline
			self.gr:Bars(series.x, series.y, style .. "a")
		else
			self.gr:Plot(series.x, series.y, style .. "-")
		end
		if series.legend ~= "" then
			self.gr:AddLegend(series.legend, style)
		end
	end

	-- Show legend
	for _, s in ipairs(self.series) do
		if s.legend ~= "" then
			self.gr:Legend(1, 1, "#")
			break
		end
	end

	-- DEBUG: Save PNG for bar plots
	if hasBarPlot then
		self.gr:WriteFrame("debug_bar_plot.png")
		print("PLOTSERVER: Saved debug_bar_plot.png")
	end

	-- Get RGB
	local w, h = self.gr:GetWidth(), self.gr:GetHeight()
	local bufferSize = 3*w*h

	-- Reuse buffer if possible to avoid memory allocation failures
	if not self.imgBuffer then
		local ok_str, imgStr = pcall(string.rep, "x", bufferSize)
		if not ok_str then
			return false
		end
		self.imgBuffer = imgStr
	end

	local ok = pcall(function() assert(self.gr:GetRGB(self.imgBuffer, bufferSize)) end)
	if not ok then return false end

	-- Update bitmap
	self.bitmap = wx.wxBitmap(wx.wxImage(w, h, self.imgBuffer))

	-- Refresh panel if it exists
	if self.panel then
		self.panel:Refresh(false)
	end
	return true
end

function MathGLPlot:getPanel(parent)
	return self:ensurePanel(parent)
end

-- Server state
local client
local managedPlots = {}
local plot2Dialog = {}
local managedDialogs = {}
local managedWindows = {}
local exitProg = false

-- Connect to parent
local function connectParent()
	local socket = require("socket")
	local c, msg = socket.connect("localhost", parentPort)
	if not c then return nil end
	c:settimeout(0.01)
	client = c
	return true
end

-- Window object
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

-- Create plot
local function pplot(tbl)
	-- Handle AXS_BOUNDS
	if tbl.AXS_BOUNDS then
		local t = tbl.AXS_BOUNDS
		tbl.AXS_XMIN, tbl.AXS_YMIN = t[1], t[2]
		tbl.AXS_XMAX, tbl.AXS_YMAX = t[3], t[4]
		tbl.AXS_BOUNDS = nil
	end

	-- Disable auto if explicit ranges given
	if tbl.AXS_YMIN then tbl.AXS_YAUTOMIN = "NO" end
	if tbl.AXS_YMAX then tbl.AXS_YAUTOMAX = "NO" end
	if tbl.AXS_XMIN then tbl.AXS_XAUTOMIN = "NO" end
	if tbl.AXS_XMAX then tbl.AXS_XAUTOMAX = "NO" end

	-- Create plot without parent (panel will be created when shown)
	local plot = MathGLPlot:new(nil, 600, 400)
	plot:setAttributes(tbl)

	function plot:Attributes(attr)
		if attr.AXS_BOUNDS then
			local t = attr.AXS_BOUNDS
			attr.AXS_XMIN, attr.AXS_YMIN = t[1], t[2]
			attr.AXS_XMAX, attr.AXS_YMAX = t[3], t[4]
			attr.AXS_BOUNDS = tbl
			attr.AXS_YAUTOMIN, attr.AXS_XAUTOMIN = "NO", "NO"
			attr.AXS_YAUTOMAX, attr.AXS_XAUTOMAX = "NO", "NO"
		else
			if attr.AXS_YMIN then attr.AXS_YAUTOMIN = "NO" end
			if attr.AXS_YMAX then attr.AXS_YAUTOMAX = "NO" end
			if attr.AXS_XMIN then attr.AXS_XAUTOMIN = "NO" end
			if attr.AXS_XMAX then attr.AXS_XAUTOMAX = "NO" end
		end
		self:setAttributes(attr)
		return true
	end

	function plot:Redraw()
		self:render()
	end

	return plot
end

-- Setup timer and message loop
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
		-- Stop timer to prevent reentrancy
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
							managedPlots[k] = nil
							break
						end
					end
					-- Clean up panel if it was created
					if destroyQ[i].panel then
						destroyQ[i].panel:Destroy()
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
					print("PLOTSERVER: Adding data to plot " .. msg[2])
					local data
					local to = client:gettimeout()
					client:settimeout(2)

					if msg[4] then
						-- Chunked transfer
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
						print("PLOTSERVER: Waiting for data...")
						data, err = client:receive("*l")
						if data then
							print("PLOTSERVER: Data received, length=" .. #data)
							data = tu.s2t(data)
							print("PLOTSERVER: Data parsed")
						else
							print("PLOTSERVER: ERROR receiving data:", err)
						end
					end

					client:settimeout(to)

					if data then
						print("PLOTSERVER: Data received, adding series...")
						managedPlots[msg[2]]:addSeries(data[1], data[2], msg[3])
						print("PLOTSERVER: Series added successfully")
						sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
					else
						print("PLOTSERVER: ERROR - Data not received")
						sendMSG([[{"ERROR","Data not received"}]] .. "\n")
					end
				else
					sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
				end

			elseif msg[1] == "SHOW PLOT" then
				if managedPlots[msg[2]] then
					local plot = managedPlots[msg[2]]

					-- Create dialog if not exists
					if not plot2Dialog[plot] then
						print("PLOTSERVER: Creating new dialog for plot " .. msg[2])
						local opts = msg[3] or {}
						local dlg = wx.wxFrame(wx.NULL, wx.wxID_ANY,
							opts.title or "Plot",
							wx.wxDefaultPosition,
							wx.wxSize(plot.width, plot.height))

						print("PLOTSERVER: Dialog created, adding panel...")
						local sizer = wx.wxBoxSizer(wx.wxVERTICAL)
						-- Create panel with dialog as parent
						sizer:Add(plot:getPanel(dlg), 1, wx.wxEXPAND)
						dlg:SetSizer(sizer)
						print("PLOTSERVER: Panel added to dialog")

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

					plot:render()
					-- Use CallAfter to avoid timer reentrancy issues
					plot2Dialog[plot]:CallAfter(function()
						plot2Dialog[plot]:Show(true)
					end)
					sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
				else
					sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
				end

			elseif msg[1] == "REDRAW" then
				if managedPlots[msg[2]] then
					print("PLOTSERVER: Redrawing plot " .. msg[2])
					local ok, err = pcall(function()
						managedPlots[msg[2]]:Redraw()
					end)
					if not ok then
						print("PLOTSERVER: ERROR in Redraw:", err)
						sendMSG([[{"ERROR","Redraw failed"}]] .. "\n")
					else
						print("PLOTSERVER: Redraw completed successfully")
						sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
					end
				else
					sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
				end

			elseif msg[1] == "SET ATTRIBUTES" then
				if managedPlots[msg[2]] then
					print("PLOTSERVER: Setting attributes for plot " .. msg[2])
					if msg[3].REMOVE then
						print("PLOTSERVER: REMOVE=" .. msg[3].REMOVE)
					end
					managedPlots[msg[2]]:Attributes(msg[3])
					sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
				else
					sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
				end

			elseif msg[1] == "DESTROY" then
				if managedPlots[msg[2]] then
					table.insert(destroyQ, managedPlots[msg[2]])
					sendMSG([[{"ACKNOWLEDGE"}]] .. "\n")
				else
					sendMSG([[{"ERROR","No Plot present at that index"}]] .. "\n")
				end

			elseif msg[1] == "LIST PLOTS" then
				print("PLOTSERVER: Managed Plots:")
				for k, v in pairs(managedPlots) do
					print(k, v)
				end
				print("PLOTSERVER: Managed Dialogs:")
				for k, v in pairs(managedDialogs) do
					print(k, v)
				end
				print("PLOTSERVER: Managed Windows:")
				for k, v in pairs(managedWindows) do
					print(k, v)
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
						-- Create panel with slot.panel as parent
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
					managedWindows[msg[2]].frame:Raise()  -- Bring to front
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
		end) -- end of pcall

		if not ok then
			print("PLOTSERVER: ERROR in timer callback:", err)
		end

		-- Restart timer for next tick
		timer:Start(10)
	end)

	timer:Start(10)
	return timer
end

-- Main execution
if not connectParent() then
	print("PLOTSERVER: Could not connect to parent")
	os.exit(1)
end

-- Create wxApp
local app = wx.wxApp()
setupTimer(app)
app:MainLoop()
