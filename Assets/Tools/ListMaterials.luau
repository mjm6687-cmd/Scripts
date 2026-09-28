--[[
	LIST MATERIALS  --  run this in Studio's COMMAND BAR (View > Command Bar)
	-----------------------------------------------------------------------
	Prints everything in MaterialService to the Output window, in one block you
	can copy and paste to Claude:
	  * every MaterialVariant (custom material): its name, which base material it
	    sits on, tile size, and which texture maps it has
	  * which base materials have been overridden by a variant (so every part
	    using e.g. Concrete actually shows your custom concrete)
	  * how many parts in Workspace use each variant right now
	Changes nothing.
]]

local MaterialService = game:GetService("MaterialService")

local lines = {}
local function out(s)
	table.insert(lines, s)
end

-- How often each variant is actually used in Workspace.
local used = {}
for _, d in ipairs(workspace:GetDescendants()) do
	if d:IsA("BasePart") and d.MaterialVariant ~= "" then
		used[d.MaterialVariant] = (used[d.MaterialVariant] or 0) + 1
	end
end

local variants = {}
for _, d in ipairs(MaterialService:GetDescendants()) do
	if d:IsA("MaterialVariant") then
		table.insert(variants, d)
	end
end
table.sort(variants, function(a, b)
	if a.BaseMaterial ~= b.BaseMaterial then
		return a.BaseMaterial.Name < b.BaseMaterial.Name
	end
	return a.Name < b.Name
end)

out("===== MATERIALSERVICE =====")
pcall(function()
	out("Use2022Materials: " .. tostring(MaterialService.Use2022Materials))
end)

out(("--- MaterialVariants (%d) ---"):format(#variants))
out("name | base material | studs per tile | maps | parts using it | folder")
for _, v in ipairs(variants) do
	local maps = {}
	for _, prop in ipairs({ "ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap" }) do
		local ok, val = pcall(function()
			return v[prop]
		end)
		if ok and val ~= "" then
			table.insert(maps, (prop:gsub("Map", "")))
		end
	end
	local pattern = ""
	pcall(function()
		if v.MaterialPattern ~= Enum.MaterialPattern.Regular then
			pattern = " (" .. v.MaterialPattern.Name .. ")"
		end
	end)
	local where = v.Parent == MaterialService and "-" or v.Parent:GetFullName():gsub("^MaterialService%.", "")
	out(("%s | %s | %s%s | %s | %d | %s"):format(
		v.Name, v.BaseMaterial.Name, tostring(v.StudsPerTile), pattern,
		#maps > 0 and table.concat(maps, "+") or "none", used[v.Name] or 0, where))
end

out("--- Base material overrides ---")
local any = false
for _, m in ipairs(Enum.Material:GetEnumItems()) do
	local ok, name = pcall(function()
		return MaterialService:GetBaseMaterialOverride(m)
	end)
	if ok and name and name ~= "" then
		out(("%s -> %s"):format(m.Name, name))
		any = true
	end
end
if not any then
	out("(none)")
end

-- Variants that are referenced by parts but don't exist (typos, deleted variants).
local missing = {}
local known = {}
for _, v in ipairs(variants) do
	known[v.Name] = true
end
for name, n in pairs(used) do
	if not known[name] then
		table.insert(missing, ("%s (%d parts)"):format(name, n))
	end
end
if #missing > 0 then
	out("--- Used in Workspace but NOT in MaterialService ---")
	for _, s in ipairs(missing) do
		out(s)
	end
end
out("===== END =====")

print("\n" .. table.concat(lines, "\n"))
