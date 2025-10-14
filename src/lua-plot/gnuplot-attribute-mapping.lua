-- gnuplot-attribute-mapping.lua
-- Centralized attribute mapping system for lua-plot to gnuplot translation
--
-- This module provides a registry-based system for mapping lua-plot attributes
-- to gnuplot commands. Each attribute has a handler function, priority, and
-- embedded documentation.
--
-- Usage:
--   local AttributeMapping = require("lua-plot.gnuplot-attribute-mapping")
--   local commands = AttributeMapping:processAttributes(attributes)
--   -- Returns array of gnuplot commands in priority order

local AttributeMapping = {}

--[[
    ATTRIBUTE REGISTRY

    Each entry maps a lua-plot attribute to gnuplot command(s).

    Structure:
    {
        category = "plot" | "axis" | "grid" | "style" | "data",
        priority = number,  -- Execution order (lower = earlier)
        handler = function(value, context) → string or table of strings
        doc = {
            description = "What this attribute does",
            lua_example = "TITLE = 'My Plot'",
            gnuplot_output = "set title 'My Plot'",
            notes = "Additional information"
        }
    }

    Priority ranges:
    0-9:    Terminal/output setup
    10-19:  Plot-level settings (title, etc.)
    20-29:  Grid/background settings
    30-49:  Axis configuration
    50-99:  Style settings
    100+:   Per-series settings (handled separately)
]]

