-- No turtle ftplugin ships with Neovim and ts-comments.nvim has no entry for it,
-- so gcc/gc have nothing to work with without this.
vim.bo.commentstring = "# %s"
