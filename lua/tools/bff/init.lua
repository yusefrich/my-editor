-- BFF route <-> upstream links for any TypeScript BFF (TSOA, NestJS, Express) and its worktrees.
--
-- :BffSetup detects the repo layout once and saves it in the git-ignored local config
-- (see config.lua). indexer.cjs (TypeScript compiler, run with the repo's own `typescript`)
-- then builds a graph of
--   route handler -> service/helper hops -> upstream call (generated SDK / Prisma / npm client / AWS / fetch)
-- and this module paints it as virtual text:
--   route handler        virt lines: every upstream it reaches (+ eol: full BFF route)
--   service / helper     virt lines: which BFF routes reach it
--   upstream call site   eol: upstream method + url
--   SDK file / upstream spec   eol: which BFF routes use the operation (or "unused")
--   own OpenAPI spec           eol: handler + upstream
-- plus pickers to jump along those links.

local config = require("tools.bff.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("bff_links")
M.enabled = true

local indexer = debug.getinfo(1, "S").source:sub(2):gsub("init%.lua$", "indexer.cjs")
local state = {} -- project root -> { data, marks, running, again, err }
local projects = {} -- project root -> config.projects() record

-- Annotation colours: the fg of familiar groups on a background a shade off `Normal`, so the
-- badges read as "not code" at a glance. Recomputed on :colorscheme.
local FG = {
  BffLinksArrow = "Special",
  BffLinksApi = "Type",
  BffLinksMethod = "Keyword",
  BffLinksDim = "Comment",
}

local function shade(rgb)
  local r, g, b = math.floor(rgb / 65536) % 256, math.floor(rgb / 256) % 256, rgb % 256
  local f = function(c)
    -- Near-black themes have no room to go darker: lift slightly instead.
    if (r + g + b) / 3 < 24 then
      return math.min(255, c + 22)
    end
    return math.floor(c * 0.7)
  end
  return f(r) * 65536 + f(g) * 256 + f(b)
end

-- Ownership colours, fixed rather than theme-derived: gold = routes the BFF serves,
-- bright red fading into purple = upstream routes it calls.
local PALETTE = {
  dark = { route = 0xffd75f, upstream = { 0xff3b5c, 0xb86bff } },
  light = { route = 0x8a6d00, upstream = { 0xd0103a, 0x7a1fd6 } },
}
local STEPS = 12 -- BffLinksUpstream1..STEPS along the gradient

local function mix(a, b, t)
  local out = 0
  for _, shift in ipairs({ 65536, 256, 1 }) do
    local ca, cb = math.floor(a / shift) % 256, math.floor(b / shift) % 256
    out = out + math.floor(ca + (cb - ca) * t + 0.5) * shift
  end
  return out
end

function M.set_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local bg = normal.bg and shade(normal.bg) or (vim.o.background == "light" and 0xdcdcdc or 0x16161e)
  for name, src in pairs(FG) do
    local h = vim.api.nvim_get_hl(0, { name = src, link = false })
    vim.api.nvim_set_hl(0, name, { fg = h.fg, bg = bg, italic = name == "BffLinksDim" })
  end
  local p = PALETTE[vim.o.background] or PALETTE.dark
  vim.api.nvim_set_hl(0, "BffLinksRoute", { fg = p.route, bg = bg, bold = true })
  local from, to = p.upstream[1], p.upstream[2]
  vim.api.nvim_set_hl(0, "BffLinksUpstream", { fg = mix(from, to, 0.5), bg = bg })
  for i = 1, STEPS do
    vim.api.nvim_set_hl(0, "BffLinksUpstream" .. i, { fg = mix(from, to, (i - 1) / (STEPS - 1)), bg = bg })
  end
  vim.api.nvim_set_hl(0, "BffLinksBg", { bg = bg })
end
M.set_highlights()

-- ---------------------------------------------------------------------------
-- Roots
-- ---------------------------------------------------------------------------
-- The configured project a buffer belongs to (its dir in the current worktree), or nil.
function M.root_for(buf)
  buf = buf or 0
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return nil
  end
  local p = config.project_for(name)
  if p then
    projects[p.root] = p
    return p.root
  end
end

local NO_CONFIG = "bff: no config for this repo — run :BffSetup"

local function rel(root, file)
  local abs = vim.fs.normalize(file)
  if abs:sub(1, #root + 1) == root .. "/" then
    return abs:sub(#root + 2)
  end
end

-- Linked worktrees usually have no node_modules; fall back to the main checkout's packages
-- (project dir first, then the repo root for hoisted monorepo installs).
local function node_path(p)
  local seen, out = {}, {}
  for _, dir in ipairs({ p.root, p.main, p.top, p.repo }) do
    local nm = dir .. "/node_modules"
    if not seen[nm] then
      seen[nm] = true
      table.insert(out, nm)
    end
  end
  return table.concat(out, ":")
end

local function node_bin()
  local node = vim.fn.exepath("node")
  if node ~= "" then
    return node
  end
  local nvm = vim.fn.glob(vim.fn.expand("~/.nvm/versions/node/*/bin/node"), false, true)
  return nvm[#nvm]
end

-- ---------------------------------------------------------------------------
-- Formatting helpers (return virt_text chunk lists)
-- ---------------------------------------------------------------------------
-- Upstream text as red -> purple gradient chunks (one per step, UTF-8 safe).
local function upstream(text)
  local chars = vim.fn.split(text, "\\zs")
  local chunks, n = {}, #chars
  for i, ch in ipairs(chars) do
    local step = n > 1 and math.floor((i - 1) / (n - 1) * (STEPS - 1) + 0.5) + 1 or 1
    local hl = "BffLinksUpstream" .. step
    local last = chunks[#chunks]
    if last and last[2] == hl then
      last[1] = last[1] .. ch
    else
      table.insert(chunks, { ch, hl })
    end
  end
  return chunks
end

local function op_chunks(op)
  if op.api == "db" then
    return { { "db ", "BffLinksApi" }, unpack(upstream(op.fn)) }
  end
  local out = { { op.api .. " ", "BffLinksApi" }, { op.method .. " ", "BffLinksMethod" } }
  vim.list_extend(out, upstream(op.url))
  return out
end

local function route_chunks(r)
  return {
    { r.method .. " ", "BffLinksMethod" },
    { r.path, "BffLinksRoute" },
    { "  " .. r.controller .. "." .. r.handler, "BffLinksDim" },
  }
end

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    vim.list_extend(out, list)
  end
  return out
end

-- Pad the chunks into a shaded badge.
local function badge(chunks)
  return concat({ { " ", "BffLinksBg" } }, chunks, { { " ", "BffLinksBg" } })
end

-- A virt line: indentation left unshaded, content as a badge.
local function vline(pad, chunks)
  return concat({ { pad } }, badge(chunks))
end

-- An eol annotation: one plain space off the code, then the badge.
local function eol(chunks)
  return concat({ { " " } }, badge(chunks))
end

local function more(n)
  return n > 0 and { { "  +" .. n .. " more", "BffLinksDim" } } or {}
end

-- ---------------------------------------------------------------------------
-- Marks: per relative file, what to draw on which line
-- ---------------------------------------------------------------------------
local function build_marks(data)
  local marks = {}
  local function add(file, line, mark)
    if not file or not line then
      return
    end
    mark.line = line
    marks[file] = marks[file] or {}
    table.insert(marks[file], mark)
  end

  local handler_nodes = {}
  for _, r in ipairs(data.routes) do
    handler_nodes[r.node] = true
    add(r.file, r.line, { kind = "route", route = r })
    local own = data.ownSpec and data.specs[data.ownSpec]
    if own then
      add(data.ownSpec, own[r.method:lower() .. " " .. r.specPath], { kind = "ownspec", route = r })
    end
  end

  for id, node in pairs(data.nodes) do
    if not handler_nodes[id] and data.nodeRoutes[id] and #node.reaches > 0 then
      add(node.file, node.line, { kind = "node", node = node })
    end
  end

  for _, c in ipairs(data.callsites) do
    add(c.file, c.line, { kind = "call", call = c })
  end

  for id, op in pairs(data.ops) do
    if op.sdk then
      add(op.sdk.file, op.sdk.line, { kind = "op", op = op })
    end
    if op.spec then
      add(op.spec.file, op.spec.line, { kind = "op", op = op })
    end
    op.routes = data.opRoutes[id] or {}
  end

  return marks
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
local function indent_of(buf, lnum)
  local text = vim.api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1] or ""
  return text:match("^%s*")
end

local function upstream_lines(data, r, pad)
  local lines, db = {}, {}
  for _, u in ipairs(r.upstream) do
    local op = data.ops[u.op]
    if op.api == "db" then
      table.insert(db, op.fn)
    else
      local via = u.via[#u.via] and data.nodes[u.via[#u.via]]
      table.insert(
        lines,
        vline(
          pad,
          concat({ { "⇢ ", "BffLinksArrow" } }, op_chunks(op), via and { { "  ‹ " .. via.name, "BffLinksDim" } } or {})
        )
      )
    end
  end
  if #db > 0 then
    table.insert(
      lines,
      vline(pad, concat({ { "⇢ ", "BffLinksArrow" }, { "db ", "BffLinksApi" } }, upstream(table.concat(db, ", "))))
    )
  end
  if #lines == 0 then
    table.insert(lines, vline(pad, { { "⇢ no upstream call (local only)", "BffLinksDim" } }))
  end
  return lines
end

local MAX_ROUTES = 4

local function draw(buf, data, mark)
  local lnum = mark.line - 1
  if lnum >= vim.api.nvim_buf_line_count(buf) then
    return
  end
  local set = function(opts)
    opts.hl_mode = "combine"
    pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, lnum, 0, opts)
  end
  local pad = indent_of(buf, lnum)

  if mark.kind == "route" then
    set({
      virt_lines = upstream_lines(data, mark.route, pad),
      virt_lines_above = true,
      virt_text = eol(concat({ { "◆ ", "BffLinksArrow" } }, route_chunks(mark.route))),
    })
  elseif mark.kind == "node" then
    local ids = data.nodeRoutes[mark.node.id]
    local lines = {}
    for i = 1, math.min(#ids, MAX_ROUTES) do
      local line = concat({ { "◀ ", "BffLinksArrow" } }, route_chunks(data.routes[ids[i]]))
      if i == MAX_ROUTES then
        line = concat(line, more(#ids - MAX_ROUTES))
      end
      table.insert(lines, vline(pad, line))
    end
    set({ virt_lines = lines, virt_lines_above = true })
  elseif mark.kind == "call" then
    set({ virt_text = eol(concat({ { "⇢ ", "BffLinksArrow" } }, op_chunks(data.ops[mark.call.op]))) })
  elseif mark.kind == "op" then
    local ids = mark.op.routes
    if #ids == 0 then
      set({ virt_text = eol({ { "◌ not used by BFF", "BffLinksDim" } }) })
    else
      set({
        virt_text = eol(concat({ { "◀ ", "BffLinksArrow" } }, route_chunks(data.routes[ids[1]]), more(#ids - 1))),
      })
    end
  elseif mark.kind == "ownspec" then
    local r = mark.route
    local first = r.upstream[1] and data.ops[r.upstream[1].op]
    set({
      virt_text = eol(
        concat(
          { { "→ " .. r.controller .. "." .. r.handler .. "  ", "BffLinksDim" } },
          first and concat({ { "⇢ ", "BffLinksArrow" } }, op_chunks(first), more(#r.upstream - 1))
            or { { "local only", "BffLinksDim" } }
        )
      ),
    })
  end
end

-- The index knows on-disk line numbers only. A buffer with unsaved edits keeps its current
-- extmarks (they already follow the edits) until it is saved and reindexed, unless forced.
function M.render(buf, force)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.bo[buf].modified and not force and M.enabled then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local root = M.root_for(buf)
  local st = root and state[root]
  if not (M.enabled and st and st.data) then
    return
  end
  local file = rel(root, vim.api.nvim_buf_get_name(buf))
  for _, mark in ipairs(file and st.marks[file] or {}) do
    draw(buf, st.data, mark)
  end
end

local function render_root(root)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and M.root_for(buf) == root then
      M.render(buf)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Indexing
-- ---------------------------------------------------------------------------
function M.index(root, opts)
  opts = opts or {}
  local p = projects[root]
  if not p then
    return
  end
  local st = state[root] or { marks = {} }
  state[root] = st
  if st.running then
    st.again = true
    return
  end
  local node = node_bin()
  if not node then
    vim.notify("bff: `node` not found on PATH", vim.log.levels.ERROR)
    return
  end
  st.running = true
  st.started = vim.uv.clock_gettime("realtime") -- anything modified after this makes it stale
  st.checked = nil
  vim.system(
    { node, indexer, p.top, vim.json.encode(p.project) },
    { text = true, env = { NODE_PATH = node_path(p) } },
    vim.schedule_wrap(function(res)
      st.running = false
      if res.code == 0 then
        local ok, data = pcall(vim.json.decode, res.stdout, { luanil = { object = true, array = true } })
        if ok then
          st.data, st.marks, st.err = data, build_marks(data), nil
          render_root(root)
          if opts.notify then
            vim.notify(("bff: %d routes, %d upstream calls indexed"):format(#data.routes, #data.callsites))
          end
        else
          st.err = data
        end
      else
        st.err = res.stderr
      end
      if st.err and (opts.notify or not st.data) then
        vim.notify("bff: index failed:\n" .. vim.trim(st.err):sub(1, 800), vim.log.levels.WARN)
      end
      if st.again then
        st.again = false
        M.index(root)
      end
    end)
  )
end

-- ---------------------------------------------------------------------------
-- Pickers
-- ---------------------------------------------------------------------------
local function item(root, label, detail, file, line)
  return {
    text = label .. " " .. (detail or ""),
    label = label,
    detail = detail or "",
    file = root .. "/" .. file,
    pos = { line, 0 },
  }
end

local function jump(it)
  vim.cmd.edit(vim.fn.fnameescape(it.file))
  pcall(vim.api.nvim_win_set_cursor, 0, { it.pos[1], it.pos[2] })
  vim.cmd("normal! zz")
end

local function pick(title, items)
  if #items == 0 then
    vim.notify("bff: nothing linked here", vim.log.levels.INFO)
    return
  end
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    snacks.picker.pick({
      title = title,
      items = items,
      preview = "file",
      format = function(it)
        return { { it.label, "Normal" }, { "  " .. it.detail, "Comment" } }
      end,
      confirm = function(picker, it)
        picker:close()
        if it then
          jump(it)
        end
      end,
    })
  else
    vim.ui.select(items, {
      prompt = title,
      format_item = function(it)
        return it.label .. "  " .. it.detail
      end,
    }, function(it)
      if it then
        jump(it)
      end
    end)
  end
end

local function op_label(op)
  return op.api == "db" and ("db " .. op.fn) or (op.api .. " " .. op.method .. " " .. op.url)
end

local function route_label(r)
  return r.method .. " " .. r.path
end

-- Best place to open for an op: its spec entry, else the SDK function, else nothing.
local function op_target(op)
  return op.spec or op.sdk
end

local function current(root)
  local st = state[root]
  if not (st and st.data) then
    return nil
  end
  local file = rel(root, vim.api.nvim_buf_get_name(0))
  local marks = file and st.marks[file] or {}
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local best
  for _, m in ipairs(marks) do
    if m.line == cur and (not best or best.line ~= cur or m.kind == "call") then
      best = m
    elseif m.line < cur and m.kind ~= "call" and (not best or (best.line ~= cur and m.line > best.line)) then
      best = m -- nearest enclosing def / spec operation above the cursor
    end
  end
  return best, st.data
end

local function route_items(root, data, r, items)
  table.insert(items, item(root, "◆ " .. route_label(r), r.controller .. "." .. r.handler, r.file, r.line))
end

local function op_items(root, data, op, items, callsites_for)
  local t = op_target(op)
  if t then
    table.insert(items, item(root, "⇢ " .. op_label(op), op.fn .. "  (" .. t.file .. ")", t.file, t.line))
  end
  -- No spec/SDK to open (S3, db, npm clients, fetch): the call site is the useful target.
  if callsites_for or not t then
    for _, c in ipairs(data.callsites) do
      if c.op == op.id then
        local label = t and "· call" or ("⇢ " .. op_label(op))
        table.insert(items, item(root, label, data.nodes[c.owner].name, c.file, c.line))
      end
    end
  end
end

function M.links()
  local root = M.root_for(0)
  if not root then
    return vim.notify(NO_CONFIG, vim.log.levels.INFO)
  end
  local mark, data = current(root)
  if not mark then
    return vim.notify("bff: no link at cursor (index still building?)", vim.log.levels.INFO)
  end
  local items = {}
  if mark.kind == "route" or mark.kind == "ownspec" then
    local r = mark.route
    if mark.kind == "ownspec" then
      route_items(root, data, r, items)
    end
    for _, u in ipairs(r.upstream) do
      op_items(root, data, data.ops[u.op], items, false)
      for _, v in ipairs(u.via) do
        local n = data.nodes[v]
        table.insert(items, item(root, "  ‹ " .. n.name, "hop", n.file, n.line))
      end
    end
  elseif mark.kind == "node" then
    for _, idx in ipairs(data.nodeRoutes[mark.node.id]) do
      route_items(root, data, data.routes[idx], items)
    end
    for _, opId in ipairs(mark.node.reaches) do
      op_items(root, data, data.ops[opId], items, false)
    end
  elseif mark.kind == "call" then
    local op = data.ops[mark.call.op]
    op_items(root, data, op, items, false)
    for _, idx in ipairs(data.nodeRoutes[mark.call.owner] or {}) do
      route_items(root, data, data.routes[idx], items)
    end
  elseif mark.kind == "op" then
    local op = mark.op
    for _, idx in ipairs(op.routes) do
      route_items(root, data, data.routes[idx], items)
    end
    op_items(root, data, op, items, true)
    if op.sdk then
      table.insert(items, item(root, "· sdk " .. op.fn, op.sdk.file, op.sdk.file, op.sdk.line))
    end
  end
  -- Drop the entry for the place we're standing on.
  local here = vim.api.nvim_buf_get_name(0)
  items = vim.tbl_filter(function(it)
    return not (it.file == here and it.pos[1] == mark.line)
  end, items)
  pick("BFF links", items)
end

function M.routes()
  local root = M.root_for(0)
  local st = root and state[root]
  if not (st and st.data) then
    return vim.notify(root and "bff: index still building" or NO_CONFIG, vim.log.levels.INFO)
  end
  local items = {}
  for _, r in ipairs(st.data.routes) do
    local ups = vim.tbl_map(function(u)
      return op_label(st.data.ops[u.op])
    end, r.upstream)
    table.insert(
      items,
      item(root, route_label(r), (#ups > 0 and "⇢ " .. table.concat(ups, " | ") or "local only"), r.file, r.line)
    )
  end
  table.sort(items, function(a, b)
    return a.label < b.label
  end)
  pick("BFF routes -> upstream", items)
end

function M.upstream()
  local root = M.root_for(0)
  local st = root and state[root]
  if not (st and st.data) then
    return vim.notify(root and "bff: index still building" or NO_CONFIG, vim.log.levels.INFO)
  end
  local items = {}
  for _, op in pairs(st.data.ops) do
    local t = op_target(op)
    if t then
      local users = vim.tbl_map(function(idx)
        return route_label(st.data.routes[idx])
      end, op.routes)
      table.insert(
        items,
        item(root, op_label(op), #users > 0 and ("◀ " .. table.concat(users, " | ")) or "◌ unused", t.file, t.line)
      )
    end
  end
  table.sort(items, function(a, b)
    return a.label < b.label
  end)
  pick("Upstream ops <- BFF routes", items)
end

function M.toggle()
  M.enabled = not M.enabled
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      M.render(buf)
    end
  end
  vim.notify("bff: annotations " .. (M.enabled and "on" or "off"))
end

function M.reindex()
  local root = M.root_for(0)
  if root then
    M.index(root, { notify = true })
  else
    vim.notify(NO_CONFIG, vim.log.levels.INFO)
  end
end
M.reload = M.reindex

-- ---------------------------------------------------------------------------
-- Setup: detect the repo layout, show it in an editable float, save on :w
-- ---------------------------------------------------------------------------
-- Drop cached project records and redraw / reindex every loaded buffer.
local function refresh_all()
  projects = {}
  for root in pairs(state) do
    state[root] = nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
      local root = M.root_for(buf)
      if root and not state[root] then
        M.index(root, { notify = true })
      end
    end
  end
end

local function detect(info, cb)
  local node = node_bin()
  if not node then
    return vim.notify("bff: `node` not found on PATH", vim.log.levels.ERROR)
  end
  vim.notify("bff: scanning " .. info.top .. " …")
  vim.system(
    { node, indexer, "--detect", info.top },
    { text = true, env = { NODE_PATH = info.top .. "/node_modules:" .. info.key .. "/node_modules" } },
    vim.schedule_wrap(function(res)
      local ok, data = pcall(vim.json.decode, res.code == 0 and res.stdout or "")
      if not ok or type(data) ~= "table" then
        return vim.notify("bff: detect failed:\n" .. vim.trim(res.stderr or ""):sub(1, 800), vim.log.levels.ERROR)
      end
      cb(data)
    end)
  )
end

local function validate(entry)
  if type(entry) ~= "table" or type(entry.projects) ~= "table" or #entry.projects == 0 then
    return "expected { \"projects\": [ ... ] } with at least one project"
  end
  for i, p in ipairs(entry.projects) do
    if type(p) ~= "table" or type(config.get(p, "tsconfig")) ~= "string" then
      return ("project %d: \"tsconfig\" (string) is required"):format(i)
    end
  end
end

local function open_float(info, entry)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_name(buf, "bff-setup://" .. info.key)
  local function fill(e)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(config.encode(e), "\n"))
    vim.bo[buf].modified = false
  end
  fill(entry)
  vim.bo[buf].filetype = "json"

  local width = math.min(100, vim.o.columns - 8)
  local height = math.min(vim.api.nvim_buf_line_count(buf) + 1, vim.o.lines - 8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = "rounded",
    title = " BFF links: " .. vim.fs.basename(info.key) .. " ",
    title_pos = "center",
    footer = " :w / <CR> save · q cancel · R re-detect ",
    footer_pos = "center",
  })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      local ok, parsed = pcall(vim.json.decode, text)
      local err = not ok and ("invalid JSON: " .. tostring(parsed)) or validate(parsed)
      if err then
        return vim.notify("bff: " .. err, vim.log.levels.ERROR)
      end
      local data = config.load()
      data.version = data.version or 1
      data.repos[info.key] = parsed
      config.save(data)
      vim.bo[buf].modified = false
      close()
      vim.notify("bff: saved " .. #parsed.projects .. " project(s) to " .. config.path)
      refresh_all()
    end,
  })

  local map = function(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  map("<CR>", function()
    vim.cmd.write()
  end)
  map("q", close)
  map("R", function()
    detect(info, function(found)
      if vim.api.nvim_buf_is_valid(buf) then
        fill(found)
        vim.bo[buf].modified = true
      end
    end)
  end)
end

--- :BffSetup — scan the repo of the current buffer (or the tab cwd), or edit its saved entry.
--- With `redetect`, ignore the saved entry and scan again.
function M.setup_repo(redetect)
  local name = vim.api.nvim_buf_get_name(0)
  local dir = (name ~= "" and vim.bo.buftype == "") and vim.fs.dirname(name) or vim.fn.getcwd()
  local info = config.repo_info(dir)
  if not info then
    return vim.notify("bff: " .. dir .. " is not inside a git repo or npm package", vim.log.levels.WARN)
  end
  local entry = not redetect and config.entry(info.key)
  if entry then
    return open_float(info, entry)
  end
  detect(info, function(found)
    if #(found.projects or {}) == 0 then
      return vim.notify("bff: no TypeScript project found in " .. info.top, vim.log.levels.WARN)
    end
    open_float(info, found)
  end)
end

--- Start indexing every configured project of the repo `dir` belongs to (worktree switch).
function M.prewarm(dir)
  for _, p in ipairs(config.projects(dir)) do
    projects[p.root] = p
    if not state[p.root] then
      M.index(p.root)
    end
  end
end

function M.open_config()
  if not vim.uv.fs_stat(config.path) then
    config.save(config.load())
  end
  vim.cmd.edit(vim.fn.fnameescape(config.path))
end

-- ---------------------------------------------------------------------------
-- Staleness: newest mtime among the files the index reads vs when that index started.
-- A few hundred stats (generated clients in watchSkip skipped), throttled, so it is cheap
-- enough for BufEnter.
-- ---------------------------------------------------------------------------
local WATCH_EXT = { ts = true, tsx = true, js = true, mjs = true, cjs = true, json = true }

local function newest_mtime(p)
  local root, newest = p.root, 0
  local skip = {}
  for _, d in ipairs(config.get(p.project, "watchSkip") or {}) do
    skip[vim.fs.normalize(root .. "/" .. d)] = true
  end
  local function consider(path)
    local st = vim.uv.fs_stat(path)
    if st then
      newest = math.max(newest, st.mtime.sec + st.mtime.nsec / 1e9)
    end
    return st
  end
  for _, w in ipairs(config.get(p.project, "watch") or { "." }) do
    local base = w == "." and root or vim.fs.normalize(root .. "/" .. w)
    local st = consider(base)
    if st and st.type == "directory" then
      for name, kind in vim.fs.dir(base, {
        depth = 20,
        skip = function(d)
          local leaf = vim.fs.basename(d)
          return leaf ~= "node_modules" and leaf:sub(1, 1) ~= "." and not skip[base .. "/" .. d]
        end,
      }) do
        if kind == "file" and WATCH_EXT[name:match("%.(%w+)$") or ""] then
          consider(base .. "/" .. name)
        end
      end
    end
  end
  return newest
end

function M.is_stale(root)
  local st = state[root]
  if not (st and st.started) then
    return true
  end
  local now = vim.uv.now()
  if st.checked and now - st.checked < 1000 then
    return st.stale_cache
  end
  st.checked = now
  local started = st.started.sec + st.started.nsec / 1e9
  st.stale_cache = not projects[root] or newest_mtime(projects[root]) > started
  return st.stale_cache
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
local PATTERNS = { "*.ts", "*.tsx", "*.js", "*.mjs", "*.cjs", "*.json" }

function M.setup()
  local group = vim.api.nvim_create_augroup("bff_links", { clear = true })
  local timers = {}

  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = M.set_highlights })

  -- Opening / returning to a buffer: reindex if anything changed on disk since the last index
  -- (edits from another pane, git checkout, npm run generate…), otherwise just redraw.
  -- When stale, drawing waits for the fresh index so marks never land on old line numbers.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter" }, {
    group = group,
    pattern = PATTERNS,
    callback = function(ev)
      local root = M.root_for(ev.buf)
      if not root then
        return
      end
      if M.is_stale(root) then
        M.index(root)
      else
        M.render(ev.buf)
      end
    end,
  })

  -- Reindex after saves that can change the graph; debounced so :wa is one run.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = PATTERNS,
    callback = function(ev)
      local root = M.root_for(ev.buf)
      if not root then
        return
      end
      if timers[root] then
        timers[root]:stop()
      end
      timers[root] = vim.defer_fn(function()
        timers[root] = nil
        M.index(root)
      end, 400)
    end,
  })

  vim.api.nvim_create_user_command("BffLinks", M.links, { desc = "BFF links at cursor" })
  vim.api.nvim_create_user_command("BffRoutes", M.routes, { desc = "All BFF routes with upstream" })
  vim.api.nvim_create_user_command("BffUpstream", M.upstream, { desc = "All upstream ops with BFF users" })
  vim.api.nvim_create_user_command("BffToggle", M.toggle, { desc = "Toggle BFF annotations" })
  vim.api.nvim_create_user_command("BffIndex", M.reindex, { desc = "Rebuild BFF index" })
  vim.api.nvim_create_user_command("BffReload", M.reload, { desc = "Reload BFF annotations" })
  vim.api.nvim_create_user_command("BffSetup", function(o)
    M.setup_repo(o.bang)
  end, { bang = true, desc = "Detect / edit BFF links config for this repo (! = re-detect)" })
  vim.api.nvim_create_user_command("BffConfig", M.open_config, { desc = "Open the local BFF links config" })

  -- Hand edits of the local config file apply at once.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = config.path,
    callback = function()
      config.reload()
      refresh_all()
    end,
  })

  -- Buffers already open when this loads (lazy `event` fired on the first one).
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local root = vim.api.nvim_buf_is_loaded(buf) and M.root_for(buf)
    if root and not state[root] then
      M.index(root)
    end
  end
end

return M
