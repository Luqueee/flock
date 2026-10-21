--!strict

local Sidebar = require("./lib/sidebar")
local Navigation = require("./lib/navigation")
local Projects = require("./lib/projects")
local Editor = require("./lib/editor")
local Snapshot = require("./lib/snapshot")

local OWNER = tern.plugin.id
local POLL_MS = 1000
local state = Sidebar.new()

tern.command({
	id = "toggle",
	title = "Mostrar u ocultar sidebar",
	keys = { "ctrl+alt+shift+h" },
	run = function(cx)
		if tern.kv.get("enabled") == true then
			Sidebar.hide(state, cx)
		else
			Sidebar.show(state, cx)
		end
	end,
})
tern.command({
	id = "refresh",
	title = "Actualizar proyectos y agentes",
	run = function(cx)
		Sidebar.show(state, cx)
	end,
})
tern.command({
	id = "next_waiting",
	title = "Ir al siguiente agente en espera",
	keys = { "ctrl+alt+shift+j" },
	run = function(cx)
		Navigation.nextWaiting(state, cx)
	end,
})
tern.command({
	id = "last_agent",
	title = "Volver al último agente utilizado",
	keys = { "ctrl+alt+shift+l" },
	run = function(cx)
		Navigation.previousAgent(state, cx)
	end,
})
tern.command({
	id = "toggle_filter",
	title = "Filtrar proyectos con agentes",
	run = function(cx)
		Sidebar.toggleFilter(state, cx)
	end,
})
tern.command({
	id = "open_vscode",
	title = "Abrir el proyecto enfocado en VS Code",
	icon = "code",
	run = function(cx)
		Editor.openFocusedInVSCode(state, cx)
	end,
})

local actions: { [string]: (any, WindowCx) -> () } = {
	hide = function(_, cx)
		Sidebar.hide(state, cx)
	end,
	refresh = function(_, cx)
		Sidebar.update(state, cx)
	end,
	filter = function(_, cx)
		Sidebar.toggleFilter(state, cx)
	end,
	["next-waiting"] = function(_, cx)
		Navigation.nextWaiting(state, cx)
	end,
	["last-agent"] = function(_, cx)
		Navigation.previousAgent(state, cx)
	end,
	project = function(ev, cx)
		Sidebar.toggleProjectMenu(state, ev.value)
		Sidebar.update(state, cx)
	end,
	["cancel-project"] = function(_, cx)
		Sidebar.cancelProjectMenu(state)
		Sidebar.update(state, cx)
	end,
	["new-omp"] = function(ev, cx)
		Projects.createInProject(state, cx, ev.value, "omp")
	end,
	["new-terminal"] = function(ev, cx)
		Projects.createInProject(state, cx, ev.value, nil)
	end,
	["open-vscode"] = function(ev, cx)
		Editor.openProjectInVSCode(cx, ev.value)
	end,
	["agent-code"] = function(ev, cx)
		Editor.openAgentInVSCode(cx, ev.value)
	end,
	agent = function(ev, cx)
		Navigation.focusPane(state, cx, ev.value)
	end,
	pane = function(ev, cx)
		Navigation.focusPane(state, cx, ev.value)
	end,
	session = function(ev, cx)
		Navigation.focusSession(state, cx, ev.value)
	end,
}

tern.on("canvas_action", function(ev, cx)
	if ev.owner ~= OWNER then
		return false
	end
	local action = actions[ev.act]
	if not action then
		return false
	end
	action(ev, cx)
	return true
end)

tern.on("focus", function(ev, cx)
	if state.enabled and ev.pane == cx.session:focused() then
		local excluded = Snapshot.owned(cx)
		Sidebar.remember(state, cx, excluded)
		Sidebar.schedule(state)
	end
end)

for _, event in
	{
		"pane_created",
		"pane_closed",
		"tab_created",
		"tab_closed",
		"cwd",
		"title",
		"command_started",
		"command_finished",
	}
do
	tern.on(event, function(_ev, _cx)
		Sidebar.schedule(state)
	end)
end

tern.on("window_start", function(_cx)
	Sidebar.schedule(state)
end)

local function poll(cx: WindowCx?)
	if cx then
		Sidebar.update(state, cx)
	end
	tern.timer(POLL_MS, poll)
end
tern.timer(POLL_MS, poll)
Sidebar.schedule(state)
