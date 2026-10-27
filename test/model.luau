--!strict

local Model = require("../lib/model")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

local function blank(): Model.Snapshot
	return { sessions = {}, tabs = {}, panes = {}, agents = {}, hosts = {}, excluded = {} }
end

local function add(s: Model.Snapshot, pane: number, session: number, host: number, cwd: string, state: string?)
	local present = false
	for _, row in s.sessions do
		if row.id == session then
			present = true
		end
	end
	if not present then
		table.insert(
			s.sessions,
			{ id = session, name = "Session " .. session, host = host, current = false, locked = false }
		)
	end
	table.insert(s.tabs, { id = pane, session = session, pane = pane, cwd = cwd })
	table.insert(s.panes, { pane = pane, tab = pane, cwd = cwd, title = "Agent " .. pane })
	if state then
		table.insert(s.agents, { pane = pane, cwd = cwd, state = state, last_message = nil, model = nil })
	end
end

local function project(board: Model.Board, host: number, path: string): Model.Project
	for _, row in board.projects do
		if row.host == host and row.path == path then
			return row
		end
	end
	error("Missing project " .. host .. ":" .. path)
end

-- Same basename and same directory on different hosts must never merge navigation targets.
local distinct = blank()
add(distinct, 1, 11, 1, "/work/app", "idle")
add(distinct, 2, 12, 1, "/other/app", "working")
add(distinct, 3, 13, 2, "/work/app", "waiting_input")
local board = Model.build(distinct)
check(#board.projects == 3, "different full paths/hosts must remain separate projects")
check(project(board, 1, "/work/app").sessions[1].agents[1].pane == 1, "local project must target local pane")
check(project(board, 2, "/work/app").sessions[1].agents[1].pane == 3, "remote project must target remote pane")
check(
	project(board, 1, "/work/app").key ~= project(board, 2, "/work/app").key,
	"remote and local project identity must differ"
)

-- One project can contain several sessions, and one session can span several directories.
local spanning = blank()
add(spanning, 1, 10, 1, "/a/", "idle")
add(spanning, 2, 20, 1, "/a", "working")
add(spanning, 3, 10, 1, "/b", "waiting_input")
board = Model.build(spanning)
check(#project(board, 1, "/a").sessions == 2, "same project must include both sessions")
check(project(board, 1, "/b").sessions[1].id == 10, "session must also appear in its second project")
check(project(board, 1, "/b").sessions[1].agents[1].pane == 3, "second directory must not target first session pane")

-- Native agent cwd wins without leaving an empty ghost of its old pane directory.
spanning.agents[3].cwd = "/moved"
board = Model.build(spanning)
check(#board.projects == 2, "moving an agent directory must replace, not duplicate, its project")
check(project(board, 1, "/moved").sessions[1].pane == 3, "session anchor must follow agent directory")

-- Waiting agents precede working and idle agents. Duplicate/native-null metadata cannot corrupt counts.
local states = blank()
for i, state in { "idle", "working", "waiting_input", "exited", "unrecognized" } do
	add(states, i, 1, 1, "/app", state)
end
states.agents[3].model = false
states.agents[3].last_message = {}
table.insert(states.agents, { pane = 3, cwd = "/app", state = "idle", last_message = nil, model = nil })
board = Model.build(states)
local agents = project(board, 1, "/app").sessions[1].agents
check(
	agents[1].pane == 3 and agents[2].pane == 2 and agents[3].pane == 1,
	"attention order must follow native agent state"
)
check(
	board.total == 5 and board.waiting == 1 and board.working == 1 and board.idle == 1 and board.exited == 1,
	"duplicate/unknown agents must not inflate state counts"
)
check(
	agents[1].model == nil and agents[1].last_message == nil,
	"non-string native null metadata must not enter the view"
)
check(agents[5].state == "unrecognized", "unknown native state must not become idle")

-- Own sidebars and orphan/parked agents must not become selectable agents in arbitrary sessions.
local missing = blank()
add(missing, 1, 1, 1, "/app", "working")
add(missing, 2, 2, 1, "/app", "idle")
missing.excluded[1] = true
missing.panes[2].tab = nil
table.insert(missing.agents, { pane = 999, cwd = "/app", state = "working", last_message = nil, model = nil })
board = Model.build(missing)
check(board.total == 0, "unmapped and excluded panes must not create focusable agent rows")
local emptySession = project(board, 1, "").sessions[1]
check(
	emptySession.pane == nil and #emptySession.agents == 0 and #emptySession.terminals == 0,
	"empty session must remain navigable with empty agent/terminal lists"
)

-- Directory boundaries: normalize Windows separators and roots, but not POSIX backslash filenames.
local paths = blank()
add(paths, 1, 1, 1, "/", "idle")
add(paths, 2, 2, 1, "/app\\name/", "idle")
add(paths, 3, 3, 2, "C:\\", "idle")
add(paths, 4, 4, 2, "\\\\server\\share\\", "idle")
board = Model.build(paths)
check(project(board, 1, "/").sessions[1].agents[1].pane == 1, "POSIX root must not become unknown directory")
check(
	project(board, 1, "/app\\name").sessions[1].agents[1].pane == 2,
	"POSIX backslash filename must not become nested directories"
)
check(project(board, 2, "C:/").sessions[1].agents[1].pane == 3, "Windows drive root must retain slash")

-- Waiting navigation is globally pane-sorted, deduplicated, and wraps only from a waiting current pane.
local waitingSnapshot = blank()
add(waitingSnapshot, 8, 8, 1, "/app", "waiting_input")
add(waitingSnapshot, 5, 5, 1, "/app", "idle")
add(waitingSnapshot, 2, 2, 1, "/app", "waiting_input")
local waitingBoard = Model.build(waitingSnapshot)
local waitingAgents = Model.waiting(waitingBoard)
check(
	#waitingAgents == 2 and waitingAgents[1].pane == 2 and waitingAgents[2].pane == 8,
	"waiting agents must be unique and sorted by pane"
)
check(Model.nextWaiting(waitingBoard, 8) == waitingAgents[1], "next waiting must wrap from the last waiting pane")
check(Model.nextWaiting(waitingBoard, 2) == waitingAgents[2], "next waiting must advance from a waiting pane")
check(
	Model.nextWaiting(waitingBoard, 5) == waitingAgents[1],
	"non-waiting current pane must select the first waiting pane"
)
check(
	Model.nextWaiting(waitingBoard, nil) == waitingAgents[1],
	"missing current pane must select the first waiting pane"
)
local emptyWaiting = Model.build(blank())
check(
	#Model.waiting(emptyWaiting) == 0 and Model.nextWaiting(emptyWaiting, nil) == nil,
	"empty waiting list must return no next agent"
)
local duplicateWaiting: Model.Agent =
	{ pane = 7, session = 1, title = "Agent 7", cwd = "/app", state = "waiting_input", last_message = nil, model = nil }
local earlierWaiting: Model.Agent =
	{ pane = 2, session = 2, title = "Agent 2", cwd = "/app", state = "waiting_input", last_message = nil, model = nil }
local duplicateProject: Model.Project = {
	key = "test",
	path = "/app",
	name = "app",
	host = 1,
	host_name = "",
	sessions = {
		{
			id = 1,
			name = "one",
			current = false,
			locked = false,
			pane = 7,
			agents = { duplicateWaiting },
			terminals = {},
		},
		{
			id = 2,
			name = "two",
			current = false,
			locked = false,
			pane = 7,
			agents = { duplicateWaiting, earlierWaiting },
			terminals = {},
		},
	},
}
local duplicateBoard: Model.Board =
	{ projects = { duplicateProject }, working = 0, waiting = 3, idle = 0, exited = 0, total = 3, terminalTotal = 0 }
local deduplicated = Model.waiting(duplicateBoard)
check(
	#deduplicated == 2 and deduplicated[1] == earlierWaiting and deduplicated[2] == duplicateWaiting,
	"waiting agents must sort by pane and deduplicate across groups"
)
check(
	#duplicateProject.sessions[1].agents == 1
		and duplicateProject.sessions[2].agents[1].pane == 7
		and duplicateProject.sessions[2].agents[2].pane == 2,
	"waiting collection must not reorder or mutate board groups"
)

local emptyProject: Model.Project = {
	key = "empty",
	path = "",
	name = "",
	host = 1,
	host_name = "",
	sessions = {
		{ id = 1, name = "empty", current = false, locked = false, pane = nil, agents = {}, terminals = {} },
	},
}

-- Ordinary native terminals are grouped by the same host/path/session mapping, separately from agent filtering.
local terminalSnapshot = blank()
add(terminalSnapshot, 10, 1, 1, "/work/app", nil)
terminalSnapshot.panes[1].kind = "terminal"
terminalSnapshot.panes[1].title = "shell tab"
terminalSnapshot.panes[1].program = "zsh"
terminalSnapshot.panes[1].at_prompt = true
add(terminalSnapshot, 11, 1, 1, "/work/app", nil)
terminalSnapshot.panes[2].kind = "terminal"
terminalSnapshot.panes[2].cwd = "/other/path"
terminalSnapshot.panes[2].running = { line = "make test", ms = 40 }
terminalSnapshot.panes[2].program = "make"
add(terminalSnapshot, 12, 2, 1, "/work/app", nil)
terminalSnapshot.panes[3].kind = "terminal"
table.insert(
	terminalSnapshot.panes,
	{ pane = 10, tab = 10, cwd = "/work/app", title = "duplicate terminal", kind = "terminal" }
)
board = Model.build(terminalSnapshot)
local terminalProject = project(board, 1, "/work/app")
local terminalSession = terminalProject.sessions[1]
check(
	not Model.hasAgents(terminalProject) and board.total == 0 and board.terminalTotal == 3,
	"terminal-only projects must remain outside agent filtering and counts"
)
check(
	#terminalSession.terminals == 1 and terminalSession.terminals[1].pane == 10,
	"terminals must associate by pane project and session"
)
check(
	terminalSession.terminals[1].state == "ready",
	"prompt-ready terminals must not be classified as running or unknown"
)
check(terminalSession.terminals[1].cwd == "/work/app", "terminal cwd must use the mapped project path")
local otherTerminalSession = project(board, 1, "/other/path").sessions[1]
check(
	otherTerminalSession.id == 1
		and otherTerminalSession.terminals[1].pane == 11
		and otherTerminalSession.terminals[1].state == "running",
	"running terminal in another directory must remain associated with its original session"
)
check(
	project(board, 1, "/work/app").sessions[2].id == 2
		and project(board, 1, "/work/app").sessions[2].terminals[1].pane == 12,
	"one terminal session may group under multiple existing project paths"
)

-- A pinned terminal keeps its project and its name when its shell moves, and the fingerprint reacts to the pin.
local pinnedSnapshot = blank()
add(pinnedSnapshot, 20, 1, 1, "/work/app", nil)
pinnedSnapshot.panes[1].kind = "terminal"
pinnedSnapshot.panes[1].cwd = "/somewhere/else"
local unpinnedFingerprint = Model.fingerprint(pinnedSnapshot)
pinnedSnapshot.pinned = { [20] = "/work/app" }
board = Model.build(pinnedSnapshot)
local pinnedTerminal = project(board, 1, "/work/app").sessions[1].terminals[1]
check(#board.projects == 1, "a pinned terminal must not create a project for the directory it moved to")
check(
	pinnedTerminal.pinned == true and pinnedTerminal.title == "app" and pinnedTerminal.cwd == "/somewhere/else",
	"a pinned terminal must keep the project name as title and report its real directory"
)
check(Model.fingerprint(pinnedSnapshot) ~= unpinnedFingerprint, "pinning a terminal must change the fingerprint")

-- Only explicit ordinary terminal panes qualify; native agent metadata wins and pane ids are counted once.
local filteredTerminals = blank()
add(filteredTerminals, 1, 1, 1, "/app", "working")
filteredTerminals.panes[1].kind = "terminal"
add(filteredTerminals, 2, 1, 1, "/app", nil)
filteredTerminals.panes[2].kind = "canvas"
add(filteredTerminals, 3, 1, 1, "/app", nil)
filteredTerminals.panes[3].kind = "browser"
add(filteredTerminals, 4, 1, 1, "/app", nil)
filteredTerminals.panes[4].kind = "file"
add(filteredTerminals, 5, 1, 1, "/app", nil)
filteredTerminals.panes[5].kind = "unknown"
add(filteredTerminals, 6, 1, 1, "/app", nil)
filteredTerminals.panes[6].kind = "terminal"
filteredTerminals.panes[6].tab = nil
add(filteredTerminals, 7, 1, 1, "/app", nil)
filteredTerminals.panes[7].kind = "terminal"
filteredTerminals.excluded[7] = true
table.insert(filteredTerminals.panes, { pane = 8, tab = 999, cwd = "/app", title = "orphan", kind = "terminal" })
table.insert(filteredTerminals.panes, { pane = 1, tab = 1, cwd = "/app", title = "agent duplicate", kind = "terminal" })
board = Model.build(filteredTerminals)
local filteredSession = project(board, 1, "/app").sessions[1]
check(
	board.total == 1 and board.terminalTotal == 0 and #filteredSession.agents == 1 and #filteredSession.terminals == 0,
	"native agent panes, nonterminals, orphan/parked panes, and duplicates must not inflate terminal counts"
)

-- Terminal status precedence preserves exit code zero and sorts unique terminal ids numerically.
local function terminalState(source: Model.Board, pane: number): string?
	for _, p in source.projects do
		for _, s in p.sessions do
			for _, terminal in s.terminals do
				if terminal.pane == pane then
					return terminal.state
				end
			end
		end
	end
	return nil
end
local statuses = blank()
for _, paneId in { 9, 2, 5, 1 } do
	add(statuses, paneId, 1, 1, "/app", nil)
	statuses.panes[#statuses.panes].kind = "terminal"
end
statuses.panes[1].busy = true
statuses.panes[1].at_prompt = true
statuses.panes[1].running = { line = "sleep 1", ms = 1 }
statuses.panes[2].exited = 0
statuses.panes[2].busy = true
statuses.panes[2].at_prompt = true
statuses.panes[3].exited = 7
statuses.panes[3].running = { line = "false", ms = 1 }
statuses.panes[4].busy = true
statuses.panes[4].at_prompt = true
board = Model.build(statuses)
local statusTerminals = project(board, 1, "/app").sessions[1].terminals
check(
	#statusTerminals == 4
		and statusTerminals[1].pane == 1
		and statusTerminals[2].pane == 2
		and statusTerminals[3].pane == 5
		and statusTerminals[4].pane == 9,
	"terminal ids must be deduplicated and sorted"
)
check(
	statusTerminals[1].state == "running"
		and statusTerminals[2].state == "exited"
		and statusTerminals[2].exit_status == 0
		and statusTerminals[3].state == "exited"
		and statusTerminals[3].exit_status == 7,
	"exit state must outrank running and preserve zero/nonzero status"
)
check(statusTerminals[4].state == "running", "busy status must outrank prompt-ready")
statuses.panes[4].busy = nil
statuses.panes[4].at_prompt = true
statuses.panes[4].running = nil
board = Model.build(statuses)
check(terminalState(board, 1) == "ready", "prompt metadata must classify a nonbusy terminal ready")
statuses.panes[4].at_prompt = nil
board = Model.build(statuses)
check(terminalState(board, 1) == "open", "terminal without native activity metadata must remain open")
check(not Model.hasAgents(project(board, 1, "/app")), "terminal-only project must not pass the existing agents filter")

check(
	not Model.hasAgents(emptyProject) and Model.hasAgents(duplicateProject),
	"project agent filtering must distinguish empty and populated projects"
)

-- Previous-agent navigation ignores the focused pane and stale history without mutating history.
local history = { 1, 2, 3, 2, 4 }
local historyBefore = table.concat(history, ",")
local available = { [2] = true, [3] = true }
check(
	Model.previousAgent(history, 4, available) == 2,
	"previous agent must choose newest available history entry other than current"
)
check(
	Model.previousAgent(history, 2, available) == 3,
	"previous agent must skip current and choose the newest remaining available entry"
)
check(Model.previousAgent({ 1, 4 }, 4, available) == nil, "stale/current history entries must yield no previous agent")
check(Model.previousAgent(history, nil, {}) == nil, "history without available agents must yield no previous agent")
check(table.concat(history, ",") == historyBefore, "previous-agent lookup must not mutate focus history")

board = Model.build(paths)
check(project(board, 2, "//server/share/").sessions[1].agents[1].pane == 4, "UNC share root must retain identity")

-- The fingerprint lets the sidebar skip rebuilding: it must move with everything drawn, and only with that.
local printed = blank()
add(printed, 1, 1, 1, "/app", "idle")
printed.panes[1].running = { line = "make", ms = 10 }
printed.hosts[1] = "Local"
local baseline = Model.fingerprint(printed)
check(Model.fingerprint(printed) == baseline, "an unchanged snapshot must keep its fingerprint")
printed.panes[1].running = { line = "make", ms = 99999 }
check(Model.fingerprint(printed) == baseline, "a running command's elapsed time is never drawn and must not change it")

local function changes(mutate: () -> (), restore: () -> ()): boolean
	mutate()
	local differs = Model.fingerprint(printed) ~= baseline
	restore()
	return differs
end
check(
	changes(function()
		printed.agents[1].state = "working"
	end, function()
		printed.agents[1].state = "idle"
	end),
	"an agent state change must change the fingerprint"
)
check(
	changes(function()
		printed.panes[1].title = "renamed"
	end, function()
		printed.panes[1].title = "Agent 1"
	end),
	"a pane title change must change the fingerprint"
)
check(
	changes(function()
		printed.panes[1].running = { line = "make test", ms = 10 }
	end, function()
		printed.panes[1].running = { line = "make", ms = 10 }
	end),
	"a different running command must change the fingerprint"
)
check(
	changes(function()
		printed.hosts[1] = "Renamed"
	end, function()
		printed.hosts[1] = "Local"
	end),
	"a host rename must change the fingerprint"
)
check(
	changes(function()
		printed.excluded[1] = true
	end, function()
		printed.excluded[1] = nil
	end),
	"excluding a pane must change the fingerprint"
)
check(Model.fingerprint(printed) == baseline, "restoring every change must restore the fingerprint")

print("Model: " .. checks .. " checks passed")
