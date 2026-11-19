-- ~/.config/nvim/lua/plugins/treesitter.lua
-- On the nvim-treesitter `main` branch parsers aren't bundled -- a language only gets
-- syntax highlighting once its parser is installed. LazyVim merges (extends) this list
-- via opts_extend, so this ADDS to the langs it already installs, and highlighting then
-- shows everywhere including the diff view.
return {
  "nvim-treesitter/nvim-treesitter",
  opts = {
    ensure_installed = { "rust", "turtle" },
  },
}
