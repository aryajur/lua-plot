-- Simple bar plot test
local plot = require("lua-plot")

-- Create simple positive data
local x = {1, 2, 3, 4, 5}
local y = {10, 20, 15, 25, 18}

print("Creating plot...")
local p = plot.plot({TITLE = "Simple Bar Plot"})

print("Adding series...")
p:AddSeries(x, y, {DS_MODE = "BAR"})

print("Showing plot...")
p:Show()

print("Plot shown. Press Enter to exit...")
io.read()
