-- Simple plot test without dependencies
local plot = require("lua-plot")

-- Create simple data
local xy = {}
for i = -10, 10 do
	xy[#xy+1] = {i, i*i}
end

print("Creating plot...")
local p = plot.plot({})

print("Adding series...")
p:AddSeries(xy, {DS_MODE="MARK"})

print("Showing plot...")
p:Show()

print("Plot shown. Press Enter to exit...")
io.read()
