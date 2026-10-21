--!strict

export type InputSession = { id: number, name: string, host: number, current: boolean, locked: boolean }
export type InputTab = { id: number, session: number, pane: number, cwd: string? }
export type InputPane = {
	pane: number,
	tab: number?,
	cwd: string?,
	title: string,
	kind: string?,
	program: string?,
	busy: boolean?,
	at_prompt: boolean?,
	running: { line: string, ms: number }?,
	exited: number?,
}
export type InputAgent = { pane: number, cwd: string, state: string, last_message: any, model: any }
export type Snapshot = {
	sessions: { InputSession },
	tabs: { InputTab },
	panes: { InputPane },
	agents: { InputAgent },
	hosts: { [number]: string },
	excluded: { [number]: boolean },
}
export type Agent = {
	pane: number,
	session: number,
	title: string,
	cwd: string,
	state: string,
	last_message: string?,
	model: string?,
}
export type Terminal = {
	pane: number,
	session: number,
	title: string,
	cwd: string,
	program: string?,
	command: string?,
	state: "running" | "ready" | "exited" | "open",
	exit_status: number?,
}
export type Session = {
	id: number,
	name: string,
	current: boolean,
	locked: boolean,
	pane: number?,
	agents: { Agent },
	terminals: { Terminal },
}
export type Project =
	{ key: string, path: string, name: string, host: number, host_name: string, sessions: { Session } }
export type Board = {
	projects: { Project },
	working: number,
	waiting: number,
	idle: number,
	exited: number,
	total: number,
	terminalTotal: number,
}

local Model = {}

local function normalizePath(path: string): string
	if path == "" then
		return ""
	end
	local windows = string.match(path, "^[A-Za-z]:") ~= nil or string.sub(path, 1, 2) == "\\\\"
	local normalized = if windows then string.gsub(path, "\\", "/") else path
	local isUnc = string.sub(normalized, 1, 2) == "//"
	local isDriveRoot = string.match(normalized, "^[A-Za-z]:/$") ~= nil
	local isPosixRoot = string.match(normalized, "^/+$") ~= nil
	local isUncRoot = isUnc and string.match(normalized, "^//[^/]+/[^/]+/*$") ~= nil
	if isPosixRoot then
		return "/"
	end
	if isDriveRoot then
		return string.sub(normalized, 1, 2) .. "/"
	end
	if isUncRoot then
		local trimmed = string.gsub(normalized, "/+$", "")
		return trimmed .. "/"
	end
	return string.gsub(normalized, "/+$", "")
end

local function pathName(path: string): string
	if path == "" then
		return "Sin directorio"
	end
	local withoutSlash = string.gsub(path, "/+$", "")
	if withoutSlash == "" then
		return path
	end
	local name = string.match(withoutSlash, "([^/]+)$")
	return name or path
end

local function nonempty(value: string?): boolean
	return value ~= nil and value ~= ""
end

local function agentLess(a: Agent, b: Agent): boolean
	local function rank(state: string): number
		if state == "waiting_input" then
			return 1
		end
		if state == "working" then
			return 2
		end
		if state == "idle" then
			return 3
		end
		if state == "exited" then
			return 4
		end
		return 5
	end
	local ar, br = rank(a.state), rank(b.state)
	if ar ~= br then
		return ar < br
	end
	local at, bt = string.lower(a.title), string.lower(b.title)
	if at ~= bt then
		return at < bt
	end
	if a.title ~= b.title then
		return a.title < b.title
	end
	return a.pane < b.pane
end

local function sessionLess(a: Session, b: Session): boolean
	local an, bn = string.lower(a.name), string.lower(b.name)
	if an ~= bn then
		return an < bn
	end
	if a.name ~= b.name then
		return a.name < b.name
	end
	return a.id < b.id
end

