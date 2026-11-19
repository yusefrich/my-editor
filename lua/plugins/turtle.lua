-- ~/.config/nvim/lua/plugins/turtle.lua
-- Turtle / RDF (.ttl) support. The treesitter parser is requested in treesitter.lua,
-- the commentstring is set in ftplugin/turtle.lua.
return {
  -- Stardog's turtle-language-server (diagnostics + hover). Its mason registry entry has no
  -- `neovim.lspconfig` field, so mason-lspconfig never maps turtle_ls -> this package and
  -- LazyVim won't auto-install it. Ask for it by name.
  {
    "mason-org/mason.nvim",
    opts = { ensure_installed = { "turtle-language-server" } },
  },
  {
    "neovim/nvim-lspconfig",
    init = function()
      -- Neovim's builtin .ttl detection is a heuristic: unless line 1 starts with
      -- @prefix/@base it classifies the file as `teraterm`. We only write RDF, so pin it.
      vim.filetype.add({ extension = { ttl = "turtle" } })
    end,
    opts = {
      servers = {
        turtle_ls = {
          -- lspconfig's default cmd scans $PATH when the config module loads, which races
          -- mason's PATH injection. Point at the mason bin directly. Invoked via `node` so
          -- it works whether or not the npm shim carries a shebang.
          cmd = {
            "node",
            vim.fn.stdpath("data") .. "/mason/bin/turtle-language-server",
            "--stdio",
          },
        },
      },
    },
  },
}
