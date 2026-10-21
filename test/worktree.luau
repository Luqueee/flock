--!strict

local Worktree = require("../lib/worktree")
local checks = 0

local function check(condition: boolean, message: string)
	assert(condition, message)
	checks += 1
end

-- Fixture mirroring `git worktree list --porcelain` on a real project: the main checkout, linked worktrees nested
-- inside it (one a level below `.worktrees/<name>`), and one whose directory was already deleted.
local LISTING = table.concat({
	"worktree /data/workspace",
	"HEAD a0a0a0a000000000000000000000000000000001",
	"branch refs/heads/main",
	"",
	"worktree /data/workspace/.worktrees/feature-a/workspace",
	"HEAD b0b0b0b000000000000000000000000000000002",
	"branch refs/heads/task/feature-a",
	"",
	"worktree /data/workspace/.worktrees/feature-b",
	"HEAD c0c0c0c000000000000000000000000000000003",
	"branch refs/heads/task/feature-b",
	"",
	"worktree /data/workspace/.worktrees/finished-task",
	"HEAD d0d0d0d000000000000000000000000000000004",
	"detached",
	"prunable gitdir file points to non-existent location",
	"",
}, "\n")

local function output(extra: { string }): string
	return LISTING .. "@@END\n" .. table.concat(extra, "\n") .. "\n"
end

local ALIVE = {
	"@@DIR\t/data/workspace\t1",
	"@@DIR\t/data/workspace/.worktrees/feature-a/workspace\t1",
	"@@DIR\t/data/workspace/.worktrees/feature-b\t1",
	"@@DIR\t/data/workspace/.worktrees/finished-task\t0",
}

local function probeFor(real: { string }): Worktree.Probe
	local lines = {}
	for _, line in real do
		table.insert(lines, line)
	end
	for _, line in ALIVE do
		table.insert(lines, line)
	end
	return Worktree.parse(output(lines))
end

local function edit(path: string): Worktree.Tool
	return { name = "edit", path = path }
end
local function read(path: string): Worktree.Tool
	return { name = "read", path = path }
end

-- Tool hrefs are file URIs: decoded, stripped of fragments, and limited to absolute local files.
check(
	Worktree.fileUri("file:///home/me/my%20app/a%23b.lua#L52") == "/home/me/my app/a#b.lua",
	"href must decode escapes and drop the fragment"
)
check(
	Worktree.fileUri("https://example.com/x") == nil
		and Worktree.fileUri("memory://root/x") == nil
		and Worktree.fileUri("file://host/x") == nil,
	"non-local hrefs must be ignored"
)
check(Worktree.fileUri("file:///a%0Ab") == nil, "an escaped newline must not become a path")

-- Candidates are newest first, mutations before reads, deduplicated, capped, and sanitized.
local tools: { Worktree.Tool } = {
	read("/r/old"),
	edit("/w/one"),
	read("/r/new"),
	edit("/w/two"),
	edit("/w/one"),
	{ name = "bash" },
	edit("relative/x"),
	edit("/bad\nname"),
}
local candidates = Worktree.collect(tools)
local order = {}
for _, candidate in candidates do
	table.insert(order, candidate.path)
end
check(
	table.concat(order, ",") == "/w/one,/w/two,/r/new,/r/old",
	"newest mutations must precede newest reads without duplicates or unusable paths"
)
check(candidates[1].mutating and not candidates[3].mutating, "candidates must record whether they are mutations")
local many: { Worktree.Tool } = {}
for i = 1, 40 do
	table.insert(many, edit("/w/" .. i))
end
check(
	#Worktree.collect(many) == 8 and Worktree.collect(many)[1].path == "/w/40",
	"the per-kind cap must keep the newest paths"
)

-- Parsing keeps what the chooser needs and strips the ref prefix.
local probe = probeFor({ "@@REAL\t/x\t/y\t1" })
check(
	#probe.worktrees == 4
		and probe.worktrees[2].branch == "task/feature-a"
		and probe.worktrees[2].path == "/data/workspace/.worktrees/feature-a/workspace",
	"worktree roots and branches must be parsed"
)
check(
	probe.worktrees[4].detached and probe.worktrees[4].prunable and probe.worktrees[4].branch == nil,
	"detached and prunable entries must be flagged"
)
check(
	probe.real["/x"] == "/y"
		and probe.exists["/x"] == true
		and probe.alive["/data/workspace/.worktrees/finished-task"] == false
		and probe.alive["/data/workspace"] == true,
	"resolved paths, existence and liveness must be parsed"
)
check(Worktree.parse("@@NOCWD\n").cwdMissing, "a missing cwd must be reported")

local CWD = "/data/workspace"
local function choose(list: { Worktree.Tool }, real: { string }): Worktree.Choice
	return Worktree.choose(CWD, Worktree.collect(list), probeFor(real))
end