AttributeMapping.registry = {

    -- ========================================================================
    -- PLOT-LEVEL ATTRIBUTES
    -- ========================================================================

    TITLE = {
        category = "plot",
        priority = 10,
        handler = function(value, context)
            if value and value ~= "" then
                -- Escape single quotes
                local escaped = tostring(value):gsub("'", "''")
                return string.format("set title '%s'", escaped)
            else
                return "unset title"
            end
        end,
        doc = {
            description = "Sets the plot title",
            lua_example = "TITLE = 'My Plot'",
            gnuplot_output = "set title 'My Plot'",
            notes = "Single quotes in title are automatically escaped"
        }
    },

    -- ========================================================================
    -- GRID ATTRIBUTES
    -- ========================================================================

    GRID = {
        category = "grid",
        priority = 20,
        handler = function(value, context)
            if value == "YES" then
                return "set grid"
            else
                return "unset grid"
            end
        end,
        doc = {
            description = "Enable/disable grid lines",
            lua_example = "GRID = 'YES'",
            gnuplot_output = "set grid",
            notes = "Use 'YES' to enable, anything else to disable"
        }
    },

    GRIDLINESTYLE = {
        category = "grid",
        priority = 21,
        handler = function(value, context)
            if context.attributes.GRID ~= "YES" then
                return nil  -- Grid not enabled, skip
            end

            if value == "DOTTED" then
                return "set grid linetype 0 linewidth 1"
            else
                return "set grid linetype 1 linewidth 1"
            end
        end,
        doc = {
            description = "Sets grid line style",
            lua_example = "GRIDLINESTYLE = 'DOTTED'",
            gnuplot_output = "set grid linetype 0 linewidth 1",
            notes = "Requires GRID = 'YES' to have effect. Use 'DOTTED' for dotted lines."
        }
    },

    -- ========================================================================
    -- AXIS SCALE ATTRIBUTES
    -- ========================================================================

    AXS_XSCALE = {
        category = "axis",
        priority = 30,
        handler = function(value, context)
            if value == "LOG10" then
                return "set logscale x 10"
            else
                return "unset logscale x"
            end
        end,
        doc = {
            description = "Sets X axis scale (linear or logarithmic)",
            lua_example = "AXS_XSCALE = 'LOG10'",
            gnuplot_output = "set logscale x 10",
            notes = "Use 'LOG10' for log scale, 'LINEAR' or omit for linear"
        }
    },

    AXS_YSCALE = {
        category = "axis",
        priority = 30,
        handler = function(value, context)
            if value == "LOG10" then
                return "set logscale y 10"
            else
                return "unset logscale y"
            end
        end,
        doc = {
            description = "Sets Y axis scale (linear or logarithmic)",
            lua_example = "AXS_YSCALE = 'LOG10'",
            gnuplot_output = "set logscale y 10",
            notes = "Use 'LOG10' for log scale, 'LINEAR' or omit for linear"
        }
    },

    -- ========================================================================
    -- AXIS RANGE ATTRIBUTES
    -- ========================================================================

    AXS_BOUNDS = {
        category = "axis",
        priority = 35,
        handler = function(value, context)
            if type(value) == "table" and #value == 4 then
                return {
                    string.format("set xrange [%g:%g]", value[1], value[3]),
                    string.format("set yrange [%g:%g]", value[2], value[4])
                }
            end
            return nil
        end,
        doc = {
            description = "Sets axis bounds [xmin, ymin, xmax, ymax]",
            lua_example = "AXS_BOUNDS = {0, -1, 10, 1}",
            gnuplot_output = "set xrange [0:10]\nset yrange [-1:1]",
            notes = "Takes 4-element array. Overrides individual AXS_XMIN/MAX, AXS_YMIN/MAX"
        }
    },

    AXS_XMIN = {
        category = "axis",
        priority = 36,
        handler = function(value, context)
            -- Don't apply if AXS_BOUNDS already set
            if context.attributes.AXS_BOUNDS then
                return nil
            end

            local xmax = context.attributes.AXS_XMAX
            if xmax then
                return string.format("set xrange [%g:%g]", value, xmax)
            else
                return string.format("set xrange [%g:*]", value)
            end
        end,
        doc = {
            description = "Sets X axis minimum",
            lua_example = "AXS_XMIN = 0",
            gnuplot_output = "set xrange [0:*]",
            notes = "Use * for auto-max. Overridden by AXS_BOUNDS."
        }
    },

    AXS_XMAX = {
        category = "axis",
        priority = 36,
        handler = function(value, context)
            -- Don't apply if AXS_BOUNDS already set or if AXS_XMIN will handle both
            if context.attributes.AXS_BOUNDS or context.attributes.AXS_XMIN then
                return nil
            end

            return string.format("set xrange [*:%g]", value)
        end,
        doc = {
            description = "Sets X axis maximum",
            lua_example = "AXS_XMAX = 10",
            gnuplot_output = "set xrange [*:10]",
            notes = "Use * for auto-min. Overridden by AXS_BOUNDS."
        }
    },

    AXS_YMIN = {
        category = "axis",
        priority = 37,
        handler = function(value, context)
            -- Don't apply if AXS_BOUNDS already set
            if context.attributes.AXS_BOUNDS then
                return nil
            end

            local ymax = context.attributes.AXS_YMAX
            if ymax then
                return string.format("set yrange [%g:%g]", value, ymax)
            else
                return string.format("set yrange [%g:*]", value)
            end
        end,
        doc = {
            description = "Sets Y axis minimum",
            lua_example = "AXS_YMIN = -1",
            gnuplot_output = "set yrange [-1:*]",
            notes = "Use * for auto-max. Overridden by AXS_BOUNDS."
        }
    },

    AXS_YMAX = {
        category = "axis",
        priority = 37,
        handler = function(value, context)
            -- Don't apply if AXS_BOUNDS already set or if AXS_YMIN will handle both
            if context.attributes.AXS_BOUNDS or context.attributes.AXS_YMIN then
                return nil
            end

            return string.format("set yrange [*:%g]", value)
        end,
        doc = {
            description = "Sets Y axis maximum",
            lua_example = "AXS_YMAX = 1",
            gnuplot_output = "set yrange [*:1]",
            notes = "Use * for auto-min. Overridden by AXS_BOUNDS."
        }
    },

    -- ========================================================================
    -- AUTO-RANGING ATTRIBUTES
    -- ========================================================================

    AXS_XAUTOMIN = {
        category = "axis",
        priority = 38,
        handler = function(value, context)
            if value == "YES" then
                -- Will be handled by computing data ranges
                context.autorange = context.autorange or {}
                context.autorange.xmin = true
                return nil  -- No direct gnuplot command
            end
            return nil
        end,
        doc = {
            description = "Enable automatic X axis minimum based on data",
            lua_example = "AXS_XAUTOMIN = 'YES'",
            gnuplot_output = "(computed from data)",
            notes = "Requires data analysis. Overrides AXS_XMIN."
        }
    },

    AXS_XAUTOMAX = {
        category = "axis",
        priority = 38,
        handler = function(value, context)
            if value == "YES" then
                context.autorange = context.autorange or {}
                context.autorange.xmax = true
                return nil
            end
            return nil
        end,
        doc = {
            description = "Enable automatic X axis maximum based on data",
            lua_example = "AXS_XAUTOMAX = 'YES'",
            gnuplot_output = "(computed from data)",
            notes = "Requires data analysis. Overrides AXS_XMAX."
        }
    },

    AXS_YAUTOMIN = {
        category = "axis",
        priority = 38,
        handler = function(value, context)
            if value == "YES" then
                context.autorange = context.autorange or {}
                context.autorange.ymin = true
                return nil
            end
            return nil
        end,
        doc = {
            description = "Enable automatic Y axis minimum based on data",
            lua_example = "AXS_YAUTOMIN = 'YES'",
            gnuplot_output = "(computed from data)",
            notes = "Requires data analysis. Overrides AXS_YMIN."
        }
    },

    AXS_YAUTOMAX = {
        category = "axis",
        priority = 38,
        handler = function(value, context)
            if value == "YES" then
                context.autorange = context.autorange or {}
                context.autorange.ymax = true
                return nil
            end
            return nil
        end,
        doc = {
            description = "Enable automatic Y axis maximum based on data",
            lua_example = "AXS_YAUTOMAX = 'YES'",
            gnuplot_output = "(computed from data)",
            notes = "Requires data analysis. Overrides AXS_YMAX."
        }
    },
}

