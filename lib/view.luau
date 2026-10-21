--!strict

local Model = require("./model")
local ui = tern.ui

type Node = { k: string, p: { [string]: any }?, c: { Node }? }
type Agent = Model.Agent
type Terminal = Model.Terminal
type Session = Model.Session
type Project = Model.Project

local View = {}
local function role(name: string): string
	return "flock." .. name
end

local MAX_PROJECTS = 30
local MAX_SESSIONS = 40
local MAX_AGENTS = 40
local MAX_TERMINALS = 40
local MAX_WAITING = 12
local MAX_TITLE = 120
local MAX_MODEL = 80
local MAX_MESSAGE = 160
local MAX_VIEW_BYTES = 190 * 1024

export type Options = { onlyAgents: boolean, projectMenu: string? }

local function bounded(value: string, limit: number): string
	if #value <= limit then
		return value
	end
	local boundary = utf8.offset(value, 0, limit)
	return string.sub(value, 1, (boundary or limit) - 1) .. "…"
end

local function withProps(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for key, value in props do
		p[key] = value
	end
	node.p = p
	return node
end

local function nativeState(state: string): (string, string)
	if state == "working" then
		return "Trabajando", "accent"
	elseif state == "waiting_input" then
		return "Espera respuesta", "warning"
	elseif state == "idle" then
		return "Inactivo", "muted"
	elseif state == "exited" then
		return "Finalizado", "success"
	end
	return "Desconocido", "neutral"
end

local function compactPath(path: string): string
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		table.insert(parts, part)
	end
	if #parts <= 2 then
		return path
	end
	return "…/" .. parts[#parts - 1] .. "/" .. parts[#parts]
end
local function agentNode(agent: Agent, focused: number?, keyPrefix: string): Node
	local state, tone = nativeState(agent.state)
	local detail = { ui.span(state, tone) }
	if agent.model ~= nil and agent.model ~= "" then
		table.insert(detail, ui.span(" · " .. bounded(agent.model, MAX_MODEL), "muted"))
	end
	local head = withProps(
		ui.row({
			withProps(ui.text(ui.span(bounded(agent.title, MAX_TITLE), "strong")), {
				key = keyPrefix .. "title:" .. tostring(agent.pane),
				role = role("agent-title"),
			}),
			withProps(ui.badge("VS Code", "muted"), {
				key = keyPrefix .. "code:" .. tostring(agent.pane),
				role = role("agent-code"),
				title = "Abrir el worktree de este agente en VS Code",
				actions = { click = "agent-code=" .. tostring(agent.pane) },
			}),
		}),
		{ key = keyPrefix .. "head:" .. tostring(agent.pane), role = role("agent-head") }
	)
	local children = {
		head,
		ui.text(detail),
	}
	if agent.state == "waiting_input" and agent.last_message ~= nil and agent.last_message ~= "" then
		table.insert(children, ui.text(ui.span(bounded(agent.last_message, MAX_MESSAGE), "muted")))
	end
	local agentRole = if focused == agent.pane then role("active") else role("normal")
	return withProps(ui.col(children), {
		key = keyPrefix .. tostring(agent.pane),
		role = agentRole,
		title = agent.title .. "\n" .. agent.cwd,
		actions = { click = "agent=" .. tostring(agent.pane) },
	})
end
local function terminalNode(terminal: Terminal, focused: number?): Node
	local state, tone = "Abierto", "muted"
	if terminal.state == "running" then
		state, tone = "Ejecutando", "accent"
	elseif terminal.state == "ready" then
		state, tone = "Listo", "success"
	elseif terminal.state == "exited" then
		state = "Finalizado"
			.. (if terminal.exit_status ~= nil then " (código " .. tostring(terminal.exit_status) .. ")" else "")
		tone = if terminal.exit_status ~= nil and terminal.exit_status ~= 0 then "error" else "muted"
	end
	local detail = state
	if terminal.command ~= nil and terminal.command ~= "" then
		detail ..= " · " .. bounded(terminal.command, MAX_MESSAGE)
	elseif terminal.program ~= nil and terminal.program ~= "" then
		detail ..= " · " .. bounded(terminal.program, MAX_MODEL)
	end
	return withProps(
		ui.col({
			ui.text({ ui.span(">_ ", "muted"), ui.span(bounded(terminal.title, MAX_TITLE), "strong") }),
			ui.text(ui.span(detail, tone)),
		}),
		{
			key = "terminal:" .. tostring(terminal.pane),
			role = if focused == terminal.pane then role("terminal-active") else role("terminal"),
			title = terminal.title .. "\n" .. terminal.cwd .. (if terminal.command ~= nil
					and terminal.command ~= ""
				then "\n" .. terminal.command
				else ""),
			actions = { click = "pane=" .. tostring(terminal.pane) },
		}
	)
end

local function sessionNode(
	session: Session,
	focused: number?,
	agentLimit: number,
	terminalLimit: number
): (Node, number, number, number, number)
	local children: { Node } = {}
	local renderedAgents = math.min(#session.agents, agentLimit)
	for i = 1, renderedAgents do
		table.insert(children, agentNode(session.agents[i], focused, "agent:"))
	end
	local hiddenAgents = #session.agents - renderedAgents
	if hiddenAgents > 0 then
		table.insert(
			children,
			withProps(ui.text(ui.span("… " .. tostring(hiddenAgents) .. " agentes omitidos", "muted")), {
				key = "agents-overflow:" .. tostring(session.id),
				role = role("overflow"),
			})
		)
	end
	local renderedTerminals = math.min(#session.terminals, terminalLimit)
	if renderedTerminals > 0 then
		table.insert(
			children,
			withProps(ui.text(ui.span("Terminales", "muted")), {
				key = "terminals-heading:" .. tostring(session.id),
				role = role("terminal-heading"),
			})
		)
		for i = 1, renderedTerminals do
			table.insert(children, terminalNode(session.terminals[i], focused))
		end
	end
	local hiddenTerminals = #session.terminals - renderedTerminals
	if hiddenTerminals > 0 then
		table.insert(
			children,
			withProps(ui.text(ui.span("… " .. tostring(hiddenTerminals) .. " terminales omitidos", "muted")), {
				key = "terminals-overflow:" .. tostring(session.id),
				role = role("overflow"),
			})
		)
	end
	if #session.agents == 0 and #session.terminals == 0 then
		table.insert(children, ui.text(ui.span("Sin agentes", "muted")))
	end
	local group = withProps(ui.col(children), {
		key = "session-group:" .. tostring(session.id),
		role = role("session-group"),
	})
	return group, renderedAgents, hiddenAgents, renderedTerminals, hiddenTerminals
end

local function actionBadge(label: string, key: string, role: string, action: string, tone: string): Node
	return withProps(ui.badge(label, tone), { key = key, role = role, actions = { click = action } })
end

local function header(board: Model.Board): Node
	local summary: { Node } =
		{ ui.badge(tostring(board.total) .. (if board.total == 1 then " agente" else " agentes"), "neutral") }
	if board.terminalTotal > 0 then
		table.insert(
			summary,
			ui.badge(
				tostring(board.terminalTotal) .. (if board.terminalTotal == 1 then " terminal" else " terminales"),
				"muted"
			)
		)
	end
	if board.waiting > 0 then
		table.insert(summary, ui.badge(tostring(board.waiting) .. " en espera", "warning"))
	end
	if board.working > 0 then
		table.insert(summary, ui.badge(tostring(board.working) .. " trabajando", "accent"))
	end
	if board.idle > 0 then
		table.insert(
			summary,
			ui.badge(tostring(board.idle) .. (if board.idle == 1 then " inactivo" else " inactivos"), "muted")
		)
	end
	if board.exited > 0 then
		table.insert(
			summary,
			ui.badge(tostring(board.exited) .. (if board.exited == 1 then " finalizado" else " finalizados"), "muted")
		)
	end
	local unknown = board.total - board.waiting - board.working - board.idle - board.exited
	if unknown > 0 then
		table.insert(summary, ui.badge(tostring(unknown) .. " sin estado conocido", "muted"))
	end
	return withProps(
		ui.row({
			ui.text(ui.span("Proyectos", "strong")),
			withProps(ui.row(summary), { key = "summary", role = role("summary") }),
		}),
		{ key = "header", role = role("header") }
	)
end

local function attentionSection(board: Model.Board, focused: number?): Node?
	local waiting = Model.waiting(board)
	if #waiting == 0 then
		return nil
	end
	local attention: { Node } = { ui.text(ui.span("Esperan respuesta", "strong warning")) }
	local count, attentionBytes = 0, 0
	local limit = math.min(#waiting, MAX_WAITING)
	for i = 1, limit do
		local agent = waiting[i]
		local projectName, sessionName, hostName = "", "", ""
		for _, project in board.projects do
			for _, session in project.sessions do
				for _, candidate in session.agents do
					if candidate.pane == agent.pane then
						projectName, sessionName, hostName = project.name, session.name, project.host_name
						break
					end
				end
			end
		end
		local item = agentNode(agent, focused, "attention:")
		local context = projectName .. " · " .. sessionName .. " · " .. hostName
		table.insert(
			item.c :: { Node },
			withProps(ui.text(ui.span(bounded(context, MAX_TITLE), "muted")), { title = agent.cwd .. "\n" .. context })
		)
		local cost = #tern.json.encode(item)
		if attentionBytes + cost > 48 * 1024 then
			break
		end
		attentionBytes += cost
		count += 1
		table.insert(attention, item)
	end
	if #waiting > count then
		table.insert(
			attention,
			withProps(ui.text(ui.span("… " .. tostring(#waiting - count) .. " esperas omitidas", "muted")), {
				key = "waiting-overflow",
				role = role("overflow"),
			})
		)
	end
	return withProps(ui.col(attention), { key = "waiting", role = role("waiting") })
end

local function projectPathRow(project: Project): Node
	local pathNodes: { Node } = {
		withProps(
			ui.text({
				ui.span(if project.path == "" then "Sin directorio" else compactPath(project.path), "path"),
				ui.span(" · " .. bounded(project.host_name, 80), "muted"),
			}),
			{ key = "project-location:" .. project.key, role = role("project-location") }
		),
	}
	if project.path ~= "" then
		table.insert(
			pathNodes,
			withProps(
				ui.row({
					actionBadge(
						"VS Code",
						"project-code:" .. project.key,
						role("project-code"),
						"open-vscode=" .. project.key,
						"muted"
					),
					actionBadge(
						"+",
						"project-add:" .. project.key,
						role("project-add"),
						"project=" .. project.key,
						"accent"
					),
				}),
				{ key = "project-tools:" .. project.key, role = role("project-tools") }
			)
		)
	end
	local pathProps: { [string]: any } =
		{ key = "project-path:" .. project.key, role = role("project-path"), title = project.path }
	if #project.sessions == 1 then
		local session = project.sessions[1]
		pathProps.title = project.path
			.. "\n"
			.. project.host_name
			.. "\nSesión: "
			.. session.name
			.. (if session.locked then " (bloqueada)" else "")
		pathProps.aria = "Proyecto " .. project.name .. ", sesión " .. session.name
		pathProps.actions =
			{ click = if session.pane then "pane=" .. tostring(session.pane) else "session=" .. tostring(session.id) }
	end
	return withProps(ui.row(pathNodes), pathProps)
end

local function launcherChooser(project: Project, options: Options): Node?
	if project.path == "" or options.projectMenu ~= project.key then
		return nil
	end
	return withProps(
		ui.row({
			actionBadge("Nuevo omp", "new-omp:" .. project.key, role("launch"), "new-omp=" .. project.key, "accent"),
			actionBadge(
				"Terminal",
				"new-terminal:" .. project.key,
				role("launch"),
				"new-terminal=" .. project.key,
				"muted"
			),
			actionBadge("Cancelar", "cancel-project:" .. project.key, role("cancel"), "cancel-project", "muted"),
		}),
		{ key = "chooser:" .. project.key, role = role("chooser") }
	)
end

type Rendered = { sessions: number, agents: number, terminals: number }

local function sessionRows(project: Project, focused: number?, rendered: Rendered): ({ Node }, number)
	local nodes: { Node } = {}
	local shownSessions = 0
	for _, session in project.sessions do
		if rendered.sessions >= MAX_SESSIONS then
			break
		end
		local paneAction = if session.pane
			then "pane=" .. tostring(session.pane)
			else "session=" .. tostring(session.id)
		if #project.sessions > 1 then
			table.insert(
				nodes,
				withProps(
					ui.row({
						actionBadge(
							(if session.current then "● " else "")
								.. bounded(session.name, MAX_TITLE)
								.. (if session.locked then " · Bloqueada" else ""),
							"session:" .. tostring(session.id),
							role("session"),
							paneAction,
							if session.current then "accent" else "muted"
						),
					}),
					{ key = "session-row:" .. tostring(session.id), role = role("session-row") }
				)
			)
		end
		local group, addedAgents, _, addedTerminals =
			sessionNode(session, focused, MAX_AGENTS - rendered.agents, MAX_TERMINALS - rendered.terminals)
		table.insert(nodes, group)
		rendered.sessions += 1
		shownSessions += 1
		rendered.agents += addedAgents
		rendered.terminals += addedTerminals
	end
	return nodes, shownSessions
end

local function omittedRows(project: Project, shownSessions: number): Node?
	local omittedSessions = #project.sessions - shownSessions
	if omittedSessions <= 0 then
		return nil
	end
	return withProps(ui.text(ui.span("… " .. tostring(omittedSessions) .. " sesiones omitidas", "muted")), {
		key = "sessions-overflow:" .. project.key,
		role = role("overflow"),
	})
end

local function projectNode(project: Project, focused: number?, options: Options, rendered: Rendered): Node
	local projectChildren: { Node } = { projectPathRow(project) }
	local chooser = launcherChooser(project, options)
	if chooser then
		table.insert(projectChildren, chooser)
	end
	local rows, shownSessions = sessionRows(project, focused, rendered)
	for _, node in rows do
		table.insert(projectChildren, node)
	end
	local omitted = omittedRows(project, shownSessions)
	if omitted then
		table.insert(projectChildren, omitted)
	end
	return withProps(ui.section({ ui.span(bounded(project.name, MAX_TITLE), "strong") }, projectChildren), {
		key = "project:" .. project.key,
		role = role("project"),
		collapsible = true,
		collapsed = false,
	})
end

local function omittedProjectRows(children: { Node }, eligibleProjects: number, shownProjects: number, options: Options)
	local omittedProjects = eligibleProjects - shownProjects
	if omittedProjects > 0 then
		table.insert(
			children,
			withProps(ui.text(ui.span("… " .. tostring(omittedProjects) .. " proyectos omitidos", "muted")), {
				key = "projects-overflow",
				role = role("overflow"),
			})
		)
	end
	if options.onlyAgents and eligibleProjects == 0 then
		table.insert(children, ui.text(ui.span("No hay proyectos con agentes", "muted")))
	end
end

function View.build(board: Model.Board, focused: number?, options: Options): Node
	local children: { Node } = { header(board) }
	local attention = attentionSection(board, focused)
	if attention then
		table.insert(children, attention)
	end

	local rendered: Rendered = { sessions = 0, agents = 0, terminals = 0 }
	local bytes = #tern.json.encode(children)
	local shownProjects, eligibleProjects = 0, 0
	for _, project in board.projects do
		if not options.onlyAgents or Model.hasAgents(project) then
			eligibleProjects += 1
		end
	end
	for _, project in board.projects do
		if not options.onlyAgents or Model.hasAgents(project) then
			if shownProjects >= MAX_PROJECTS then
				break
			end
			local node = projectNode(project, focused, options, rendered)
			local cost = #tern.json.encode(node)
			if bytes + cost > MAX_VIEW_BYTES then
				break
			end
			bytes += cost
			shownProjects += 1
			table.insert(children, node)
		end
	end
	omittedProjectRows(children, eligibleProjects, shownProjects, options)
	return withProps(ui.col(children), { role = role("sidebar") })
end

function View.dock(options: Options): Node
	return withProps(
		ui.row({
			actionBadge(
				if options.onlyAgents then "Proyectos: con agentes" else "Todos los proyectos",
				"filter",
				role("filter"),
				"filter",
				if options.onlyAgents then "accent" else "muted"
			),
			actionBadge("Siguiente espera", "next-waiting", role("next-waiting"), "next-waiting", "warning"),
			actionBadge("Último agente", "last-agent", role("last-agent"), "last-agent", "muted"),
			actionBadge("Actualizar", "refresh", role("refresh"), "refresh", "accent"),
			actionBadge("Ocultar", "hide", role("hide"), "hide", "muted"),
		}),
		{ role = role("dock") }
	)
end

return View
