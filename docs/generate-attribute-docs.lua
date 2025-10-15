#!/usr/bin/env lua
-- Script to generate attribute mapping documentation

-- Add path for requiring the module
package.path = package.path .. ";../src/?.lua;../src/lua-plot/?.lua"

local AttributeMapping = require("gnuplot-attribute-mapping")

-- Generate documentation
local doc = AttributeMapping:generateDocumentation()

-- Write to file
local f = io.open("ATTRIBUTE_MAPPING.md", "w")
if f then
    f:write(doc)
    f:close()
    print("Documentation generated: docs/ATTRIBUTE_MAPPING.md")
else
    print("ERROR: Could not write documentation file")
    print(doc)
end
