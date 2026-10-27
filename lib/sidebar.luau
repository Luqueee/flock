--!strict

local Model = require("./model")
local View = require("./view")
local Snapshot = require("./snapshot")

local Sidebar = {}
local TITLE = "Flock"
local ABOUT =
	"Organiza proyectos y agentes, abre omp y terminales nativos y navega entre sus paneles. No envía prompts ni sustituye la interfaz de omp."
local PANEL_SHARE = 0.26
local SLOW_UPDATE_MS = 25
local SLOW_WARNING_INTERVAL_MS = 60000

export type State = {
	enabled: boolean,
	onlyAgents: boolean,
	projectMenu: string?,
	closeConfirm: string?,
	closePane: number?,
	collapsed: { [string]: boolean },
	agentHistory: { number },
	pending: boolean,
	reconciling: boolean,
	lastContent: { [number]: number },
	drawn: { [number]: string },
	inputs: { [number]: string },
	warned: boolean,
	lastSlowWarning: number?,
}

function Sidebar.new(): State
	return {
		enabled = tern.kv.get("enabled") == true,
		onlyAgents = tern.kv.get("only_agents") == true,
		projectMenu = nil,
		closeConfirm = nil,
		closePane = nil,
		collapsed = {},
		agentHistory = {},
		pending = false,
		reconciling = false,
		lastContent = {},
		drawn = {},
		inputs = {},
		warned = false,
		lastSlowWarning = nil,
	}
end

local function firstContent(tree: TabTree, excluded: { [number]: boolean }): number?
	if tree.pane then
		return if excluded[tree.pane] then nil else tree.pane
	end
	for _, child in tree do
		if type(child) == "table" then
			local pane = firstContent(child, excluded)
			if pane then
				return pane
			end
		end
	end
	return nil
end

