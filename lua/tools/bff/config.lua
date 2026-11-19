-- Machine-local BFF links config: one entry per repository, written by :BffSetup.
--
-- Lives in the nvim config dir as `bff-links.local.json`, which .gitignore keeps out of git
-- (it holds local paths and the names of the projects you work on).
--
-- A repository is keyed by its main checkout (the parent of `git rev-parse --git-common-dir`),
-- so every linked worktree of that repository shares the one entry. All paths inside an entry
-- are relative, so they apply to whichever worktree is open.

local M = {}

M.path = vim.fn.stdpath("config") .. "/bff-links.local.json"

local cache -- decoded file
local repo_cache = {} -- dir -> { top, key } | false

--- vim.NIL (JSON null) and missing both read as nil.
function M.get(tbl, key)
  local v = tbl and tbl[key]
  if v == vim.NIL then
    return nil
  end
  return v
end

function M.load()
  if cache then
    return cache
  end
  cache = { version = 1, repos = vim.empty_dict() }
  local f = io.open(M.path, "r")
  if f then
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(vim.json.decode, text)
    if ok and type(data) == "table" and type(data.repos) == "table" then
      cache = data
    else
      vim.notify("bff: cannot parse " .. M.path .. " — fix it or run :BffSetup again", vim.log.levels.WARN)
    end
  end
  return cache
end

function M.reload()
  cache = nil
end

function M.encode(value)
  local ok, text = pcall(vim.json.encode, value, { indent = "  ", sort_keys = true })
  return ok and text or vim.json.encode(value)
end

function M.save(data)
  local tmp = M.path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(M.encode(data), "\n")
  f:close()
  assert(vim.uv.fs_rename(tmp, M.path))
  cache = data
end

--- { top = worktree toplevel, key = main checkout } for a directory, or nil outside a repo.
--- Outside git, the nearest package.json dir is both.
function M.repo_info(dir)
  dir = vim.fs.normalize(dir)
  if repo_cache[dir] ~= nil then
    return repo_cache[dir] or nil
  end
  local info = false
  if vim.uv.fs_stat(dir) then
    local out = vim.fn.systemlist({
      "git",
      "-C",
      dir,
      "rev-parse",
      "--path-format=absolute",
      "--show-toplevel",
      "--git-common-dir",
    })
    if vim.v.shell_error == 0 and out[2] then
      info = { top = vim.fs.normalize(out[1]), key = vim.fs.dirname(vim.fs.normalize(out[2])) }
    else
      local top = vim.fs.root(dir, "package.json")
      info = top and { top = top, key = top } or false
    end
  end
  repo_cache[dir] = info
  return info or nil
end

function M.entry(key)
  local e = key and M.load().repos[key]
  return type(e) == "table" and e or nil
end

--- Every configured project of the repo `dir` belongs to, as { root, project, main, top, repo }:
--- root is the project dir in this worktree, main the same dir in the main checkout,
--- top the worktree toplevel and repo the main checkout.
function M.projects(dir)
  local info = M.repo_info(dir)
  local entry = info and M.entry(info.key)
  local out = {}
  for _, p in ipairs(entry and M.get(entry, "projects") or {}) do
    local sub = M.get(p, "dir") or "."
    local root = sub == "." and info.top or vim.fs.normalize(info.top .. "/" .. sub)
    local main = sub == "." and info.key or vim.fs.normalize(info.key .. "/" .. sub)
    table.insert(out, { root = root, project = p, main = main, top = info.top, repo = info.key })
  end
  return out
end

--- The project a file belongs to (longest matching project dir wins).
function M.project_for(file)
  file = vim.fs.normalize(file)
  local best
  for _, p in ipairs(M.projects(vim.fs.dirname(file))) do
    if file:sub(1, #p.root + 1) == p.root .. "/" and (not best or #p.root > #best.root) then
      best = p
    end
  end
  return best
end

return M
