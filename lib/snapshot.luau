--!strict

local Model = require("./model")
local Pins = require("./pins")

local Snapshot = {}
local OWNER = tern.plugin.id

function Snapshot.owned(cx: WindowCx): { [number]: boolean }
	local result: { [number]: boolean } = {}
	for _, canvas in cx.canvas:list() do
		if canvas.owner == OWNER then
			result[canvas.pane] = true
		end
	end
	return result
end

function Snapshot.take(cx: WindowCx, excluded: { [number]: boolean }): Model.Snapshot
	local hosts: { [number]: string } = {}
	for _, host in cx.hosts:list() do
		hosts[host.id] = host.name
	end
	local sessions: { Model.InputSession } = {}
	for _, session in cx.sessions:list() do
		table.insert(sessions, {
			id = session.id,
			name = session.name,
			host = session.host,
			current = session.current,
			locked = session.locked,
		})
	end
	local tabs: { Model.InputTab } = {}
	for _, tab in cx.session:tabs() do
		table.insert(tabs, { id = tab.id, session = tab.session, pane = tab.pane, cwd = tab.cwd })
	end
	local panes: { Model.InputPane } = {}
	for _, source in cx.session:panes() do
		local pane: Model.InputPane = {
			pane = source.pane,
			tab = source.tab,
			cwd = source.cwd,
			title = source.title,
			kind = source.kind,
			program = source.program,
			busy = source.busy,
			at_prompt = source.at_prompt,
			running = source.running,
			exited = source.exited,
		}
		table.insert(panes, pane)
	end
	local agents: { Model.InputAgent } = {}
	for _, source in cx.agents:list() do
		local agent: Model.InputAgent = {
			pane = source.pane,
			cwd = source.cwd,
			state = source.state,
			last_message = source.last_message,
			model = source.model,
		}
		table.insert(agents, agent)
	end
	return {
		sessions = sessions,
		tabs = tabs,
		panes = panes,
		agents = agents,
		hosts = hosts,
		excluded = excluded,
		pinned = Pins.panePaths(cx),
	}
end

-- The board for the current window state, excluding this plugin's own panels.
function Snapshot.board(cx: WindowCx): Model.Board
	return Model.build(Snapshot.take(cx, Snapshot.owned(cx)))
end

return Snapshot
