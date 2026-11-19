-- Keymaps for lua/tools/worktree.lua. Attached to the snacks spec so lazy owns the
-- lazy-loading and no extra plugin is pulled in.
return {
  {
    "folke/snacks.nvim",
    init = function()
      vim.api.nvim_create_user_command("Worktrees", function()
        require("tools.worktree").browse()
      end, { desc = "Switch git worktree" })
    end,
    keys = {
      {
        "<leader>gW",
        function()
          require("tools.worktree").browse()
        end,
        desc = "Switch git worktree",
      },
      {
        "<leader>gD",
        function()
          require("tools.worktree").diff_trunk()
        end,
        desc = "Diff worktree vs trunk",
      },
    },
  },
}