local function projectLess(a: Project, b: Project): boolean
	local an, bn = string.lower(a.name), string.lower(b.name)
	if an ~= bn then
		return an < bn
	end
	if a.name ~= b.name then
		return a.name < b.name
	end
	if a.path ~= b.path then
		return a.path < b.path
	end
	return a.host < b.host
end

type BuildIndexes = {
	tabs: { [number]: InputTab },
	panes: { [number]: InputPane },
	sessions: { [number]: InputSession },
	agentsByPane: { [number]: InputAgent },
}

type BuildState = {
	snapshot: Snapshot,
	indexes: BuildIndexes,
	projectsByKey: { [string]: Project },
	sessionByProject: { [string]: { [number]: Session } },
	seenAgent: { [number]: boolean },
	seenTerminal: { [number]: boolean },
	working: number,
	waiting: number,
	idle: number,
	exited: number,
	total: number,
	terminalTotal: number,
}

local function buildIndexes(snapshot: Snapshot): BuildIndexes
	local indexes: BuildIndexes = { tabs = {}, panes = {}, sessions = {}, agentsByPane = {} }
	for _, tab in ipairs(snapshot.tabs) do
		indexes.tabs[tab.id] = tab
	end
	for _, pane in ipairs(snapshot.panes) do
		indexes.panes[pane.pane] = pane
	end
	for _, session in ipairs(snapshot.sessions) do
		indexes.sessions[session.id] = session
	end
	for _, agent in snapshot.agents do
		if not indexes.agentsByPane[agent.pane] then
			indexes.agentsByPane[agent.pane] = agent
		end
	end
	return indexes
end

local function newBuildState(snapshot: Snapshot): BuildState
	return {
		snapshot = snapshot,
		indexes = buildIndexes(snapshot),
		projectsByKey = {},
		sessionByProject = {},
		seenAgent = {},
		seenTerminal = {},
		working = 0,
		waiting = 0,
		idle = 0,
		exited = 0,
		total = 0,
		terminalTotal = 0,
	}
end

