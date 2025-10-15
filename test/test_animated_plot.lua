-- Animated plot test (non-blocking version)
local plot = require("lua-plot")
local socket = require("socket")

function func(x, c)
	return c/10*x^2
end

function genxy(c)
	local xy = {}
	for i = -10, 10, 1 do  -- Step size of 1 for 21 points
		xy[#xy+1] = {i, func(i, c)}
	end
	return xy
end

-- Create plot with fixed ranges
print("Creating plot...")
local p = plot.plot({})

print("Setting attributes...")
local ok, err = p:Attributes({
	AXS_XAUTOMIN="NO", AXS_XAUTOMAX="NO",
	AXS_YAUTOMIN="NO", AXS_YAUTOMAX="NO",
	AXS_XMAX=10, AXS_XMIN=-10,
	AXS_YMAX=200, AXS_YMIN=0
})
if not ok then
	print("Error setting attributes:", err)
	return
end

-- Add initial series
print("Adding initial series...")
p:AddSeries(genxy(10))

print("Showing plot...")
p:Show()

print("\nStarting animation (20 frames with 0.1s delay)...")
print("Watch the plot window update!")

-- Animate without blocking
local sign = -1
for i = 0, 19 do  -- 20 frames
	print(string.format("\n=== Frame %d/20 ===", i+1))

	socket.sleep(0.1)

	p:Attributes({REMOVE="CURRENT"})

	local c = i % 20
	if c == 0 then
		sign = sign * -1
	end
	if sign == -1 then
		c = 20 - c
	end

	p:AddSeries(genxy(c))
	p:Redraw()
end

print("\nAnimation complete! Press Enter to exit...")
io.read()
