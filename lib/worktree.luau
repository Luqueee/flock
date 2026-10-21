--!strict

-- Pure helpers that decide which git worktree an agent is working in.
--
-- An omp session keeps the cwd it was launched in even when the agent runs `git worktree add`, so the
-- only trace of where it works is the absolute paths of its file tools. Those paths are matched against
-- `git worktree list` (the authoritative roots) after resolving symlinks on the agent's own machine.
-- Nothing here touches the system: window.luau runs the command this module builds and feeds back its output.

export type Tool = { name: string, path: string? }
export type Candidate = { path: string, mutating: boolean }
export type Entry =
	{ path: string, head: string?, branch: string?, detached: boolean, bare: boolean, prunable: boolean }
export type Probe = {
	worktrees: { Entry },
	real: { [string]: string },
	exists: { [string]: boolean },
	alive: { [string]: boolean },
	cwdMissing: boolean,
}
export type Choice = { path: string, kind: "worktree" | "project", branch: string?, via: string? }

local Worktree = {}

local MUTATING: { [string]: boolean } = { edit = true, write = true, ast_edit = true }
local PER_KIND = 8

-- Runs inside `sh` on the agent's machine. $1 is the cwd; every argument after it (the cwd again, then the
-- tool paths) is resolved with realpath so a symlinked spelling matches git's canonical roots.
local SCRIPT = [=[
cd -- "$1" 2>/dev/null || { echo '@@NOCWD'; exit 0; }
git worktree list --porcelain 2>/dev/null
printf '@@END\n'
for p in "$@"; do
  r=$(realpath -m -- "$p" 2>/dev/null || realpath -- "$p" 2>/dev/null || printf '%s' "$p")
  if [ -e "$r" ]; then e=1; else e=0; fi
  printf '@@REAL\t%s\t%s\t%s\n' "$p" "$r" "$e"
done
git worktree list --porcelain 2>/dev/null | while IFS= read -r l; do
  case "$l" in
    'worktree '*) w=${l#worktree }; if [ -d "$w" ]; then printf '@@DIR\t%s\t1\n' "$w"; else printf '@@DIR\t%s\t0\n' "$w"; fi;;
  esac
done
]=]

function Worktree.quote(value: string): string
	return "'" .. (string.gsub(value, "'", "'\\''")) .. "'"
end

local function usable(path: string): boolean
	return #path <= 1024 and string.sub(path, 1, 1) == "/" and string.match(path, "%c") == nil
end

-- `file:///a%20b/c#L3` becomes `/a b/c`; anything that is not a local file URI is rejected.
function Worktree.fileUri(href: string): string?
	if string.sub(href, 1, 8) ~= "file:///" then
		return nil
	end
	local path = string.sub(href, 8)
	path = string.gsub(path, "[#?].*$", "")
	path = string.gsub(path, "%%(%x%x)", function(code)
		return string.char(tonumber(code, 16) :: number)
	end)
	return if usable(path) then path else nil
end

-- Newest paths first, deduplicated; file mutations rank before reads because a read may be incidental.
function Worktree.collect(tools: { Tool }): { Candidate }
	local result: { Candidate } = {}
	local seen: { [string]: boolean } = {}
	for _, wantMutating in { true, false } do
		local taken = 0
		for index = #tools, 1, -1 do
			local tool = tools[index]
			local path = tool.path
			if path and usable(path) and (MUTATING[tool.name] == true) == wantMutating and not seen[path] then
				seen[path] = true
				table.insert(result, { path = path, mutating = wantMutating })
				taken += 1
				if taken >= PER_KIND then
					break
				end
			end
		end
	end
	return result
end

local function arguments(cwd: string, candidates: { Candidate }): { string }
	local args = { cwd, cwd }
	for _, candidate in candidates do
		table.insert(args, candidate.path)
	end
	return args
end

-- Local machine: argument vector for the process runner.
function Worktree.argv(cwd: string, candidates: { Candidate }): { string }
	local argv = { "sh", "-c", SCRIPT, "sh" }
	for _, value in arguments(cwd, candidates) do
		table.insert(argv, value)
	end
	return argv
end

-- Remote machine: one string for the remote login shell, every value single-quoted.
function Worktree.command(cwd: string, candidates: { Candidate }): string
	local parts = { "sh", "-c", Worktree.quote(SCRIPT), "sh" }
	for _, value in arguments(cwd, candidates) do
		table.insert(parts, Worktree.quote(value))
	end
	return table.concat(parts, " ")
end

function Worktree.parse(output: string): Probe
	local probe: Probe = { worktrees = {}, real = {}, exists = {}, alive = {}, cwdMissing = false }
	local current: Entry? = nil
	local listing = true
	for line in string.gmatch(output, "[^\n]+") do
		if line == "@@NOCWD" then
			probe.cwdMissing = true
		elseif line == "@@END" then
			listing = false
			current = nil
		elseif not listing then
			local original, resolved, present = string.match(line, "^@@REAL\t([^\t]*)\t([^\t]*)\t([01])$")
			if original and resolved and present then
				probe.real[original] = resolved
				probe.exists[original] = present == "1"
			end
			local dir, flag = string.match(line, "^@@DIR\t([^\t]*)\t([01])$")
			if dir and flag then
				probe.alive[dir] = flag == "1"
			end
		elseif string.sub(line, 1, 9) == "worktree " then
			local entry: Entry = {
				path = string.sub(line, 10),
				head = nil,
				branch = nil,
				detached = false,
				bare = false,
				prunable = false,
			}
			table.insert(probe.worktrees, entry)
			current = entry
		elseif current then
			if string.sub(line, 1, 5) == "HEAD " then
				current.head = string.sub(line, 6)
			elseif string.sub(line, 1, 7) == "branch " then
				current.branch = (string.gsub(string.sub(line, 8), "^refs/heads/", ""))
			elseif line == "detached" then
				current.detached = true
			elseif line == "bare" then
				current.bare = true
			elseif string.sub(line, 1, 8) == "prunable" then
				current.prunable = true
			end
		end
	end
	return probe
end

local function inside(root: string, path: string): boolean
	return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

-- The worktree to open: where the newest mutated file (else newest read) of a live worktree sits. Activity in
-- the main checkout keeps the project folder; activity in a deleted worktree (whose path also lies inside the
-- main checkout) or outside the repository is skipped, never mistaken for the main checkout.
function Worktree.choose(cwd: string, candidates: { Candidate }, probe: Probe): Choice
	local fallback: Choice = { path = cwd, kind = "project", branch = nil, via = nil }
	if probe.cwdMissing or #probe.worktrees == 0 then
		return fallback
	end
	local function resolved(path: string): string
		local real = probe.real[path]
		return if real and real ~= "" then real else path
	end
	for _, candidate in candidates do
		-- A file that no longer exists tells nothing: a pruned worktree's path still lies inside the main checkout.
		if probe.exists[candidate.path] == false then
			continue
		end
		local real = resolved(candidate.path)
		local best: Entry? = nil
		local bestIndex = 0
		for index, entry in probe.worktrees do
			if not entry.bare and inside(entry.path, real) then
				if best == nil or #entry.path > #best.path then
					best, bestIndex = entry, index
				end
			end
		end
		if best and probe.alive[best.path] == true then
			if bestIndex == 1 then
				return fallback
			end
			-- Keep the folder the user chose when it already lies inside the worktree.
			local keep = inside(best.path, resolved(cwd))
			return {
				path = if keep then cwd else best.path,
				kind = "worktree",
				branch = best.branch,
				via = candidate.path,
			}
		end
	end
	return fallback
end

return Worktree
