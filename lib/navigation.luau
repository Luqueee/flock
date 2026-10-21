--!strict

local Model = require("./model")
local Snapshot = require("./snapshot")
local Sidebar = require("./sidebar")
type State = Sidebar.State
local Navigation = {}

function Navigation.focusPane(state: State, cx: WindowCx, value: string?)
	local id = value and tonumber(value)
	if not id then
		return
	end
	local pane = cx.session:pane(id)
	local tab = pane and pane.tab
	if tab and not Snapshot.owned(cx)[id] then
		for _, row in cx.session:tabs() do
			if row.id == tab then
				cx.sessions:switch(row.session)
				cx.layout:focus(id)
				Sidebar.remember(state, cx, Snapshot.owned(cx))
				Sidebar.schedule(state)
				return
			end
		end
	end
	cx:toast("info", "Ese panel ya no está disponible")
	Sidebar.schedule(state)
end

-- Switches to a session by id: the click target of a session that has no pane to focus.
function Navigation.focusSession(state: State, cx: WindowCx, value: string?)
	local id = value and tonumber(value)
	if not id then
		return
	end
	for _, session in cx.sessions:list() do
		if session.id == id then
			cx.sessions:switch(id)
			Sidebar.schedule(state)
			return
		end
	end
	cx:toast("info", "Esa sesión ya no está disponible")
	Sidebar.schedule(state)
end
function Navigation.nextWaiting(state: State, cx: WindowCx)
	local board = Snapshot.board(cx)
	local agent = Model.nextWaiting(board, Sidebar.focusedContent(state, cx))
	if agent then
		Navigation.focusPane(state, cx, tostring(agent.pane))
	else
		cx:toast("info", "No hay agentes esperando respuesta")
	end
end
function Navigation.previousAgent(state: State, cx: WindowCx)
	local available: { [number]: boolean } = {}
	local board = Snapshot.board(cx)
	for _, project in board.projects do
		for _, session in project.sessions do
			for _, agent in session.agents do
				available[agent.pane] = true
			end
		end
	end
	local pane = Model.previousAgent(state.agentHistory, Sidebar.focusedContent(state, cx), available)
	if pane then
		Navigation.focusPane(state, cx, tostring(pane))
	else
		cx:toast("info", "Todavía no hay otro agente visitado")
	end
end

return Navigation
