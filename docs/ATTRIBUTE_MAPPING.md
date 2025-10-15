# lua-plot to gnuplot Attribute Mapping

This document describes how lua-plot attributes are translated to gnuplot commands.

**Auto-generated documentation**

## PLOT Attributes

### TITLE

Sets the plot title

**Lua example:**
```lua
TITLE = 'My Plot'
```

**Gnuplot output:**
```gnuplot
set title 'My Plot'
```

*Note: Single quotes in title are automatically escaped*

## GRID Attributes

### GRID

Enable/disable grid lines

**Lua example:**
```lua
GRID = 'YES'
```

**Gnuplot output:**
```gnuplot
set grid
```

*Note: Use 'YES' to enable, anything else to disable*

### GRIDLINESTYLE

Sets grid line style

**Lua example:**
```lua
GRIDLINESTYLE = 'DOTTED'
```

**Gnuplot output:**
```gnuplot
set grid linetype 0 linewidth 1
```

*Note: Requires GRID = 'YES' to have effect. Use 'DOTTED' for dotted lines.*

## AXIS Attributes

### AXS_BOUNDS

Sets axis bounds [xmin, ymin, xmax, ymax]

**Lua example:**
```lua
AXS_BOUNDS = {0, -1, 10, 1}
```

**Gnuplot output:**
```gnuplot
set xrange [0:10]
set yrange [-1:1]
```

*Note: Takes 4-element array. Overrides individual AXS_XMIN/MAX, AXS_YMIN/MAX*

### AXS_XAUTOMAX

Enable automatic X axis maximum based on data

**Lua example:**
```lua
AXS_XAUTOMAX = 'YES'
```

**Gnuplot output:**
```gnuplot
(computed from data)
```

*Note: Requires data analysis. Overrides AXS_XMAX.*

### AXS_XAUTOMIN

Enable automatic X axis minimum based on data

**Lua example:**
```lua
AXS_XAUTOMIN = 'YES'
```

**Gnuplot output:**
```gnuplot
(computed from data)
```

*Note: Requires data analysis. Overrides AXS_XMIN.*

### AXS_XMAX

Sets X axis maximum

**Lua example:**
```lua
AXS_XMAX = 10
```

**Gnuplot output:**
```gnuplot
set xrange [*:10]
```

*Note: Use * for auto-min. Overridden by AXS_BOUNDS.*

### AXS_XMIN

Sets X axis minimum

**Lua example:**
```lua
AXS_XMIN = 0
```

**Gnuplot output:**
```gnuplot
set xrange [0:*]
```

*Note: Use * for auto-max. Overridden by AXS_BOUNDS.*

### AXS_XSCALE

Sets X axis scale (linear or logarithmic)

**Lua example:**
```lua
AXS_XSCALE = 'LOG10'
```

**Gnuplot output:**
```gnuplot
set logscale x 10
```

*Note: Use 'LOG10' for log scale, 'LINEAR' or omit for linear*

### AXS_YAUTOMAX

Enable automatic Y axis maximum based on data

**Lua example:**
```lua
AXS_YAUTOMAX = 'YES'
```

**Gnuplot output:**
```gnuplot
(computed from data)
```

*Note: Requires data analysis. Overrides AXS_YMAX.*

### AXS_YAUTOMIN

Enable automatic Y axis minimum based on data

**Lua example:**
```lua
AXS_YAUTOMIN = 'YES'
```

**Gnuplot output:**
```gnuplot
(computed from data)
```

*Note: Requires data analysis. Overrides AXS_YMIN.*

### AXS_YMAX

Sets Y axis maximum

**Lua example:**
```lua
AXS_YMAX = 1
```

**Gnuplot output:**
```gnuplot
set yrange [*:1]
```

*Note: Use * for auto-min. Overridden by AXS_BOUNDS.*

### AXS_YMIN

Sets Y axis minimum

**Lua example:**
```lua
AXS_YMIN = -1
```

**Gnuplot output:**
```gnuplot
set yrange [-1:*]
```

*Note: Use * for auto-max. Overridden by AXS_BOUNDS.*

### AXS_YSCALE

Sets Y axis scale (linear or logarithmic)

**Lua example:**
```lua
AXS_YSCALE = 'LOG10'
```

**Gnuplot output:**
```gnuplot
set logscale y 10
```

*Note: Use 'LOG10' for log scale, 'LINEAR' or omit for linear*

## DATA Attributes

### DS_LEGEND

Sets legend label for data series

**Lua example:**
```lua
DS_LEGEND = 'Series 1'
```

**Gnuplot output:**
```gnuplot
title 'Series 1'
```

*Note: Automatically escaped for gnuplot*

### DS_MODE

Sets data series plotting style

**Lua example:**
```lua
DS_MODE = 'BAR'
```

**Gnuplot output:**
```gnuplot
with boxes
```

*Note: Options: LINE (default), MARK, BAR*

