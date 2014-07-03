local args = {...}		-- arguments given by parent
-- Search for PARENT PORT number and store it in parentPort global variable
for i=1,#args,2 do
	if args[i] == "PARENT PORT" and args[i+1] and type(args[i+1]) == "number" then
		parentPort = args[i+1]
	end
end
require("LuaMath")
require("lua-plot.plotserver")
