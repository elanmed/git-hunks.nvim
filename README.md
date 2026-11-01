# `git-hunks.nvim`

A minimal plugin to view, navigate, and reset git hunks. Also includes a diff view for comparing any two git file locations.

## Features

- 2 source files (~700 LOC), 1 test file (~700 LOC), no runtime dependencies
- Async diff computation via coroutines (no UI freezing)
- Signs update on every edit with debouncing (300ms)
- Watches `.git/index` and `.git/HEAD` for external changes (e.g. `git checkout`, `git stash`, `git reset`)
- Navigate to next/previous hunk with wrapping
- Reset a single hunk, a visual selection of hunks, or the entire file

## Example config

```lua
vim.keymap.set("n", "]h", "<Plug>GitHunksNextHunk")
vim.keymap.set("n", "[h", "<Plug>GitHunksPrevHunk")

vim.keymap.set("n", "gh", "<Plug>GitHunksResetHunk")
vim.keymap.set("v", "gh", "<Plug>GitHunksResetHunk")
vim.keymap.set("n", "gH", "<Plug>GitHunksResetFile")
```

## Plug remaps

### `<Plug>GitHunksNextHunk`

Navigate to the next hunk. Wraps to the first hunk if none remain.

### `<Plug>GitHunksPrevHunk`

Navigate to the previous hunk. Wraps to the last hunk if none remain.

### `<Plug>GitHunksResetHunk`

- In normal mode: reset the hunk on the current line
- In visual mode: reset all hunks that overlap with the visual selection

### `<Plug>GitHunksResetFile`

Reset the entire file to the index version.

## API

### `require("git-hunks").setup()`

Initializes the plugin. The `plugin/git-hunks.lua` entrypoint calls this automatically when the plugin loads.

The module also exposes `unpack_hunk(hunk)`, which converts a `vim.text.diff()` hunk index tuple into insertion, deletion, or change ranges, and `read_index_file(rel_filename)`, which returns a `vim.async.Task<string?>` containing the Git-index file contents or `nil` if it cannot be read. These helpers are for advanced use; normal configuration does not need them.

## Highlight groups

| Group            | Default link | Used for       |
| ---------------- | ------------ | -------------- |
| `DiffSignDelete` | `DiffDelete` | Deleted lines  |
| `DiffSignAdd`    | `DiffAdd`    | Added lines    |
| `DiffSignChange` | `DiffChange` | Modified lines |

## Autocommand events

### `User GitIndexChanged`

Fired when `.git/index` changes on disk (e.g. `git add`, `git checkout`, `git stash`, `git reset`).

### `User GitHeadChanged`

Fired when `.git/HEAD` changes on disk (e.g. `git checkout <branch>`, `git reset --hard`).