function Sidebar.recordAgent(state: State, cx: WindowCx, pane: number)
	if state.agentHistory[#state.agentHistory] == pane then
		return
	end
	for _, agent in cx.agents:list() do
		if agent.pane == pane then
			table.insert(state.agentHistory, pane)
			if #state.agentHistory > 64 then
				table.remove(state.agentHistory, 1)
			end
			return
		end
	end
end

function Sidebar.remember(state: State, cx: WindowCx, excluded: { [number]: boolean })
	local pane = cx.session:focused()
	if pane and not excluded[pane] then
		local tab = cx.session:tab_of(pane)
		if tab then
			state.lastContent[tab] = pane
			Sidebar.recordAgent(state, cx, pane)
		end
	end
end

function Sidebar.sizePanel(cx: WindowCx, panel: number, tab: number)
	local layout = cx.session:layout(tab)
	if not layout or layout.root.split ~= "right" or not layout.root[1] or layout.root[1].pane ~= panel then
		return
	end
	local before = layout.root.ratio or 0.5
	if not cx.layout:resize(panel, "right", 1) then
		return
	end
	local afterLayout = cx.session:layout(tab)
	local after = afterLayout and afterLayout.root.ratio
	cx.layout:resize(panel, "right", -1)
	if after and after ~= before then
		cx.layout:resize(panel, "right", math.floor((PANEL_SHARE - before) / math.abs(after - before) + 0.5))
	end
end

-- Panes of this plugin's canvases that sit in `tab`, lowest id first.
local function panelsIn(cx: WindowCx, excluded: { [number]: boolean }, tab: number): { number }
	local panels: { number } = {}
	for pane in excluded do
		if cx.session:tab_of(pane) == tab then
			table.insert(panels, pane)
		end
	end
	table.sort(panels)
	return panels
end

-- The content pane the panel sits beside: the last one used in the tab, else its first non-panel leaf.
local function anchorFor(
	state: State,
	cx: WindowCx,
	excluded: { [number]: boolean },
	tab: number,
	layout: TabLayout
): number?
	local anchor = state.lastContent[tab]
	if not anchor or excluded[anchor] or cx.session:tab_of(anchor) ~= tab then
		return firstContent(layout.root, excluded)
	end
	return anchor
end

-- Closes `panels` from index `from` on. Used both to drop duplicates and to never leave a lone panel in a tab.
local function closePanels(state: State, cx: WindowCx, panels: { number }, from: number)
	for index = from, #panels do
		cx.layout:close(panels[index])
		state.drawn[panels[index]] = nil
		state.inputs[panels[index]] = nil
	end
end

local function openPanel(cx: WindowCx, tab: number, anchor: number, view: any, dock: any): number
	local created, failure = cx.canvas:open({
		title = TITLE,
		about = ABOUT,
		view = view,
		dock = dock,
		how = "beside",
		focus = false,
	})
	if not created then
		error(failure or "Este host no permite paneles canvas")
	end
	cx.layout:move(created, anchor, "left", { focus = false })
	-- Sized once, here: later refreshes must not undo a divider the user dragged.
	Sidebar.sizePanel(cx, created, tab)
	return created
end

-- Draws the board into the tab's panel, creating it if needed. Nothing is rebuilt when the inputs are unchanged, and
-- the canvas is only touched when the drawn tree differs: both keep the 1 s refresh well inside Tern's 50 ms budget.
local function render(
	state: State,
	cx: WindowCx,
	tab: number,
	anchor: number,
	panels: { number },
	excluded: { [number]: boolean }
)
	Sidebar.recordAgent(state, cx, anchor)
	local snapshot = Snapshot.take(cx, excluded)
	local options: View.Options = {
		onlyAgents = state.onlyAgents,
		projectMenu = state.projectMenu,
		closeConfirm = state.closeConfirm,
		closePane = state.closePane,
		collapsed = state.collapsed,
	}
	local collapsedKeys: { string } = {}
	for key in state.collapsed do
		table.insert(collapsedKeys, key)
	end
	table.sort(collapsedKeys)
	local inputs = table.concat({
		Model.fingerprint(snapshot),
		tostring(anchor),
		tostring(options.onlyAgents),
		tostring(options.projectMenu),
		tostring(options.closeConfirm),
		tostring(options.closePane),
		table.concat(collapsedKeys, "\0"),
	}, "\n")
	local panel = panels[1]
	if panel and state.inputs[panel] == inputs then
		return
	end
	local view = View.build(Model.build(snapshot), anchor, options)
	local dock = View.dock(options)
	local signature = tern.json.encode({ view = view, dock = dock })
	local target: number
	if panel then
		target = panel
		if state.drawn[target] ~= signature then
			cx.canvas:set(target, { view = view, dock = dock })
		end
	else
		target = openPanel(cx, tab, anchor, view, dock)
	end
	state.drawn[target] = signature
	state.inputs[target] = inputs
end

local function reconcile(state: State, cx: WindowCx)
	local excluded = Snapshot.owned(cx)
	Sidebar.remember(state, cx, excluded)
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	local layout = tab and cx.session:layout(tab)
	if not tab or not layout then
		return
	end
	local panels = panelsIn(cx, excluded, tab)
	local anchor = anchorFor(state, cx, excluded, tab, layout)
	if not anchor then
		-- A panel must never be the only thing keeping a tab alive.
		closePanels(state, cx, panels, 1)
		return
	end
	state.lastContent[tab] = anchor
	render(state, cx, tab, anchor, panels, excluded)
	-- Windows or reloads racing each other can leave several panels in one tab; keep the first.
	closePanels(state, cx, panels, 2)
	state.warned = false
end

-- Window handlers are disabled by Tern after 50 ms, so say so early instead of failing silently.
local function warnIfSlow(state: State, cx: WindowCx, started: number)
	local elapsed = tern.now() - started
	if elapsed <= SLOW_UPDATE_MS then
		return
	end
	local last = state.lastSlowWarning
	if last == nil or started - last >= SLOW_WARNING_INTERVAL_MS then
		state.lastSlowWarning = started
		tern.log.warn(
			"flock: update took " .. string.format("%.0f", elapsed) .. " ms with " .. #cx.session:panes() .. " panes"
		)
	end
end

function Sidebar.update(state: State, cx: WindowCx)
	local started = tern.now()
	-- Another window may have changed these, so read them again on every update.
	state.enabled = tern.kv.get("enabled") == true
	state.onlyAgents = tern.kv.get("only_agents") == true
	if state.reconciling or not state.enabled then
		return
	end
	state.reconciling = true
	xpcall(function()
		reconcile(state, cx)
	end, function(err)
		if not state.warned then
			state.warned = true
			tern.log.error("No se pudo actualizar la sidebar", err)
			cx:toast("error", "No se pudo actualizar Flock", tostring(err))
		end
	end)
	state.reconciling = false
	warnIfSlow(state, cx, started)
end

function Sidebar.schedule(state: State)
	if state.pending or not state.enabled then
		return
	end
	state.pending = true
	tern.timer(120, function(cx)
		state.pending = false
		if cx then
			Sidebar.update(state, cx)
		end
	end)
end

function Sidebar.hide(state: State, cx: WindowCx)
	local panels = Snapshot.owned(cx)
	local session = cx.sessions:current().id
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	local back = if focused and not panels[focused] then focused else (tab and state.lastContent[tab])
	state.enabled = false
	tern.kv.set("enabled", false)
	for pane in panels do
		cx.layout:close(pane)
	end
	table.clear(state.drawn)
	table.clear(state.inputs)
	cx.sessions:switch(session)
	if back and cx.session:pane(back) then
		cx.layout:focus(back)
	end
end

function Sidebar.show(state: State, cx: WindowCx)
	state.enabled = true
	tern.kv.set("enabled", true)
	Sidebar.update(state, cx)
end

function Sidebar.focusedContent(state: State, cx: WindowCx): number?
	local pane = cx.session:focused()
	if pane and Snapshot.owned(cx)[pane] then
		local tab = cx.session:tab_of(pane)
		return if tab then state.lastContent[tab] else nil
	end
	return pane
end

function Sidebar.toggleFilter(state: State, cx: WindowCx)
	state.onlyAgents = not (tern.kv.get("only_agents") == true)
	tern.kv.set("only_agents", state.onlyAgents)
	state.projectMenu = nil
	Sidebar.update(state, cx)
end

function Sidebar.toggleProjectMenu(state: State, value: string?)
	state.projectMenu = if state.projectMenu == value then nil else value
end

function Sidebar.cancelProjectMenu(state: State)
	state.projectMenu = nil
	state.closeConfirm = nil
	state.closePane = nil
end

function Sidebar.toggleProject(state: State, key: string?)
	if key ~= nil then
		if state.collapsed[key] then
			state.collapsed[key] = nil
		else
			state.collapsed[key] = true
		end
	end
end

function Sidebar.askClose(state: State, key: string?)
	state.closeConfirm = if state.closeConfirm == key then nil else key
	state.closePane = nil
	state.projectMenu = nil
end

function Sidebar.askClosePane(state: State, value: string?)
	local pane = value and tonumber(value)
	state.closePane = if state.closePane == pane then nil else pane
	state.closeConfirm = nil
	state.projectMenu = nil
end

function Sidebar.cancelClose(state: State)
	state.closeConfirm = nil
	state.closePane = nil
end

return Sidebar