-- The agent's spelling goes through a symlink; the root is git's, not `.worktrees/<name>`.
local link = "/home/dev/workspace/.worktrees/feature-a/workspace/src/app.ts"
local viaLink = choose({ edit(link) }, {
	"@@REAL\t/data/workspace\t/data/workspace\t1",
	"@@REAL\t" .. link .. "\t/data/workspace/.worktrees/feature-a/workspace/src/app.ts\t1",
})
check(
	viaLink.kind == "worktree"
		and viaLink.path == "/data/workspace/.worktrees/feature-a/workspace"
		and viaLink.branch == "task/feature-a",
	"a symlinked path must resolve to the worktree's real root"
)

-- A linked worktree nested inside the main checkout must win over the main checkout.
local nested = "/data/workspace/.worktrees/feature-b/a.md"
check(
	choose({ edit(nested) }, { "@@REAL\t" .. nested .. "\t" .. nested .. "\t1" }).path
		== "/data/workspace/.worktrees/feature-b",
	"the longest matching root must win over the main checkout"
)

-- Deleted worktrees are skipped in favour of the next live one.
local gone = "/data/workspace/.worktrees/finished-task/z.md"
local pickedLive = choose(
	{ edit(nested), edit(gone) },
	{ "@@REAL\t" .. gone .. "\t" .. gone .. "\t1", "@@REAL\t" .. nested .. "\t" .. nested .. "\t1" }
)
check(pickedLive.kind == "worktree" and pickedLive.branch == "task/feature-b", "a deleted worktree must not be chosen")

-- A pruned worktree has no git entry and no file, yet its path lies inside the main checkout: skip it.
local pruned = "/data/workspace/.worktrees/long-gone/webs/x.tsx"
local afterPruned = choose(
	{ edit(nested), edit(pruned) },
	{ "@@REAL\t" .. pruned .. "\t" .. pruned .. "\t0", "@@REAL\t" .. nested .. "\t" .. nested .. "\t1" }
)
check(
	afterPruned.kind == "worktree" and afterPruned.branch == "task/feature-b",
	"a missing file under the main checkout must not count as main-checkout activity"
)

-- Edits outrank reads, and activity in the main checkout keeps the project folder.
local other = "/data/workspace/.worktrees/feature-a/workspace/b.ts"
check(
	choose(
		{ edit(other), read(nested) },
		{ "@@REAL\t" .. other .. "\t" .. other .. "\t1", "@@REAL\t" .. nested .. "\t" .. nested .. "\t1" }
	).branch == "task/feature-a",
	"a newer read must not override an edit"
)
local mainFile = "/data/workspace/README.md"
local mainChoice = choose(
	{ edit(other), edit(mainFile) },
	{ "@@REAL\t" .. other .. "\t" .. other .. "\t1", "@@REAL\t" .. mainFile .. "\t" .. mainFile .. "\t1" }
)
check(
	mainChoice.kind == "project" and mainChoice.path == CWD,
	"the newest edit in the main checkout must keep the project folder"
)

-- Nothing usable means the project folder, never a guess.
check(choose({}, {}).kind == "project", "no activity must open the project folder")
check(
	choose({ edit("/etc/hosts") }, { "@@REAL\t/etc/hosts\t/etc/hosts\t1" }).kind == "project",
	"paths outside the repository must be ignored"
)
check(
	Worktree.choose(CWD, Worktree.collect({ edit(nested) }), Worktree.parse("")).kind == "project",
	"a non-repository or empty answer must open the project folder"
)
check(
	Worktree.choose(CWD, Worktree.collect({ edit(nested) }), Worktree.parse("@@NOCWD\n")).kind == "project",
	"a missing cwd must open the project folder"
)

-- When the chat was started inside a worktree, the folder the user chose is kept.
local startedInside = "/data/workspace/.worktrees/feature-a/workspace/packages/ui"
local keep = Worktree.choose(
	startedInside,
	Worktree.collect({ edit(other) }),
	probeFor({
		"@@REAL\t" .. startedInside .. "\t" .. startedInside .. "\t1",
		"@@REAL\t" .. other .. "\t" .. other .. "\t1",
	})
)
check(keep.kind == "worktree" and keep.path == startedInside, "a cwd already inside the worktree must be kept")

-- Remote values pass through a login shell, so every one must stay inside single quotes.
check(
	Worktree.quote("it's") == "'it'\\''s'"
		and Worktree.quote("$(rm -rf ~)") == "'$(rm -rf ~)'"
		and Worktree.quote("a b;c") == "'a b;c'",
	"values must be single-quoted with embedded quotes escaped"
)
local command = Worktree.command("/srv/my app", Worktree.collect({ edit("/srv/my app/x'y") }))
check(
	string.find(command, " '/srv/my app' '/srv/my app' '/srv/my app/x'\\''y'", 1, true) ~= nil
		and string.sub(command, 1, 7) == "sh -c '",
	"the remote command must quote the cwd and every path"
)
local argv = Worktree.argv("/srv/app", Worktree.collect({ edit("/srv/app/x") }))
check(
	argv[1] == "sh"
		and argv[2] == "-c"
		and argv[4] == "sh"
		and argv[5] == "/srv/app"
		and argv[6] == "/srv/app"
		and argv[7] == "/srv/app/x"
		and #argv == 7,
	"the local argument vector must pass values unquoted after the script"
)

print("Worktree: " .. checks .. " checks passed")
