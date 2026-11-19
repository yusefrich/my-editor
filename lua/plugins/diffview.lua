-- ~/.config/nvim/lua/plugins/diffview.lua
-- Manual "Claude changes" review view. NOT auto-opened on startup -- nvim opens normally.
-- Open/close the whole view with :ClaudeChanges or <leader>gC (a toggle).
-- Inside the view: <leader>e toggles the changed-files tree on the left (like the file
-- explorer), and `q` on an entry / <leader>gC also close.
local function toggle_changes()
  local ok, lib = pcall(require, "diffview.lib")
  if ok and lib.get_current_view() then
    vim.cmd("DiffviewClose")
  else
    vim.cmd("DiffviewOpen")
  end
end

return {
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewToggleFiles", "DiffviewFocusFiles", "DiffviewFileHistory" },
  keys = {
    { "<leader>gC", toggle_changes, desc = "Claude changes: toggle diff view" },
  },
  init = function()
    -- Per request: only add the command if it isn't already taken; otherwise keep theirs.
    if vim.fn.exists(":ClaudeChanges") == 0 then
      vim.api.nvim_create_user_command("ClaudeChanges", toggle_changes,
        { desc = "Toggle the Claude changes (diffview) view" })
    else
      vim.schedule(function()
        vim.notify(":ClaudeChanges already exists -- keeping the existing command", vim.log.levels.WARN)
      end)
    end
  end,
  opts = function()
    local actions = require("diffview.actions")
    -- On the treesitter `main` branch, highlighting only turns on when something calls
    -- vim.treesitter.start(). Diffview sets the filetype on its diff buffers but never
    -- starts treesitter, so they render single-colored. Start it ourselves per diff buf.
    local function start_ts(bufnr)
      if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
        return
      end
      local ft = vim.bo[bufnr].filetype
      if ft == "" then
        return
      end
      local lang = vim.treesitter.language.get_lang(ft) or ft
      pcall(vim.treesitter.start, bufnr, lang)
    end
    -- <leader>e toggles the changed-files panel in every diffview context.
    local toggle_panel = { "n", "<leader>e", actions.toggle_files, { desc = "Toggle changed-files panel" } }
    -- Open the actual file for editing, leaving the split diff view.
    local open_file = { "n", "o", actions.goto_file_edit, { desc = "Open the real file (edit)" } }
    -- <C-o> is vim's jumplist-back and blows away the panel with a stray buffer.
    -- Neutralize it inside diffview: make it open the real file instead.
    local open_file_ctrl = { "n", "<C-o>", actions.goto_file_edit, { desc = "Open the real file (edit)" } }
    -- NOTE: default <Tab>/<S-Tab> (select_next/prev_entry) and <CR> (open the diff) are
    -- preserved -- diffview merges these into its defaults rather than replacing them.
    return {
      -- Show real syntax highlighting on the code AND the green/red add/remove
      -- backgrounds at the same time (blended diff + treesitter).
      enhanced_diff_hl = true,
      view = { default = { layout = "diff2_horizontal" } },
      hooks = {
        -- Turn on treesitter syntax highlighting for every diff buffer, both when it's
        -- first read and when it enters a window (covers all layouts / lazy loads).
        diff_buf_read = function(bufnr) start_ts(bufnr) end,
        diff_buf_win_enter = function(bufnr) start_ts(bufnr) end,
      },
      keymaps = {
        view = { toggle_panel, open_file_ctrl },
        file_panel = { toggle_panel, open_file, open_file_ctrl },
        file_history_panel = { toggle_panel, open_file, open_file_ctrl },
      },
    }
  end,
}