local function projectFor(state: BuildState, host: number, rawPath: string): Project
	local path = normalizePath(rawPath)
	local key = tostring(host) .. ":" .. tostring(#path) .. ":" .. path
	local project = state.projectsByKey[key]
	if project == nil then
		project = {
			key = key,
			path = path,
			name = pathName(path),
			host = host,
			host_name = state.snapshot.hosts[host] or "",
			sessions = {},
		}
		state.projectsByKey[key] = project
		state.sessionByProject[key] = {}
	end
	return project
end

local function ensureSession(state: BuildState, project: Project, source: InputSession): Session
	local byId = state.sessionByProject[project.key] :: { [number]: Session }
	local row = byId[source.id]
	if row == nil then
		row = {
			id = source.id,
			name = source.name,
			current = source.current,
			locked = source.locked,
			pane = nil,
			agents = {},
			terminals = {},
		}
		byId[source.id] = row
		table.insert(project.sessions, row)
	end
	return row
end

local function panePath(state: BuildState, pane: InputPane, tab: InputTab?): string
	local agent = state.indexes.agentsByPane[pane.pane]
	if agent and nonempty(agent.cwd) then
		return normalizePath(agent.cwd)
	end
	if nonempty(pane.cwd) then
		return normalizePath(pane.cwd :: string)
	end
	if tab ~= nil and nonempty(tab.cwd) then
		return normalizePath(tab.cwd :: string)
	end
	return ""
end

local function collectPaneSessions(state: BuildState)
	for _, pane in ipairs(state.snapshot.panes) do
		if not state.snapshot.excluded[pane.pane] and pane.tab ~= nil then
			local tab = state.indexes.tabs[pane.tab]
			local session = if tab ~= nil then state.indexes.sessions[tab.session] else nil
			if tab ~= nil and session ~= nil then
				local project = projectFor(state, session.host, panePath(state, pane, tab))
				local row = ensureSession(state, project, session)
				if row.pane == nil or pane.pane < (row.pane :: number) then
					row.pane = pane.pane
				end
			end
		end
	end
end

local function collectUnassignedSessions(state: BuildState)
	for _, source in ipairs(state.snapshot.sessions) do
		local found = false
		for _, project in pairs(state.projectsByKey) do
			if (state.sessionByProject[project.key] :: { [number]: Session })[source.id] ~= nil then
				found = true
				break
			end
		end
		if not found then
			ensureSession(state, projectFor(state, source.host, ""), source)
		end
	end
end

local function addAgent(
	state: BuildState,
	source: InputAgent,
	pane: InputPane,
	inputSession: InputSession,
	tab: InputTab
)
	local agentPath = if nonempty(source.cwd) then normalizePath(source.cwd) else panePath(state, pane, tab)
	local project = projectFor(state, inputSession.host, agentPath)
	local session = ensureSession(state, project, inputSession)
	if session.pane == nil or source.pane < (session.pane :: number) then
		session.pane = source.pane
	end
	local agent: Agent = {
		pane = source.pane,
		session = inputSession.id,
		title = pane.title,
		cwd = agentPath,
		state = source.state,
		last_message = if type(source.last_message) == "string" then source.last_message else nil,
		model = if type(source.model) == "string" then source.model else nil,
	}
	table.insert(session.agents, agent)
	state.total += 1
	if source.state == "working" then
		state.working += 1
	elseif source.state == "waiting_input" then
		state.waiting += 1
	elseif source.state == "idle" then
		state.idle += 1
	elseif source.state == "exited" then
		state.exited += 1
	end
end

local function collectAgents(state: BuildState)
	for _, source in ipairs(state.snapshot.agents) do
		if not state.seenAgent[source.pane] and not state.snapshot.excluded[source.pane] then
			local pane = state.indexes.panes[source.pane]
			local tab = if pane ~= nil and pane.tab ~= nil then state.indexes.tabs[pane.tab] else nil
			local inputSession = if tab ~= nil then state.indexes.sessions[tab.session] else nil
			if pane ~= nil and tab ~= nil and inputSession ~= nil then
				state.seenAgent[source.pane] = true
				addAgent(state, source, pane, inputSession, tab)
			end
		end
	end
end

local function terminalState(pane: InputPane): "running" | "ready" | "exited" | "open"
	if pane.exited ~= nil then
		return "exited"
	elseif pane.busy == true or pane.running ~= nil then
		return "running"
	elseif pane.at_prompt == true then
		return "ready"
	end
	return "open"
end

local function addTerminal(state: BuildState, pane: InputPane, inputSession: InputSession, tab: InputTab)
	local terminalPath = panePath(state, pane, tab)
	local project = projectFor(state, inputSession.host, terminalPath)
	local session = ensureSession(state, project, inputSession)
	local running = pane.running
	local terminal: Terminal = {
		pane = pane.pane,
		session = inputSession.id,
		title = pane.title,
		cwd = terminalPath,
		program = if type(pane.program) == "string" then pane.program else nil,
		command = if running ~= nil
				and type(running.line) == "string"
				and running.line ~= ""
			then running.line
			else nil,
		state = terminalState(pane),
		exit_status = pane.exited,
	}
	table.insert(session.terminals, terminal)
	state.terminalTotal += 1
end

local function collectTerminals(state: BuildState)
	for _, pane in ipairs(state.snapshot.panes) do
		if
			pane.kind == "terminal"
			and not state.seenTerminal[pane.pane]
			and not state.indexes.agentsByPane[pane.pane]
			and not state.snapshot.excluded[pane.pane]
			and pane.tab ~= nil
		then
			local tab = state.indexes.tabs[pane.tab]
			local inputSession = if tab ~= nil then state.indexes.sessions[tab.session] else nil
			if tab ~= nil and inputSession ~= nil then
				state.seenTerminal[pane.pane] = true
				addTerminal(state, pane, inputSession, tab)
			end
		end
	end
end

local function sortProjects(state: BuildState): { Project }
	local projects: { Project } = {}
	for _, project in pairs(state.projectsByKey) do
		for _, session in ipairs(project.sessions) do
			table.sort(session.agents, agentLess)
			table.sort(session.terminals, function(a, b)
				return a.pane < b.pane
			end)
		end
		table.sort(project.sessions, sessionLess)
		table.insert(projects, project)
	end
	table.sort(projects, projectLess)
	return projects
end

function Model.build(snapshot: Snapshot): Board
	local state = newBuildState(snapshot)
	collectPaneSessions(state)
	collectUnassignedSessions(state)
	collectAgents(state)
	collectTerminals(state)
	return {
		projects = sortProjects(state),
		working = state.working,
		waiting = state.waiting,
		idle = state.idle,
		exited = state.exited,
		total = state.total,
		terminalTotal = state.terminalTotal,
	}
end

local FIELD_SEPARATOR = "\31"

local function row(...: any): string
	local values = table.pack(...)
	for index = 1, values.n do
		values[index] = tostring(values[index])
	end
	return table.concat(values, FIELD_SEPARATOR, 1, values.n)
end

local function sortedKeys(map: { [number]: any }): { number }
	local keys: { number } = {}
	for key in map do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

-- A string that changes exactly when the snapshot could change what `Model.build` and the view produce. It costs
-- far less than building the board, so callers can skip rebuilding an unchanged view. A running command's elapsed
-- time is left out on purpose: it changes every second and is never drawn.
function Model.fingerprint(snapshot: Snapshot): string
	local parts: { string } = {}
	for _, session in snapshot.sessions do
		table.insert(parts, row("s", session.id, session.name, session.host, session.current, session.locked))
	end
	for _, tab in snapshot.tabs do
		table.insert(parts, row("t", tab.id, tab.session, tab.pane, tab.cwd))
	end
	for _, pane in snapshot.panes do
		local running = pane.running
		table.insert(
			parts,
			row(
				"p",
				pane.pane,
				pane.tab,
				pane.cwd,
				pane.title,
				pane.kind,
				pane.program,
				pane.busy,
				pane.at_prompt,
				running and running.line,
				pane.exited
			)
		)
	end
	for _, agent in snapshot.agents do
		table.insert(parts, row("a", agent.pane, agent.cwd, agent.state, agent.last_message, agent.model))
	end
	for _, id in sortedKeys(snapshot.hosts) do
		table.insert(parts, row("h", id, snapshot.hosts[id]))
	end
	for _, pane in sortedKeys(snapshot.excluded) do
		table.insert(parts, row("x", pane))
	end
	return table.concat(parts, "\n")
end
function Model.waiting(board: Board): { Agent }
	local result: { Agent } = {}
	local seen: { [number]: boolean } = {}
	for _, project in ipairs(board.projects) do
		for _, session in ipairs(project.sessions) do
			for _, agent in ipairs(session.agents) do
				if agent.state == "waiting_input" and not seen[agent.pane] then
					seen[agent.pane] = true
					table.insert(result, agent)
				end
			end
		end
	end
	table.sort(result, function(a, b)
		return a.pane < b.pane
	end)
	return result
end

function Model.nextWaiting(board: Board, current: number?): Agent?
	local waiting = Model.waiting(board)
	if #waiting == 0 then
		return nil
	end
	for index, agent in ipairs(waiting) do
		if agent.pane == current then
			return waiting[index % #waiting + 1]
		end
	end
	return waiting[1]
end

function Model.hasAgents(project: Project): boolean
	for _, session in ipairs(project.sessions) do
		if #session.agents > 0 then
			return true
		end
	end
	return false
end

function Model.previousAgent(history: { number }, current: number?, available: { [number]: boolean }): number?
	for index = #history, 1, -1 do
		local pane = history[index]
		if pane ~= current and available[pane] then
			return pane
		end
	end
	return nil
end

return Model
