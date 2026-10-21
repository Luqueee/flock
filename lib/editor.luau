--!strict

local Model = require("./model")
local Snapshot = require("./snapshot")
local Sidebar = require("./sidebar")
local VSCode = require("./vscode")
local Worktree = require("./worktree")

local Editor = {}
type State = Sidebar.State
local resolving: { [number]: boolean } = {}

function Editor.vscodeSettings(): (VSCode.Settings, boolean)
	local path = tern.plugin.data .. "/vscode.json"
	if not tern.fs.exists(path) then
		return VSCode.settings(nil), false
	end
	local ok, decoded = pcall(function()
		return tern.json.decode(tern.fs.read(path))
	end)
	if not ok then
		tern.log.warn("vscode.json no es válido", decoded)
		return VSCode.settings(nil), true
	end
	return VSCode.settings(decoded), false
end

function Editor.hostInfo(cx: WindowCx, host: number): VSCode.Host?
	for _, row in cx.hosts:list() do
		if row.id == host then
			local found: VSCode.Host = {
				name = row.name,
				kind = row.kind :: string,
				address = if type(row.address) == "string" then row.address else nil,
			}
			return found
		end
	end
	return nil
end

function Editor.openInVSCode(cx: WindowCx, host: number, path: string, title: string?)
	local info = Editor.hostInfo(cx, host)
	if not info then
		cx:toast("error", "No se puede abrir en VS Code", "La máquina del proyecto ya no está conectada.")
		return
	end
	local settings, invalid = Editor.vscodeSettings()
	if invalid then
		cx:toast("error", "vscode.json no es válido", "Se usa la configuración por defecto.")
	end
	local argv, reason = VSCode.argv(info, path, settings)
	if not argv then
		cx:toast("error", "No se puede abrir en VS Code", reason)
		return
	end
	local function finished(result: ProcessResult, later: WindowCx?)
		if later and (result.status ~= 0 or result.timed_out) then
			local line = string.match(result.stderr, "[^\r\n]+") or "Sin detalles."
			later:toast("error", "VS Code no pudo abrir el proyecto", line)
		end
	end
	local started, failure = pcall(function()
		tern.process.run(argv, { timeout_ms = 20000 }, finished)
	end)
	if started then
		local destination = if info.kind == "local"
			then "este equipo"
			else (settings.hosts[string.lower(info.name)] or info.address or info.name)
		cx:toast("info", title or "Abriendo en VS Code", destination .. " · " .. path)
	else
		cx:toast(
			"error",
			"No se pudo ejecutar «" .. settings.command .. "»",
			"Revisa el PATH o `command` en vscode.json."
		)
		tern.log.warn("VS Code launcher failed", failure)
	end
end

function Editor.openProjectInVSCode(cx: WindowCx, key: string?)
	for _, project in Snapshot.board(cx).projects do
		if project.key == key then
			Editor.openInVSCode(cx, project.host, project.path)
			return
		end
	end
	cx:toast("info", "Ese proyecto ya no está disponible")
end

-- File tools of an agent, oldest first. Its native transcript carries the absolute path of every file it touched,
-- which is the only trace of a worktree: the session keeps the cwd it was launched in.
function Editor.agentTools(cx: WindowCx, pane: number): { Worktree.Tool }
	local tools: { Worktree.Tool } = {}
	local ok, messages = pcall(function()
		return cx.agents:transcript(pane, { last = 120 })
	end)
	if not ok then
		return tools
	end
	for _, message in messages do
		for _, tool in message.tools do
			local href = tool.href
			local name = tool.name
			local entry: Worktree.Tool = {
				name = if type(name) == "string" then name else "",
				path = if type(href) == "string" then Worktree.fileUri(href) else nil,
			}
			table.insert(tools, entry)
		end
	end
	return tools
end

type Located = { agent: Model.Agent, host: number, cwd: string }

