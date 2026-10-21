--!strict

local VSCode = require("../lib/vscode")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local defaults = VSCode.settings(nil)
local remote = function(name: string, address: string?): VSCode.Host
	return { name = name, kind = "remote", address = address }
end

local function url(host: VSCode.Host, path: string, settings: VSCode.Settings?): string?
	local argv = VSCode.argv(host, path, settings or defaults)
	return if argv then argv[3] else nil
end

-- A Tern host name can collide with an unrelated ~/.ssh/config alias: the address must win.
check(
	url(remote("buildbox", "dev@203.0.113.7"), "/home/dev/app")
		== "vscode-remote://ssh-remote+dev@203.0.113.7/home/dev/app",
	"remote destination must come from the Tern address, not the visible host name"
)
check(
	url(remote("box", "10.0.0.5"), "/srv") == "vscode-remote://ssh-remote+10.0.0.5/srv",
	"an address without a user must stay without a user"
)
check(
	url(remote("box", "u@host:22"), "/srv") == "vscode-remote://ssh-remote+u@host/srv",
	"the default SSH port must not force the encoded form"
)

-- A non-default port or IPv6 cannot be expressed as user@host: VS Code takes hex-encoded JSON.
local function hexOf(json: string): string
	return (string.gsub(json, ".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end
check(
	url(remote("box", "alice@example.com:2222"), "/srv")
		== "vscode-remote://ssh-remote+" .. hexOf('{"hostName":"example.com","user":"alice","port":2222}') .. "/srv",
	"a custom port must use the encoded authority"
)
check(
	url(remote("box", "[fd7a::1]:2200"), "/srv")
		== "vscode-remote://ssh-remote+" .. hexOf('{"hostName":"fd7a::1","port":2200}') .. "/srv",
	"bracketed IPv6 must use the encoded authority"
)

-- Unusable or hostile addresses must not produce a command.
for _, bad in { "", "a b@host", "user@", "host;rm -rf /", "fd7a::1", "u@h:notaport", "user@host/../x" } do
	check(VSCode.argv(remote("box", bad), "/srv", defaults) == nil, "unsafe address must be rejected: " .. bad)
end
local missing, reason = VSCode.argv(remote("box", nil), "/srv", defaults)
check(missing == nil and reason ~= nil, "a remote host without an address must explain why it cannot open")

-- The user can map a Tern host to an SSH alias, case-insensitively, but only to safe aliases.
local mapped = VSCode.settings({ hosts = { BuildBox = "buildbox-vpn", evil = "a b", other = "x;y" } })
check(
	url(remote("buildbox", "dev@203.0.113.7"), "/srv", mapped) == "vscode-remote://ssh-remote+buildbox-vpn/srv",
	"a configured alias must override the address"
)
check(
	url(remote("evil", "u@h"), "/srv", mapped) == "vscode-remote://ssh-remote+u@h/srv",
	"an unsafe alias must be ignored"
)

-- Paths: spaces, reserved characters and non-ASCII must survive; only `/` and drive colons stay literal.
check(
	url(remote("b", "h"), "/a b/c#d%e?f/ñ") == "vscode-remote://ssh-remote+h/a%20b/c%23d%25e%3Ff/%C3%B1",
	"path bytes must be percent-encoded"
)
check(
	url({ name = "me", kind = "local" }, "/home/me/my app") == "file:///home/me/my%20app",
	"local folders must open through a file URI"
)
check(
	url({ name = "me", kind = "local" }, "C:/work/app") == "file:///C:/work/app",
	"Windows drive paths must gain a leading slash"
)
check(
	VSCode.argv({ name = "me", kind = "local" }, "relative/dir", defaults) == nil
		and VSCode.argv({ name = "me", kind = "local" }, "", defaults) == nil,
	"relative or empty paths must not open"
)

-- The launcher is always an argument vector; settings may change the executable but not smuggle control characters.
local argv = VSCode.argv({ name = "me", kind = "local" }, "/x", defaults)
check(
	argv ~= nil and argv[1] == "code" and argv[2] == "--folder-uri" and #argv == 3,
	"default launcher must be code --folder-uri URI"
)
check(VSCode.settings({ command = "code-insiders" }).command == "code-insiders", "a configured launcher must be used")
check(
	VSCode.settings({ command = "code\nrm" }).command == "code"
		and VSCode.settings({ command = 5 }).command == "code"
		and VSCode.settings("junk").command == "code",
	"invalid launcher settings must fall back to code"
)

-- The ssh prefix used to run git on the agent's machine: never prompts, honors port and user, never trusts hostile input.
local function ssh(host: VSCode.Host, settings: VSCode.Settings?): string
	local prefix = VSCode.ssh(host, settings or defaults)
	return if prefix then table.concat(prefix, " ") else "nil"
end
local BASE = "ssh -o BatchMode=yes -o ConnectTimeout=8"
check(ssh(remote("buildbox", "dev@203.0.113.7")) == BASE .. " dev@203.0.113.7", "ssh must target the Tern address")
check(
	ssh(remote("box", "alice@example.com:2222")) == BASE .. " -p 2222 alice@example.com",
	"ssh must pass a custom port with -p"
)
check(ssh(remote("box", "[fd7a::1]:2200")) == BASE .. " -p 2200 fd7a::1", "ssh must unwrap bracketed IPv6")
check(
	ssh(remote("buildbox", "dev@203.0.113.7"), VSCode.settings({ hosts = { buildbox = "buildbox" } }))
		== BASE .. " buildbox",
	"a configured alias must win over the address, matching VS Code"
)
check(
	ssh({ name = "me", kind = "local" }) == "nil"
		and VSCode.ssh(remote("box", nil), defaults) == nil
		and VSCode.ssh(remote("box", "host;rm"), defaults) == nil,
	"local hosts need no ssh; missing or hostile addresses must yield nothing"
)
check(
	VSCode.ssh(remote("box", "-oProxyCommand=x"), defaults) == nil,
	"an address that looks like an ssh option must be rejected"
)
print("VS Code: " .. checks .. " checks passed")
