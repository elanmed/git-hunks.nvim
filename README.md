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

### `M.unpack_indices_hunk`

```lua
--- @class HunkOldRange
--- @field start_old_1i integer
--- @field start_old_0i integer
--- @field count_old integer
--- @field end_old_1i_excl integer
--- @field end_old_1i_incl integer
--- @field end_old_0i_excl integer
--- @field end_old_0i_incl integer

--- @class HunkNewRange
--- @field start_new_1i integer
--- @field start_new_0i integer
--- @field count_new integer
--- @field end_new_1i_excl integer
--- @field end_new_1i_incl integer
--- @field end_new_0i_excl integer
--- @field end_new_0i_incl integer

--- @class InsertionHunk : HunkNewRange
--- @field kind "insertion"
--- @field after_old_1i integer
--- @field is_leading boolean

--- @class DeletionHunk : HunkOldRange
--- @field kind "deletion"
--- @field after_new_1i integer
--- @field after_new_1i_visible integer
--- @field is_leading boolean

--- @class ChangeHunk : HunkOldRange, HunkNewRange
--- @field kind "change"

--- @alias UnpackedHunk InsertionHunk | DeletionHunk | ChangeHunk

--- @alias DiffHunk { [1]: integer, [2]: integer, [3]: integer, [4]: integer }
--- @param hunk DiffHunk
--- @return UnpackedHunk
M.unpack_indices_hunk = function(hunk)
-- ...
end
```

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