local function locateAgent(cx: WindowCx, pane: number): Located?
	for _, project in Snapshot.board(cx).projects do
		for _, session in project.sessions do
			for _, agent in session.agents do
				if agent.pane == pane and project.path ~= "" then
					return { agent = agent, host = project.host, cwd = project.path }
				end
			end
		end
	end
	return nil
end

-- The command that lists the worktrees of `cwd` on the agent's machine: `sh` locally, `ssh` for a remote host.
local function gitQuery(
	info: VSCode.Host,
	settings: VSCode.Settings,
	cwd: string,
	candidates: { Worktree.Candidate }
): ({ string }?, string?)
	if info.kind == "local" then
		return Worktree.argv(cwd, candidates), nil
	end
	local prefix, reason = VSCode.ssh(info, settings)
	if not prefix then
		return nil, reason
	end
	table.insert(prefix, Worktree.command(cwd, candidates))
	return prefix, nil
end

local function openChoice(cx: WindowCx, host: number, choice: Worktree.Choice)
	if choice.kind == "worktree" then
		local branch = if choice.branch then " «" .. choice.branch .. "»" else ""
		Editor.openInVSCode(cx, host, choice.path, "Abriendo el worktree" .. branch)
	else
		Editor.openInVSCode(cx, host, choice.path)
	end
end

-- Opens the worktree an agent is working in, falling back to its project folder whenever that cannot be told.
function Editor.openAgentInVSCode(cx: WindowCx, value: string?)
	local pane = value and tonumber(value)
	if not pane or resolving[pane] then
		return
	end
	local target = locateAgent(cx, pane)
	if not target then
		cx:toast("info", "Ese agente ya no está disponible")
		return
	end
	local host, cwd = target.host, target.cwd
	local info = Editor.hostInfo(cx, host)
	if not info then
		cx:toast("error", "No se puede abrir en VS Code", "La máquina del agente ya no está conectada.")
		return
	end
	local candidates = Worktree.collect(Editor.agentTools(cx, pane))
	if #candidates == 0 then
		Editor.openInVSCode(cx, host, cwd)
		return
	end
	local argv, reason = gitQuery(info, (Editor.vscodeSettings()), cwd, candidates)
	if not argv then
		cx:toast("error", "No se pudo consultar git; abro la carpeta del proyecto", reason)
		Editor.openInVSCode(cx, host, cwd)
		return
	end
	local function answered(result: ProcessResult, later: WindowCx?)
		resolving[pane] = nil
		if not later then
			return
		end
		if result.status ~= 0 or result.timed_out then
			local line = string.match(result.stderr, "[^\r\n]+") or "Sin respuesta."
			later:toast("error", "No se pudo consultar git; abro la carpeta del proyecto", line)
			Editor.openInVSCode(later, host, cwd)
			return
		end
		openChoice(later, host, Worktree.choose(cwd, candidates, Worktree.parse(result.stdout)))
	end
	resolving[pane] = true
	local started = pcall(function()
		tern.process.run(argv, { timeout_ms = 20000 }, answered)
	end)
	if started then
		cx:toast("info", "Buscando el worktree de «" .. target.agent.title .. "»")
	else
		resolving[pane] = nil
		cx:toast("error", "No se pudo consultar git; abro la carpeta del proyecto", "Falta `sh` o `ssh` en el PATH.")
		Editor.openInVSCode(cx, host, cwd)
	end
end

function Editor.openFocusedInVSCode(state: State, cx: WindowCx)
	local focused = Sidebar.focusedContent(state, cx)
	if focused then
		for _, project in Snapshot.board(cx).projects do
			for _, session in project.sessions do
				for _, agent in session.agents do
					if agent.pane == focused then
						Editor.openAgentInVSCode(cx, tostring(agent.pane))
						return
					end
				end
				for _, terminal in session.terminals do
					if terminal.pane == focused then
						Editor.openInVSCode(cx, project.host, project.path)
						return
					end
				end
			end
		end
	end
	cx:toast("info", "El panel enfocado no es un agente ni una terminal con proyecto")
end

return Editor
