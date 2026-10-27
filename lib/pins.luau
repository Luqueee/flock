--!strict

-- Each project (category) can own one persistent terminal. The link lives in the plugin's key-value store, so it
-- survives reloads and restarts, and it records the project's path: the terminal keeps showing under that project
-- whatever directory its shell moves to.
local Pins = {}

export type Pin = { pane: number, path: string }

local KEY = "category_terminals"

local function load(): { [string]: Pin }
	local raw = tern.kv.get(KEY)
	if type(raw) ~= "string" then
		return {}
	end
	local ok, value = pcall(tern.json.decode, raw)
	if not ok or type(value) ~= "table" then
		return {}
	end
	local pins: { [string]: Pin } = {}
	for key, pin in value :: { [string]: any } do
		if type(pin) == "table" and type(pin.pane) == "number" and type(pin.path) == "string" then
			pins[key] = { pane = pin.pane, path = pin.path }
		end
	end
	return pins
end

local function save(pins: { [string]: Pin })
	if next(pins) == nil then
		tern.kv.set(KEY, nil)
	else
		tern.kv.set(KEY, tern.json.encode(pins))
	end
end

-- The live pane pinned to `key`, if it still exists.
function Pins.paneFor(cx: WindowCx, key: string): number?
	local pin = load()[key]
	if pin and cx.session:pane(pin.pane) then
		return pin.pane
	end
	return nil
end

-- Pinned pane -> project path, only for panes that still exist.
function Pins.panePaths(cx: WindowCx): { [number]: string }
	local result: { [number]: string } = {}
	for _, pin in load() do
		if cx.session:pane(pin.pane) then
			result[pin.pane] = pin.path
		end
	end
	return result
end

-- Pins `pane` to the project `key` and forgets pins whose pane is gone.
function Pins.set(cx: WindowCx, key: string, pane: number, path: string)
	local pins = load()
	for other, pin in pins do
		if not cx.session:pane(pin.pane) then
			pins[other] = nil
		end
	end
	pins[key] = { pane = pane, path = path }
	save(pins)
end

return Pins
