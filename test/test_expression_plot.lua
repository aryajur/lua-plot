-- Test expression plotting functionality
local plot = require("lua-plot")

print("=== Test 1: Pure Expression Plots ===")
print("Plotting mathematical functions: sin(x) and cos(x)")

local p1 = plot.plot({
    AXS_XLABEL = "x",
    AXS_YLABEL = "y",
    AXS_XMIN = -10,
    AXS_XMAX = 10
})

print("Adding sin(x) expression...")
local success, err = p1:AddExpression("sin(x)", {
    DS_MODE = "LINE",
    DS_LEGEND = "sin(x)"
})
if not success then
    print("Error adding sin(x):", err)
    return
end

print("Adding cos(x) expression...")
success, err = p1:AddExpression("cos(x)", {
    DS_MODE = "LINE",
    DS_LEGEND = "cos(x)"
})
if not success then
    print("Error adding cos(x):", err)
    return
end

print("Showing plot...")
p1:Show({title = "Pure Expression Plot: sin(x) and cos(x)"})

print("\nPress Enter to continue to Test 2...")
io.read()

print("\n=== Test 2: Mixed Expression and Data Plots ===")
print("Plotting expression x**2 with noisy data points")

local p2 = plot.plot({
    AXS_XLABEL = "x",
    AXS_YLABEL = "y"
})

-- Add expression
print("Adding x**2 expression...")
success, err = p2:AddExpression("x**2", {
    DS_MODE = "LINE",
    DS_LEGEND = "y = x²"
})
if not success then
    print("Error adding x**2:", err)
    return
end

-- Generate some noisy data points
print("Generating noisy data points...")
local data = {}
for i = -10, 10 do
    data[#data+1] = {i, i*i + math.random(-5, 5)}
end

print("Adding data series...")
success, err = p2:AddSeries(data, {
    DS_MODE = "MARK",
    DS_LEGEND = "Noisy data"
})
if not success then
    print("Error adding data series:", err)
    return
end

print("Showing plot...")
p2:Show({title = "Mixed Plot: Expression + Data"})

print("\nPress Enter to continue to Test 3...")
io.read()

print("\n=== Test 3: Multiple Expressions ===")
print("Plotting multiple polynomial expressions")

local p3 = plot.plot({
    AXS_XLABEL = "x",
    AXS_YLABEL = "y",
    AXS_XMIN = -3,
    AXS_XMAX = 3
})

-- Add multiple polynomial expressions
print("Adding x expression...")
p3:AddExpression("x", {
    DS_MODE = "LINE",
    DS_LEGEND = "y = x"
})

print("Adding x**2 expression...")
p3:AddExpression("x**2", {
    DS_MODE = "LINE",
    DS_LEGEND = "y = x²"
})

print("Adding x**3 expression...")
p3:AddExpression("x**3", {
    DS_MODE = "LINE",
    DS_LEGEND = "y = x³"
})

print("Showing plot...")
p3:Show({title = "Multiple Expressions: x, x², x³"})

print("\nPress Enter to exit...")
io.read()

print("Expression plotting tests complete!")
