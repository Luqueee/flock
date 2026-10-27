--!strict

local Snapshot = require("./snapshot")
local Sidebar = require("./sidebar")
local Navigation = require("./navigation")
local Pins = require("./pins")
local Model = require("./model")

local Projects = {}
type State = Sidebar.State

-- The session new panes of a project go to: its current one, else its first.
local function targetSession(project: Model.Project): Model.Session?
	local target = project.sessions[1]
	for _, session in project.sessions do
		if session.current then
			return session
		end
	end
	return target
end

local function findProject(board: Model.Board, key: string?): Model.Project?
	for _, project in board.projects do
		if project.key == key then
			return project
		end
	end
	return nil
end

function Projects.createInProject(state: State, cx: WindowCx, key: string?, command: string?)
	local project = findProject(Snapshot.board(cx), key)
	Sidebar.cancelProjectMenu(state)
	if not project then
		cx:toast("info", "Ese proyecto ya no está disponible")
		Sidebar.update(state, cx)
		return
	end
	if project.path == "" then
		cx:toast("error", "El proyecto no tiene un directorio conocido")
		return
	end
	local target = targetSession(project)
	if not target then
		cx:toast("info", "La sesión del proyecto ya no está disponible")
		return
	end
	cx.sessions:switch(target.id)
	if not cx.layout:new_tab({ cwd = project.path, command = command }) then
		cx:toast("error", "No se pudo abrir el panel en el proyecto")
	end
	Sidebar.schedule(state)
end

-- The project's own terminal. It is created once, remembered by project, and only focused afterwards; it keeps
-- its project and name when its shell changes directory. It is created again only if it was closed.
function Projects.openCategoryTerminal(state: State, cx: WindowCx, key: string?)
	local project = findProject(Snapshot.board(cx), key)
	Sidebar.cancelProjectMenu(state)
	if not project then
		cx:toast("info", "Ese proyecto ya no está disponible")
		Sidebar.update(state, cx)
		return
	end
	local existing = Pins.paneFor(cx, project.key)
	if existing then
		Navigation.focusPane(state, cx, tostring(existing))
		return
	end
	local target = targetSession(project)
	if not target then
		cx:toast("info", "La sesión del proyecto ya no está disponible")
		return
	end
	cx.sessions:switch(target.id)
	local pane = cx.layout:new_tab({ cwd = if project.path == "" then nil else project.path })
	if pane then
		Pins.set(cx, project.key, pane, project.path)
	else
		cx:toast("error", "No se pudo abrir la terminal del proyecto")
	end
	Sidebar.schedule(state)
end

-- A workspace is a Tern session; the new one starts with a plain terminal and is shown immediately.
function Projects.createWorkspace(state: State, cx: WindowCx)
	local ok, failure = pcall(function()
		cx.sessions:create()
	end)
	if not ok then
		cx:toast("error", "No se pudo crear el workspace", tostring(failure))
	end
	Sidebar.schedule(state)
end

-- Closing a project ends every session grouped under it; a locked one blocks it before anything is closed.
function Projects.closeProject(state: State, cx: WindowCx, key: string?)
	Sidebar.cancelClose(state)
	local board = Snapshot.board(cx)
	for _, project in board.projects do
		if project.key == key then
			for _, session in project.sessions do
				if session.locked then
					cx:toast(
						"error",
						"El workspace «" .. session.name .. "» está bloqueado",
						"Desbloquéalo para cerrarlo"
					)
					Sidebar.update(state, cx)
					return
				end
			end
			for _, session in project.sessions do
				local ok, failure = pcall(function()
					cx.sessions:close(session.id)
				end)
				if not ok then
					cx:toast("error", "No se pudo cerrar «" .. session.name .. "»", tostring(failure))
					break
				end
			end
			state.collapsed[project.key] = nil
			Sidebar.schedule(state)
			return
		end
	end
	cx:toast("info", "Ese proyecto ya no está disponible")
	Sidebar.update(state, cx)
end

-- Closes one terminal or agent pane. Flock's own panels are never closed from here.
function Projects.closePane(state: State, cx: WindowCx, value: string?)
	Sidebar.cancelClose(state)
	local id = value and tonumber(value)
	if id and cx.session:pane(id) and not Snapshot.owned(cx)[id] then
		local ok, failure = pcall(function()
			cx.layout:close(id)
		end)
		if not ok then
			cx:toast("error", "No se pudo cerrar el panel", tostring(failure))
		end
		Sidebar.schedule(state)
		return
	end
	cx:toast("info", "Ese panel ya no está disponible")
	Sidebar.update(state, cx)
end

return Projects
