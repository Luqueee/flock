--!strict

local Snapshot = require("./snapshot")
local Sidebar = require("./sidebar")

local Projects = {}
type State = Sidebar.State

function Projects.createInProject(state: State, cx: WindowCx, key: string?, command: string?)
	local board = Snapshot.board(cx)
	for _, project in board.projects do
		if project.key == key then
			if project.path == "" then
				cx:toast("error", "El proyecto no tiene un directorio conocido")
				return
			end
			local target = project.sessions[1]
			for _, session in project.sessions do
				if session.current then
					target = session
					break
				end
			end
			if not target then
				cx:toast("info", "La sesión del proyecto ya no está disponible")
				return
			end
			cx.sessions:switch(target.id)
			local pane = cx.layout:new_tab({ cwd = project.path, command = command })
			Sidebar.cancelProjectMenu(state)
			if not pane then
				cx:toast("error", "No se pudo abrir el panel en el proyecto")
			end
			Sidebar.schedule(state)
			return
		end
	end
	Sidebar.cancelProjectMenu(state)
	cx:toast("info", "Ese proyecto ya no está disponible")
	Sidebar.update(state, cx)
end

return Projects
