-- Minimal test for multi-graph window functionality
local plot = require("lua-plot")

print("Creating first plot (magnitude)...")
-- Create simple data for magnitude plot
local mag_data = {}
for i = 1, 20 do
    local freq = 0.01 * (10 ^ (i / 4))
    local mag = 1000 / ((1 + freq) * (1 + freq / 100))
    mag_data[#mag_data+1] = {freq, mag}
end

local mag_plot = plot.plot({})
mag_plot:AddSeries(mag_data, {DS_MODE="LINE"})

print("Creating second plot (phase)...")
-- Create simple data for phase plot
local phase_data = {}
for i = 1, 20 do
    local freq = 0.01 * (10 ^ (i / 4))
    local phase = -math.atan(freq) - math.atan(freq / 100)
    phase_data[#phase_data+1] = {freq, phase * 180 / math.pi}
end

local phase_plot = plot.plot({})
phase_plot:AddSeries(phase_data, {DS_MODE="LINE"})

print("\n=== Test 1: Show plots in separate windows ===")
mag_plot:Show({title="Magnitude Plot"})
phase_plot:Show({title="Phase Plot"})

print("\nPress Enter to close windows and continue...")
io.read()

print("\n=== Test 2: Create window with 2x1 grid (2 rows, 1 column) ===")
local win = plot.window{1,1; title="Bode Plots"}  -- 2 rows, 1 column each

print("Window created. Now adding plots...")
print("Adding magnitude plot to row 1, column 1...")
win:AddPlot(mag_plot, {1,1})

print("Adding phase plot to row 2, column 1...")
win:AddPlot(phase_plot, {2,1})

print("Showing window...")
local result = win:Show()
print("Result of win:Show():", result)

print("\nBoth plots should appear in a single window, stacked vertically.")
print("Press Enter to exit...")
io.read()

print("Test complete.")
