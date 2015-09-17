-- Start this file with a command like:
-- >lua launchPlotServer.lua "PARENT PORT" portNum

local args = {...}		-- arguments given by parent
-- Search for PARENT PORT number and store it in parentPort global variable
for i=1,#args,2 do
	--print(args[i],args[i+1],args[i]=="PARENT PORT",#args[i])
	if args[i] == "PARENT PORT" and args[i+1] then
		--print("Set parentPort = ",tonumber(args[i+1]))
		parentPort = args[i+1]
	end
end

--print("plotserver is launched")
require("lua-plot.plotserver")
