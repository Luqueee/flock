--!strict

-- Pure helpers that turn a Tern host and a project directory into a VS Code launch command.
-- Nothing here touches the system: window.luau reads settings and runs the process.

export type Host = { name: string, kind: string, address: string? }
export type Settings = { command: string, hosts: { [string]: string } }

local VSCode = {}

local DEFAULT_COMMAND = "code"

local function safeName(value: string): boolean
	return string.match(value, "^[%w][%w._-]*$") ~= nil
end

local function safeAlias(value: string): boolean
	return string.match(value, "^[%w][%w._@-]*$") ~= nil
end

local function hex(text: string): string
	return (string.gsub(text, ".", function(char)
		return string.format("%02x", string.byte(char))
	end))
end

-- A URI path keeps `/` and `:` (drive letters); every other non-unreserved byte is escaped.
local function encodePath(path: string): string?
	local absolute = path
	if string.match(absolute, "^%a:/") then
		absolute = "/" .. absolute
	end
	if string.sub(absolute, 1, 1) ~= "/" then
		return nil
	end
	return (
		string.gsub(absolute, "[^%w%-%._~/:]", function(char)
			return string.format("%%%02X", string.byte(char))
		end)
	)
end

-- Reads `[user@]host[:port]` and `[user@][v6][:port]`. Bare IPv6 is ambiguous and rejected.
local function parseAddress(address: string): (string?, string?, number?, boolean)
	local user: string? = nil
	local rest = address
	local name, tail = string.match(address, "^([^@]+)@(.+)$")
	if name and tail then
		if not safeName(name) then
			return nil, nil, nil, false
		end
		user, rest = name, tail
	end
	local v6, v6port = string.match(rest, "^%[([%x:%.]+)%]:?(%d*)$")
	if v6 then
		return user, v6, tonumber(v6port), true
	end
	local host, port = string.match(rest, "^([%w][%w._-]*):(%d+)$")
	if host then
		return user, host, tonumber(port), false
	end
	if safeName(rest) then
		return user, rest, nil, false
	end
	return nil, nil, nil, false
end

-- Validates the user's optional settings table; anything malformed falls back to the defaults.
function VSCode.settings(raw: any): Settings
	local command = DEFAULT_COMMAND
	local hosts: { [string]: string } = {}
	if type(raw) == "table" then
		local candidate = raw.command
		if
			type(candidate) == "string"
			and candidate ~= ""
			and #candidate <= 256
			and string.match(candidate, "%c") == nil
		then
			command = candidate
		end
		local map = raw.hosts
		if type(map) == "table" then
			for key, alias in map do
				if type(key) == "string" and type(alias) == "string" and safeAlias(alias) then
					hosts[string.lower(key)] = alias
				end
			end
		end
	end
	return { command = command, hosts = hosts }
end

-- The SSH authority VS Code expects after `ssh-remote+`. The visible Tern host name is NOT used
-- unless the user maps it: it may name a different machine in ~/.ssh/config.
function VSCode.authority(host: Host, settings: Settings): (string?, string?)
	local alias = settings.hosts[string.lower(host.name)]
	if alias then
		return alias, nil
	end
	local address = host.address
	if address == nil or address == "" then
		return nil, "Tern no expone la dirección SSH de «" .. host.name .. "»."
	end
	local user, hostname, port, needsJson = parseAddress(address)
	if not hostname then
		return nil, "No se puede interpretar la dirección «" .. address .. "» de «" .. host.name .. "»."
	end
	if needsJson or (port ~= nil and port ~= 22) then
		local fields = { '"hostName":"' .. hostname .. '"' }
		if user then
			table.insert(fields, '"user":"' .. user .. '"')
		end
		if port then
			table.insert(fields, '"port":' .. tostring(port))
		end
		return hex("{" .. table.concat(fields, ",") .. "}"), nil
	end
	return if user then user .. "@" .. hostname else hostname, nil
end

-- The `ssh` prefix that runs a command on the machine behind a remote Tern host, or nil and a reason.
-- BatchMode keeps a missing key from hanging on a password prompt. Local hosts have no prefix.
function VSCode.ssh(host: Host, settings: Settings): ({ string }?, string?)
	if host.kind == "local" then
		return nil, nil
	end
	local base = { "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8" }
	local alias = settings.hosts[string.lower(host.name)]
	if alias then
		table.insert(base, alias)
		return base, nil
	end
	local address = host.address
	if address == nil or address == "" then
		return nil, "Tern no expone la dirección SSH de «" .. host.name .. "»."
	end
	local user, hostname, port = parseAddress(address)
	if not hostname then
		return nil, "No se puede interpretar la dirección «" .. address .. "» de «" .. host.name .. "»."
	end
	if port and port ~= 22 then
		table.insert(base, "-p")
		table.insert(base, tostring(port))
	end
	table.insert(base, if user then user .. "@" .. hostname else hostname)
	return base, nil
end

-- The full argument vector, or nil and a user-facing reason. Paths never reach a shell.
function VSCode.argv(host: Host, path: string, settings: Settings): ({ string }?, string?)
	local encoded = encodePath(path)
	if path == "" or not encoded then
		return nil, "El proyecto no tiene un directorio absoluto conocido."
	end
	if host.kind == "local" then
		return { settings.command, "--folder-uri", "file://" .. encoded }, nil
	end
	local authority, reason = VSCode.authority(host, settings)
	if not authority then
		return nil, reason
	end
	return { settings.command, "--folder-uri", "vscode-remote://ssh-remote+" .. authority .. encoded }, nil
end

return VSCode
