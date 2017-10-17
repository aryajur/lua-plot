local modname = ...
local type = type
local tostring = tostring
local string = string
local loadstring = loadstring
local load = load
local setfenv = setfenv
local pcall = pcall
local pairs = pairs
local table = table

local print = print

local M = {} 
package.loaded[modname] = M
if setfenv then
	setfenv(1,M)
else
	_ENV = M
end



-- Function to convert a table to a string
-- Metatables not followed
-- Unless key is a number it will be taken and converted to a string
function tableToString(t)
	-- local levels = 0
	local rL = {cL = 1}	-- Table to track recursion into nested tables (cL = current recursion level)
	rL[rL.cL] = {}
	local result = {}
	do
		rL[rL.cL]._f,rL[rL.cL]._s,rL[rL.cL]._var = pairs(t)
		--result[#result + 1] =  "{\n"..string.rep("\t",levels+1)		
		result[#result + 1] = "{"		-- Non pretty version
		rL[rL.cL].t = t
		while true do
			local k,v = rL[rL.cL]._f(rL[rL.cL]._s,rL[rL.cL]._var)
			rL[rL.cL]._var = k
			if not k and rL.cL == 1 then
				break
			elseif not k then
				-- go up in recursion level
				-- If condition for pretty printing
				-- if result[#result]:sub(-1,-1) == "," then
					-- result[#result] = result[#result]:sub(1,-3)	-- remove the tab and the comma
				-- else
					-- result[#result] = result[#result]:sub(1,-2)	-- just remove the tab
				-- end
				result[#result + 1] = "},"	-- non pretty version
				-- levels = levels - 1
				rL.cL = rL.cL - 1
				rL[rL.cL+1] = nil
				--rL[rL.cL].str = rL[rL.cL].str..",\n"..string.rep("\t",levels+1)
			else
				-- Handle the key and value here
				if type(k) == "number" then
					result[#result + 1] = "["..tostring(k).."]="
				else
					if k:match([["]]) then
						result[#result + 1] = "["..[[']]..tostring(k)..[[']].."]="
					else
						result[#result + 1] = "["..[["]]..tostring(k)..[["]].."]="
					end
				end
				if type(v) == "table" then
					-- Check if this is not a recursive table
					local goDown = true
					for i = 1, rL.cL do
						if v==rL[i].t then
							-- This is recursive do not go down
							goDown = false
							break
						end
					end
					if goDown then
						-- Go deeper in recursion
						-- levels = levels + 1
						rL.cL = rL.cL + 1
						rL[rL.cL] = {}
						rL[rL.cL]._f,rL[rL.cL]._s,rL[rL.cL]._var = pairs(v)
						--result[#result + 1] = "{\n"..string.rep("\t",levels+1)
						result[#result + 1] = "{"	-- non pretty version
						rL[rL.cL].t = v
					else
						--result[#result + 1] = "\""..tostring(v).."\",\n"..string.rep("\t",levels+1)
						result[#result + 1] = "\""..tostring(v).."\","	-- non pretty version
					end
				elseif type(v) == "number" or type(v) == "boolean" then
					--result[#result + 1] = tostring(v)..",\n"..string.rep("\t",levels+1)
					result[#result + 1] = tostring(v)..","	-- non pretty version
				else
					--result[#result + 1] = string.format("%q",tostring(v))..",\n"..string.rep("\t",levels+1)
					result[#result + 1] = string.format("%q",tostring(v))..","	-- non pretty version
				end		-- if type(v) == "table" then ends
			end		-- if not rL[rL.cL]._var and rL.cL == 1 then ends
		end		-- while true ends here
	end		-- do ends
	-- If condition for pretty printing
	-- if result[#result]:sub(-1,-1) == "," then
		-- result[#result] = result[#result]:sub(1,-3)	-- remove the tab and the comma
	-- else
		-- result[#result] = result[#result]:sub(1,-2)	-- just remove the tab
	-- end
	result[#result + 1] = "}"	-- non pretty version
	return table.concat(result)end

-- convert str to table
function stringToTable(str)
  local fileFunc
	local safeenv = {}
  if loadstring and setfenv then
    fileFunc = loadstring("t="..str)
    setfenv(f,safeenv)
  else
    fileFunc = load("t="..str,"stringToTable","t",safeenv)
  end
	local err,msg = pcall(fileFunc)
	if not err or not safeenv.t or type(safeenv.t) ~= "table" then
		return nil,msg or type(safeenv.t) ~= "table" and "Not a table"
	end
	return safeenv.t
end


