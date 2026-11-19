# my-editor

A personal Neovim config on top of [LazyVim](https://www.lazyvim.org/).
This README describes only what this repo adds or changes. For the LazyVim defaults, see the LazyVim docs.

- Leader key: `<Space>`
- Plugin manager: [lazy.nvim](https://github.com/folke/lazy.nvim)
- Colour scheme: [dracula.nvim](https://github.com/Mofiqul/dracula.nvim)
- Neovim 0.12 or later is recommended (the BFF tools use `vim.json.encode` with `indent`).

## Command and keymap matrix

| Keys / command | Mode | Purpose | Defined in |
|---|---|---|---|
| **BFF links** | | | |
| `:BffSetup` / `<leader>rs` | n | Scan the current repo and show the detected BFF layout in a float. Save it with `:w` or `<CR>`. If the repo has a saved entry, the float opens that entry for edit. | `lua/tools/bff/init.lua` |
| `:BffSetup!` | n | Ignore the saved entry and scan the repo again. | `lua/tools/bff/init.lua` |
| `:BffConfig` | n | Open the local config file `bff-links.local.json`. A save applies the changes at once. | `lua/tools/bff/init.lua` |
| `:BffLinks` / `<leader>rr` | n | Show a picker with the links at the cursor (route → hops → upstream, or upstream → routes). | `lua/tools/bff/init.lua` |
| `:BffRoutes` / `<leader>rR` | n | Show a picker with all BFF routes and the upstream calls of each route. | `lua/tools/bff/init.lua` |
| `:BffUpstream` / `<leader>rU` | n | Show a picker with all upstream operations and the BFF routes that use them. | `lua/tools/bff/init.lua` |
| `:BffToggle` / `<leader>rt` | n | Show or hide the BFF annotations. | `lua/tools/bff/init.lua` |
| `:BffReload` / `<leader>rl` | n | Rebuild the index and draw the annotations again. | `lua/tools/bff/init.lua` |
| `:BffIndex` / `<leader>ri` | n | Rebuild the index of the current project. | `lua/tools/bff/init.lua` |
| **Worktrees** | | | |
| `:Worktrees` / `<leader>gW` | n | Show all git worktrees of the current repo and open the selected one in its own tab. | `lua/tools/worktree.lua` |
| `<leader>gD` | n | Open a diff of the current worktree against the trunk (`origin/HEAD`, else `origin/main`, else `origin/master`). | `lua/tools/worktree.lua` |
| **Diff review** | | | |
| `:ClaudeChanges` / `<leader>gC` | n | Open or close the diffview of the working-tree changes. | `lua/plugins/diffview.lua` |
| `<leader>e` (in diffview) | n | Show or hide the changed-files panel. | `lua/plugins/diffview.lua` |
| `o`, `<C-o>` (in diffview) | n | Open the real file for edit. | `lua/plugins/diffview.lua` |
| **Git signs** | | | |
| `<leader>uhl` | n | Toggle the line highlight of changed lines. | `lua/plugins/gitsigns.lua` |
| `<leader>uhw` | n | Toggle the word diff. | `lua/plugins/gitsigns.lua` |
| `<leader>uhn` | n | Toggle the line-number highlight. | `lua/plugins/gitsigns.lua` |
| `<leader>uhd` | n | Toggle the display of deleted lines. | `lua/plugins/gitsigns.lua` |
| `<leader>uhi` | n | Show the hunk inline. | `lua/plugins/gitsigns.lua` |
| **Movement** | | | |
| `<leader>pv` | n | Open netrw (`:Ex`). | `lua/thehazeneer/lazy.lua` |
| `j`, `k`, `n`, `N` | n | Move, then put the cursor line in the middle of the window. | `lua/thehazeneer/lazy.lua` |
| `<C-u>`, `<C-d>` | n | Scroll half a page, then put the cursor line in the middle. | `lua/thehazeneer/remap.lua` |

## BFF links

BFF links show how the routes of a TypeScript BFF (backend for frontend) connect to the upstream services that they call. The supported frameworks are **TSOA**, **NestJS** and **Express**.

### What you see

| Location | Annotation |
|---|---|
| Route handler | Lines above the handler show each upstream call that the route reaches. The end of the line shows the full route. |
| Service or helper | Lines above it show the BFF routes that reach it. |
| Upstream call site | The end of the line shows the upstream method and URL. |
| SDK file or upstream spec | The end of the line shows the BFF routes that use the operation, or "not used by BFF". |
| The project's own OpenAPI spec | The end of the line shows the handler and its first upstream call. |

Gold text is a route that the BFF serves. Red-to-purple text is an upstream route that the BFF calls.

The upstream types are:
- Generated OpenAPI SDKs (hey-api `sdk.gen.ts` style), linked to their spec files.
- npm client packages (names that end in `-client` or `-sdk`).
- Prisma calls.
- AWS SDK v3 `send()` calls.
- `fetch()` calls.

### First use in a repo

1. Open a file of the BFF repo.
2. Run `:BffSetup` (or push `<leader>rs`).
3. Examine the detected values in the float. Change them if necessary.
4. Push `<CR>` or type `:w` to save.

The index starts after the save. You do this one time for each repo. All worktrees of the repo use the same entry, because the entry key is the main checkout of the repo.

### The local config file

The config is in `bff-links.local.json` in the Neovim config dir. `.gitignore` excludes `*.local.json`, so the file stays on your machine. It contains local paths and project names, so do not commit it.

```json
{
  "version": 1,
  "repos": {
    "/abs/path/of/main/checkout": {
      "projects": [{
        "dir": ".",
        "tsconfig": "tsconfig.json",
        "frameworks": ["tsoa", "express"],
        "basePath": "api/v1",
        "source": ["src"],
        "exclude": ["src/generated", "**/*.test.ts", "**/*.spec.ts"],
        "sdk": [{ "file": "src/generated/openapi/foo-api/sdk.gen.ts", "api": "foo", "spec": "openapi/foo.json" }],
        "ownSpec": "src/generated/tsoa/swagger.json",
        "prisma": "src/generated/prisma",
        "clientPackages": ["@scope/foo-client"],
        "aws": true,
        "fetch": true,
        "watch": ["src", "openapi", "tsconfig.json"],
        "watchSkip": ["src/generated/prisma"]
      }]
    }
  }
}
```

All paths in a project are relative to `dir`, and `dir` is relative to the worktree root. A monorepo can have more than one project.

### How it works

- `lua/tools/bff/indexer.cjs` uses the TypeScript compiler API and the type checker. It runs with the repo's own `typescript` package. If a worktree has no `node_modules`, it uses the packages of the main checkout.
- `node indexer.cjs --detect <repo>` finds the projects and writes the layout as JSON.
- `node indexer.cjs <worktree> '<project-json>'` writes the index: routes, call sites, operations and graph nodes.
- `lua/tools/bff/init.lua` draws the index with extmarks. It builds the index again after a save, and when files change on disk.
- `lua/tools/bff/config.lua` reads and writes the local config file.

## Worktree switcher

`<leader>gW` (or `:Worktrees`) shows the worktrees that you can open:

- If the tab cwd is in a git repo, the list shows all worktrees of that repo. `[main]` marks the main checkout, and `*` marks the current worktree.
- If the tab cwd is a folder of repos (not a git repo), the list shows the worktrees of each child repo.

Each worktree opens in its own tab with a tab-local cwd. Thus the LSP and linters use the `node_modules` and generated files of that worktree. If the repo has a BFF links entry, the index starts when the tab opens.

## Other changes

| File | Change |
|---|---|
| `lua/thehazeneer/autoreload.lua` | Reloads a buffer, with no prompt, when an external tool (for example Claude Code in another terminal pane) changes the file. It does not reload a buffer with unsaved changes. Gitsigns then shows the change. |
| `lua/plugins/diffview.lua` | Diffview with treesitter highlight in the diff buffers and a horizontal two-pane layout. |
| `lua/plugins/turtle.lua`, `ftplugin/turtle.lua` | Turtle / RDF (`.ttl`) support: the filetype, the language server, and the comment string. |
| `lua/plugins/treesitter.lua` | Adds the `rust` and `turtle` parsers. |
| `lua/plugins/neo-tree-config.lua` | Neo-tree shows git-ignored files. |
| `lua/plugins/telescope.lua` | Telescope with `telescope-fzf-native`. |
| `lazyvim.json` | The enabled LazyVim extras (AI, languages, formatting, lint, UI and git tools). |

## Tests

```sh
nvim --headless "+Lazy! load bff-links" +qa   # load test, no errors expected
git check-ignore -v bff-links.local.json       # the local config is ignored
```