-- Data series options (processed separately per series)
AttributeMapping.seriesOptions = {

    DS_MODE = {
        category = "data",
        handler = function(value, context)
            if value == "LINE" then
                return "with lines"
            elseif value == "MARK" then
                return "with points"
            elseif value == "BAR" then
                return "with boxes"
            else
                return "with lines"  -- default
            end
        end,
        doc = {
            description = "Sets data series plotting style",
            lua_example = "DS_MODE = 'BAR'",
            gnuplot_output = "with boxes",
            notes = "Options: LINE (default), MARK, BAR"
        }
    },

    DS_LEGEND = {
        category = "data",
        handler = function(value, context)
            if value and value ~= "" then
                local escaped = tostring(value):gsub("'", "''")
                return string.format("title '%s'", escaped)
            else
                return "notitle"
            end
        end,
        doc = {
            description = "Sets legend label for data series",
            lua_example = "DS_LEGEND = 'Series 1'",
            gnuplot_output = "title 'Series 1'",
            notes = "Automatically escaped for gnuplot"
        }
    },
}

-- Process plot-level attributes and generate gnuplot commands
-- Returns: array of gnuplot command strings
function AttributeMapping:processAttributes(attributes, context)
    context = context or {}
    context.attributes = attributes
    context.autorange = {}

    local commands = {}
    local sortedAttrs = {}

    -- Collect applicable attributes with their priorities
    for key, value in pairs(attributes) do
        local mapping = self.registry[key]
        if mapping and mapping.handler then
            table.insert(sortedAttrs, {
                key = key,
                value = value,
                priority = mapping.priority,
                handler = mapping.handler
            })
        end
    end

    -- Sort by priority
    table.sort(sortedAttrs, function(a, b) return a.priority < b.priority end)

    -- Generate commands
    for _, attr in ipairs(sortedAttrs) do
        local result = attr.handler(attr.value, context)
        if result then
            if type(result) == "table" then
                for _, cmd in ipairs(result) do
                    table.insert(commands, cmd)
                end
            else
                table.insert(commands, result)
            end
        end
    end

    return commands, context
end

-- Process per-series options
-- Returns: string with gnuplot plot modifiers
function AttributeMapping:processSeriesOptions(options, context)
    context = context or {}
    context.options = options

    local parts = {}

    -- Process in a defined order for consistency
    local order = {"DS_MODE", "DS_LEGEND"}

    for _, key in ipairs(order) do
        local value = options[key]
        if value then
            local mapping = self.seriesOptions[key]
            if mapping and mapping.handler then
                local result = mapping.handler(value, context)
                if result then
                    table.insert(parts, result)
                end
            end
        end
    end

    return table.concat(parts, " ")
end

-- Generate documentation for all attributes
-- Returns: markdown string
function AttributeMapping:generateDocumentation()
    local doc = {}
    table.insert(doc, "# lua-plot to gnuplot Attribute Mapping\n\n")
    table.insert(doc, "This document describes how lua-plot attributes are translated to gnuplot commands.\n\n")
    table.insert(doc, "**Auto-generated documentation**\n\n")

    -- Group by category
    local categories = {}
    for key, mapping in pairs(self.registry) do
        local cat = mapping.category or "other"
        if not categories[cat] then
            categories[cat] = {}
        end
        table.insert(categories[cat], {key = key, mapping = mapping})
    end

    -- Add series options
    categories.data = categories.data or {}
    for key, mapping in pairs(self.seriesOptions) do
        table.insert(categories.data, {key = key, mapping = mapping})
    end

    -- Process each category
    local catOrder = {"plot", "grid", "axis", "style", "data"}
    for _, category in ipairs(catOrder) do
        local attrs = categories[category]
        if attrs then
            table.insert(doc, string.format("## %s Attributes\n\n", category:upper()))

            -- Sort by key name
            table.sort(attrs, function(a, b) return a.key < b.key end)

            for _, item in ipairs(attrs) do
                local key = item.key
                local mapping = item.mapping
                local d = mapping.doc or {}

                table.insert(doc, string.format("### %s\n\n", key))

                if d.description then
                    table.insert(doc, string.format("%s\n\n", d.description))
                end

                if d.lua_example then
                    table.insert(doc, string.format("**Lua example:**\n```lua\n%s\n```\n\n", d.lua_example))
                end

                if d.gnuplot_output then
                    table.insert(doc, string.format("**Gnuplot output:**\n```gnuplot\n%s\n```\n\n", d.gnuplot_output))
                end

                if d.notes then
                    table.insert(doc, string.format("*Note: %s*\n\n", d.notes))
                end
            end
        end
    end

    return table.concat(doc)
end

return AttributeMapping
