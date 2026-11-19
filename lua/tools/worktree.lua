-- Git worktree switcher.
--
-- From inside a repo: lists every worktree of that repo (main checkout included).
-- From a folder of repos (not itself a git repo): lists the worktrees of each child repo,
-- running `git -C <child>` so git is never invoked at the parent.
--
-- Opening a worktree gives it its own tab with a tab-local cwd. That makes tsserver/eslint
-- resolve the worktree's own node_modules and generated files instead of the main checkout's.
-- BFF links share one config per repo (keyed by the main checkout), so they work in every
-- worktree; opening one starts its index right away.

local M = {}

local function git(dir, ...)
  local out = vim.fn.systemlist({ "git", "-C", dir, ... })
  return vim.v.shell_error == 0 and out or nil
end

--- Parse `git worktree list --porcelain` into records.
--- Exposed for tests: the format is stable but the parse is easy to get subtly wrong.
function M.parse_porcelain(lines)
  local entries, cur = {}, nil
  for _, line in ipairs(lines) do
    local path = line:match("^worktree (.+)$")
    if path then
      cur = { path = path }
      table.insert(entries, cur)
    elseif cur then
      local branch = line:match("^branch refs/heads/(.+)$")
      if branch then
        cur.branch = branch
      elseif line == "detached" then
        cur.branch = "(detached)"
      elseif line == "bare" then
        cur.bare = true
      elseif line == "prunable" or line:match("^prunable ") then
        cur.prunable = true
      elseif line == "locked" or line:match("^locked ") then
        cur.locked = true
      end
    end
  end
  return entries
end

-- Live worktrees of the repo at `dir`. The first porcelain entry is the main checkout.
local function worktrees_of(dir, current)
  local lines = git(dir, "worktree", "list", "--porcelain")
  if not lines then
    return {}
  end
  local out = {}
  for i, wt in ipairs(M.parse_porcelain(lines)) do
    -- Prunable entries are stale admin records whose directory is already gone.
    if not wt.bare and not wt.prunable and vim.fn.isdirectory(wt.path) == 1 then
      wt.main = i == 1
      wt.current = wt.path == current
      wt.name = vim.fs.basename(wt.path)
      table.insert(out, wt)
    end
  end
  for _, wt in ipairs(out) do
    wt.repo = vim.fs.basename(out[1] and out[1].main and out[1].path or dir)
  end
  return out
end

--- Worktrees reachable from `cwd` (default: the tab cwd).
function M.collect(cwd)
  cwd = vim.fs.normalize(cwd or vim.fn.getcwd())
  local top = git(cwd, "rev-parse", "--show-toplevel")
  if top then
    return worktrees_of(cwd, vim.fs.normalize(top[1]))
  end
  local found = {}
  for name, kind in vim.fs.dir(cwd) do
    local repo = cwd .. "/" .. name
    if kind == "directory" and vim.uv.fs_stat(repo .. "/.git") then
      vim.list_extend(found, worktrees_of(repo))
    end
  end
  table.sort(found, function(a, b)
    if a.repo ~= b.repo then
      return a.repo < b.repo
    end
    if a.main ~= b.main then
      return a.main
    end
    return a.name < b.name
  end)
  return found
end

function M.label(wt)
  local mark = (wt.current and "* " or "  ") .. (wt.main and "[main] " or "")
  return string.format("%-20s %s%-36s %s", wt.repo, mark, wt.name, wt.branch or "?")
end

--- Reuse a tab already parked on this cwd rather than piling up duplicates.
local function focus_existing(path)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.fs.normalize(vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tab))) == path then
      vim.api.nvim_set_current_tabpage(tab)
      return true
    end
  end
  return false
end

-- Start the BFF index for the worktree, so links show on the first file opened.
local function prewarm(path)
  if #require("tools.bff.config").projects(path) == 0 then
    return
  end
  local ok, lazy = pcall(require, "lazy")
  if ok then
    lazy.load({ plugins = { "bff-links" } })
  end
  pcall(function()
    require("tools.bff").prewarm(path)
  end)
end

function M.open(wt)
  local path = vim.fs.normalize(wt.path)
  if focus_existing(path) then
    return
  end
  vim.cmd.tabnew()
  vim.cmd.tcd(vim.fn.fnameescape(path))
  prewarm(path)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    snacks.picker.files({ cwd = path })
  else
    vim.cmd.edit(".")
  end
end

function M.browse()
  local cwd = vim.fn.getcwd()
  local worktrees = M.collect(cwd)
  if #worktrees == 0 then
    vim.notify("No git worktrees in or under " .. cwd, vim.log.levels.WARN)
    return
  end
  -- vim.ui.select rather than a picker-specific API: snacks already replaces it with
  -- its fuzzy picker, so this gets that UI without pinning to an API that may move.
  vim.ui.select(worktrees, { format_item = M.label, prompt = "Git worktrees" }, function(choice)
    if choice then
      M.open(choice)
    end
  end)
end

--- The remote default branch: origin/HEAD, else origin/main, else origin/master.
function M.trunk(cwd)
  local head = git(cwd, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
  if head and head[1] then
    return head[1]
  end
  for _, candidate in ipairs({ "origin/main", "origin/master" }) do
    if git(cwd, "rev-parse", "--verify", "--quiet", candidate) then
      return candidate
    end
  end
end

--- Diff the current tab's worktree against its merge-base with the repo's trunk.
function M.diff_trunk()
  local cwd = vim.fn.getcwd()
  local base = M.trunk(cwd)
  if not base then
    vim.notify("No origin/HEAD, origin/main or origin/master reachable from " .. cwd, vim.log.levels.WARN)
    return
  end
  vim.cmd("DiffviewOpen " .. base .. "...HEAD")
end

return M
