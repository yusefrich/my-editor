-- BFF route <-> upstream annotations for TypeScript BFFs (lua/tools/bff).
-- Run :BffSetup once per repo; the result lives in the git-ignored bff-links.local.json.
-- Local "plugin" so lazy owns loading; the dir holds no plugin/ files, so adding it to rtp is inert.
local function bff()
  return require("tools.bff")
end

return {
  {
    name = "bff-links",
    dir = vim.fn.stdpath("config") .. "/lua/tools/bff",
    event = {
      "BufReadPost *.ts",
      "BufReadPost *.tsx",
      "BufReadPost *.js",
      "BufReadPost *.mjs",
      "BufReadPost *.cjs",
      "BufReadPost *.json",
    },
    cmd = { "BffLinks", "BffRoutes", "BffUpstream", "BffToggle", "BffIndex", "BffReload", "BffSetup", "BffConfig" },
    config = function()
      bff().setup()
    end,
    keys = {
      { "<leader>rr", function() bff().links() end, desc = "BFF links at cursor" },
      { "<leader>rR", function() bff().routes() end, desc = "BFF routes -> upstream" },
      { "<leader>rU", function() bff().upstream() end, desc = "Upstream ops <- BFF routes" },
      { "<leader>rt", function() bff().toggle() end, desc = "Toggle BFF annotations" },
      { "<leader>rl", function() bff().reload() end, desc = "Reload BFF annotations" },
      { "<leader>ri", function() bff().reindex() end, desc = "Rebuild BFF index" },
      { "<leader>rs", function() bff().setup_repo() end, desc = "BFF setup for this repo" },
    },
  },
  {
    "folke/which-key.nvim",
    optional = true,
    opts = { spec = { { "<leader>r", group = "bff routes" } } },
  },
}
