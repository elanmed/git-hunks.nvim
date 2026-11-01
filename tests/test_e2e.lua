local MiniTest = require "mini.test"
local new_set = MiniTest.new_set
local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local expect_hunks = MiniTest.new_expectation(
  "buffer has diff hunks",
  --- @param bufnr integer
  --- @param timeout? integer
  function(bufnr, timeout)
    timeout = timeout or 1000
    local ns_id = child.api.nvim_create_namespace "GitHunks"
    return child.lua_func(
      --- @param timeout_arg integer
      --- @param bufnr_arg integer
      --- @param ns_id_arg integer
      function(timeout_arg, bufnr_arg, ns_id_arg)
        return vim.wait(timeout_arg, function()
          return #vim.api.nvim_buf_get_extmarks(bufnr_arg, ns_id_arg, 0, -1, {}) > 0
        end)
      end,
      timeout,
      bufnr,
      ns_id
    )
  end,
  --- @param bufnr integer
  --- @param timeout? integer
  function(bufnr, timeout)
    timeout = timeout or 1000
    local ns_id = child.api.nvim_create_namespace "GitHunks"
    local count = #child.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {})
    return string.format(
      "Expected buffer %s to have GitHunks extmarks after %d ms, found %d",
      tostring(bufnr),
      timeout,
      count
    )
  end
)

local expect_cursor = MiniTest.new_expectation(
  "cursor at line",
  --- @param line integer
  --- @param col? integer
  function(line, col)
    local cursor = child.api.nvim_win_get_cursor(0)
    if col == nil then
      return cursor[1] == line
    end
    return cursor[1] == line and cursor[2] == col
  end,
  --- @param line integer
  --- @param col? integer
  function(line, col)
    local cursor = child.api.nvim_win_get_cursor(0)
    if col == nil then
      return string.format("Expected cursor at line %d, actual line %d", line, cursor[1])
    end
    return string.format(
      "Expected cursor at line %d col %d, actual line %d col %d",
      line,
      col,
      cursor[1],
      cursor[2]
    )
  end
)

--- @param content string
local function mock_read_index_file(content)
  child.lua_func(
    --- @param content_arg string
    function(content_arg)
      --- @type table
      local M_arg = M
      M_arg.read_index_file = function()
        return vim.async.run(
          --- @return string?
          function()
            return content_arg
          end
        )
      end
    end,
    content
  )
end

--- @param files table<string, string>
local function mock_read_index_files(files)
  child.lua_func(
    --- @param files_arg table<string, string>
    function(files_arg)
      --- @type table
      local M_arg = M
      --- @param rel_filename_arg string
      M_arg.read_index_file = function(rel_filename_arg)
        return vim.async.run(
          --- @return string?
          function()
            return files_arg[rel_filename_arg]
          end
        )
      end
    end,
    files
  )
end

local expect_sign = MiniTest.new_expectation(
  "line has expected sign",
  --- @param bufnr integer
  --- @param line_1i integer
  --- @param hl_group string
  function(bufnr, line_1i, hl_group)
    local ns_id = child.api.nvim_create_namespace "GitHunks"
    local marks = child.api.nvim_buf_get_extmarks(
      bufnr,
      ns_id,
      { line_1i - 1, 0 },
      { line_1i - 1, -1 },
      { details = true }
    )
    if #marks == 0 then
      return false
    end
    return marks[1][4].number_hl_group == hl_group
  end,
  --- @param bufnr integer
  --- @param line_1i integer
  --- @param hl_group string
  function(bufnr, line_1i, hl_group)
    local ns_id = child.api.nvim_create_namespace "GitHunks"
    local marks = child.api.nvim_buf_get_extmarks(
      bufnr,
      ns_id,
      { line_1i - 1, 0 },
      { line_1i - 1, -1 },
      { details = true }
    )
    if #marks == 0 then
      return string.format("Expected %s sign on line %d, found no extmarks", hl_group, line_1i)
    end
    return string.format(
      "Expected %s sign on line %d, found %s",
      hl_group,
      line_1i,
      marks[1][4].number_hl_group or "none"
    )
  end
)

local expect_lines = MiniTest.new_expectation(
  "buffer lines",
  --- @param expected_lines string[]
  function(expected_lines)
    return vim.deep_equal(child.api.nvim_buf_get_lines(0, 0, -1, false), expected_lines)
  end,
  --- @param expected_lines string[]
  function(expected_lines)
    local actual_lines = child.api.nvim_buf_get_lines(0, 0, -1, false)
    return string.format(
      "Expected lines:\n%s\nActual lines:\n%s",
      vim.inspect(expected_lines),
      vim.inspect(actual_lines)
    )
  end
)

local expect_state = MiniTest.new_expectation(
  "state condition met",
  --- @param predicate fun(): boolean
  --- @param timeout? integer
  function(predicate, timeout)
    timeout = timeout or 1000
    return vim.wait(timeout, predicate)
  end,
  --- @param _ fun(): boolean
  --- @param timeout? integer
  function(_, timeout)
    timeout = timeout or 1000
    return string.format("Expected state condition to be met after %d ms", timeout)
  end
)

--- @param rel_path string
--- @param lines string[]
local function set_worktree_buffer(rel_path, lines)
  child.bo.buftype = ""
  child.bo.readonly = false
  child.bo.modifiable = true
  child.api.nvim_buf_set_name(0, child.fn.getcwd() .. "/" .. rel_path)
  child.api.nvim_buf_set_lines(0, 0, -1, true, lines)
end

local function trigger_diff_update()
  child.cmd "doautocmd BufEnter"
end

--- @param index_content string
--- @param worktree_lines string[]
--- @return integer
local function prepare_diff(index_content, worktree_lines)
  mock_read_index_file(index_content)
  set_worktree_buffer("test.txt", worktree_lines)
  trigger_diff_update()

  local bufnr = child.api.nvim_get_current_buf()
  expect_hunks(bufnr)
  return bufnr
end

local T = new_set {
  hooks = {
    pre_case = function()
      child.restart { "-u", "scripts/minimal_init.lua" }
      child.lua_func(function()
        M = require "git-hunks"
        M.setup()
      end)
    end,
    post_once = child.stop,
  },
}

T["setup"] = new_set()

T["setup"]["creates global keymaps"] = function()
  local descriptions = child.lua_func(function()
    return {
      next = vim.fn.maparg("<Plug>GitHunksNextHunk", "n", false, true).desc,
      prev = vim.fn.maparg("<Plug>GitHunksPrevHunk", "n", false, true).desc,
      reset_normal = vim.fn.maparg("<Plug>GitHunksResetHunk", "n", false, true).desc,
      reset_visual = vim.fn.maparg("<Plug>GitHunksResetHunk", "x", false, true).desc,
      reset_file = vim.fn.maparg("<Plug>GitHunksResetFile", "n", false, true).desc,
    }
  end)

  eq(descriptions, {
    next = "Navigate to the next hunk",
    prev = "Navigate to the prev hunk",
    reset_normal = "Reset the hunk on the current line",
    reset_visual = "Reset the visually selected hunk",
    reset_file = "Reset the entire file",
  })
end

T["setup"]["creates global autocommands"] = function()
  local groups = child.lua_func(function()
    local get_autocmds = vim.api.nvim_get_autocmds
    return {
      highlights = #get_autocmds { group = "GitHunksHighlights" },
      text = #get_autocmds { group = "GitHunksTextEvents" },
      buffers = #get_autocmds { group = "GitHunksBufEvents" },
      index = get_autocmds({ group = "GitHunksIndexEvents" })[1].pattern,
      cleanup = get_autocmds({ group = "GitHunksCleanup" })[1].event,
      watcher_cleanup = get_autocmds({ group = "GitHunksWatcherCleanup" })[1].event,
    }
  end)

  eq(groups, {
    highlights = 1,
    text = 2,
    buffers = 3,
    index = "GitIndexChanged",
    cleanup = "BufDelete",
    watcher_cleanup = "VimLeavePre",
  })
end

T["setup"]["creates one watcher, dispatches Git events, and closes it on exit"] = function()
  child.restart { "-u", "scripts/minimal_init.lua" }
  child.lua_func(function()
    M = require "git-hunks"
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    _G.watcher_creations = 0
    _G.watcher_events = {}
    _G.test_watcher = {
      start = function(self, _, _, callback)
        self.callback = callback
        return true
      end,
      is_closing = function(self)
        return self.closed or false
      end,
      close = function(self)
        self.closed = true
      end,
    }
    vim.uv.new_fs_event = function()
      _G.watcher_creations = _G.watcher_creations + 1
      return _G.test_watcher
    end
    vim.api.nvim_create_autocmd("User", {
      pattern = { "GitIndexChanged", "GitHeadChanged" },
      callback = function(event)
        table.insert(_G.watcher_events, event.match)
      end,
    })

    M.setup()
    M.setup()
  end)

  expect_state(function()
    return child.lua_func(function()
      return _G.test_watcher.callback ~= nil
    end)
  end)
  local watcher_events = child.lua_func(function()
    _G.test_watcher.callback(nil, "index")
    _G.test_watcher.callback(nil, "HEAD")
    vim.wait(1000, function()
      return #_G.watcher_events == 2
    end)
    table.sort(_G.watcher_events)
    return _G.watcher_events
  end)
  eq(watcher_events, { "GitHeadChanged", "GitIndexChanged" })

  child.api.nvim_exec_autocmds("VimLeavePre", {})
  eq(
    child.lua_func(function()
      return { _G.watcher_creations, _G.test_watcher.closed }
    end),
    { 1, true }
  )
end

T["unpack hunk"] = new_set()

T["unpack hunk"]["returns variant-specific ranges and boundary positions"] = function()
  local hunks = child.lua_func(function()
    local insertion = M.unpack_hunk { 0, 0, 1, 1 }
    local deletion = M.unpack_hunk { 1, 1, 0, 0 }
    local change = M.unpack_hunk { 1, 1, 1, 1 }
    return {
      insertion = {
        kind = insertion.kind,
        after_old_1i = insertion.after_old_1i,
        after_old_1i_visible = insertion.after_old_1i_visible,
        start_new_1i = insertion.start_new_1i,
        end_new_1i_incl = insertion.end_new_1i_incl,
        is_leading = insertion.is_leading,
      },
      deletion = {
        kind = deletion.kind,
        start_old_1i = deletion.start_old_1i,
        end_old_1i_incl = deletion.end_old_1i_incl,
        after_new_1i = deletion.after_new_1i,
        after_new_1i_visible = deletion.after_new_1i_visible,
        is_leading = deletion.is_leading,
      },
      change = {
        kind = change.kind,
        start_old_1i = change.start_old_1i,
        start_new_1i = change.start_new_1i,
        end_old_1i_incl = change.end_old_1i_incl,
        end_new_1i_incl = change.end_new_1i_incl,
        is_leading = change.is_leading,
      },
    }
  end)

  eq(hunks, {
    insertion = {
      kind = "insertion",
      after_old_1i = 0,
      after_old_1i_visible = 1,
      start_new_1i = 1,
      end_new_1i_incl = 1,
      is_leading = true,
    },
    deletion = {
      kind = "deletion",
      start_old_1i = 1,
      end_old_1i_incl = 1,
      after_new_1i = 0,
      after_new_1i_visible = 1,
      is_leading = true,
    },
    change = {
      kind = "change",
      start_old_1i = 1,
      start_new_1i = 1,
      end_old_1i_incl = 1,
      end_new_1i_incl = 1,
      is_leading = false,
    },
  })
end

T["hunk navigation"] = new_set()

T["hunk navigation"]["quietly stays put when there are no hunks"] = function()
  mock_read_index_file [[line1
line2
]]
  set_worktree_buffer("test.txt", { "line1", "line2" })
  child.lua_func(function()
    local read_index_file = M.read_index_file
    _G.read_count = 0
    _G.notification_count = 0
    M.read_index_file = function(rel_filename)
      _G.read_count = _G.read_count + 1
      return read_index_file(rel_filename)
    end
    --- @diagnostic disable-next-line: duplicate-set-field
    vim.notify = function()
      _G.notification_count = _G.notification_count + 1
    end
  end)
  trigger_diff_update()

  expect_state(function()
    return child.lua_func(function()
      return _G.read_count >= 2
    end)
  end)
  child.lua_func(function()
    vim.wait(30)
  end)
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys "<Plug>GitHunksNextHunk"

  expect_cursor(2)
  eq(
    child.lua_func(function()
      return _G.notification_count
    end),
    0
  )
end

T["hunk navigation"]["jumps to next hunk"] = function()
  prepare_diff(
    [[line1
line2
line3
line4
line5
]],
    { "line1", "line2 changed", "line3", "line4 changed", "line5" }
  )

  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.type_keys "<Plug>GitHunksNextHunk"

  expect_cursor(2)
end

T["hunk navigation"]["jumps to previous hunk"] = function()
  prepare_diff(
    [[line1
line2
line3
line4
line5
]],
    { "line1", "line2 changed", "line3", "line4 changed", "line5" }
  )

  child.api.nvim_win_set_cursor(0, { 4, 0 })
  child.type_keys "<Plug>GitHunksPrevHunk"

  expect_cursor(2)
end

T["hunk navigation"]["wraps to first hunk after last"] = function()
  prepare_diff(
    [[line1
line2
line3
line4
line5
]],
    { "line1", "line2 changed", "line3", "line4 changed", "line5" }
  )

  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.type_keys "<Plug>GitHunksNextHunk"

  expect_cursor(2)
end

T["hunk navigation"]["navigates to a leading deletion"] = function()
  prepare_diff(
    [[gone
line1
line2
line3
line4
line5
]],
    { "line1", "line2", "line3 changed", "line4", "line5" }
  )

  child.api.nvim_win_set_cursor(0, { 3, 0 })
  child.type_keys "<Plug>GitHunksPrevHunk"

  expect_cursor(1)
end

T["hunk navigation"]["wraps to first leading deletion"] = function()
  prepare_diff(
    [[gone
line1
line2
]],
    { "line1", "line2" }
  )

  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys "<Plug>GitHunksNextHunk"

  expect_cursor(1)
end

T["hunk navigation"]["wraps to last hunk before first"] = function()
  prepare_diff(
    [[line1
line2
line3
line4
line5
]],
    { "line1", "line2 changed", "line3", "line4 changed", "line5" }
  )

  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.type_keys "<Plug>GitHunksPrevHunk"

  expect_cursor(4)
end

T["async state updates"] = new_set()

T["async state updates"]["ignores stale diff results after a newer update"] = function()
  local old_index = "old1\nold2\nold3\n"
  local new_index = "new1\nold2\nold3\n"
  child.lua_func(function(old_index_arg, new_index_arg)
    _G.read_count = 0
    M.read_index_file = function()
      _G.read_count = _G.read_count + 1
      local read_number = _G.read_count
      local content = new_index_arg
      if read_number == 1 or read_number == 4 then
        content = old_index_arg
      end
      return vim.async.run(function()
        if read_number == 1 then
          vim.async.sleep(100)
        end
        return content
      end)
    end
  end, old_index, new_index)
  set_worktree_buffer("test.txt", { "new1", "working", "old3" })

  trigger_diff_update()
  expect_state(function()
    return child.lua_func(function()
      return _G.read_count >= 1
    end)
  end)
  trigger_diff_update()
  expect_state(function()
    return child.lua_func(function()
      return _G.read_count >= 3
    end)
  end)
  child.lua_func(function()
    vim.wait(150)
  end)
  child.type_keys "<Plug>GitHunksResetFile"

  eq(
    child.lua_func(function()
      return _G.read_count
    end),
    3
  )
  expect_lines { "new1", "old2", "old3" }
end

T["hunk signs"] = new_set()

T["hunk signs"]["defines default highlight links"] = function()
  eq(child.api.nvim_get_hl(0, { name = "DiffSignDelete", link = true }), {
    default = true,
    link = "DiffDelete",
  })
  eq(child.api.nvim_get_hl(0, { name = "DiffSignAdd", link = true }), {
    default = true,
    link = "DiffAdd",
  })
  eq(child.api.nvim_get_hl(0, { name = "DiffSignChange", link = true }), {
    default = true,
    link = "DiffChange",
  })
end

T["hunk signs"]["preserves user highlight overrides across colorscheme changes"] = function()
  child.api.nvim_set_hl(0, "DiffSignAdd", { link = "Error" })
  child.api.nvim_exec_autocmds("ColorScheme", { pattern = "test" })

  eq(child.api.nvim_get_hl(0, { name = "DiffSignAdd", link = true }), { link = "Error" })
end

T["hunk signs"]["adds extmarks for added lines"] = function()
  local bufnr = prepare_diff(
    [[line1
line2
line3
]],
    { "line1", "line2", "line3", "line4" }
  )
  expect_sign(bufnr, 4, "DiffSignAdd")
end

T["hunk signs"]["adds extmarks for deleted lines"] = function()
  local bufnr = prepare_diff(
    [[line1
line2
line3
line4
]],
    { "line1", "line2", "line4" }
  )
  expect_sign(bufnr, 2, "DiffSignDelete")
end

T["hunk signs"]["marks a leading deletion on the first line"] = function()
  local bufnr = prepare_diff(
    [[gone
line1
line2
]],
    { "line1", "line2" }
  )
  expect_sign(bufnr, 1, "DiffSignDelete")
end

T["hunk signs"]["adds extmarks for changed lines"] = function()
  local bufnr = prepare_diff(
    [[line1
line2
line3
]],
    { "line1", "line2 changed", "line3" }
  )
  expect_sign(bufnr, 2, "DiffSignChange")
end

T["hunk signs"]["refreshes after the index changes"] = function()
  local bufnr = prepare_diff(
    [[line1
line2
]],
    { "line1", "line2", "line3" }
  )
  expect_sign(bufnr, 3, "DiffSignAdd")

  mock_read_index_file [[line1
line2
line3
]]
  child.api.nvim_exec_autocmds("User", { pattern = "GitIndexChanged" })

  expect_state(function()
    local ns_id = child.api.nvim_create_namespace "GitHunks"
    return #child.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {}) == 0
  end)
end

T["hunk signs"]["clears stale state when the index file is missing"] = function()
  local bufnr = prepare_diff(
    [[line1
line2
]],
    { "line1", "line2 changed" }
  )

  mock_read_index_files {}
  child.api.nvim_exec_autocmds("User", { pattern = "GitIndexChanged" })
  expect_state(function()
    local ns_id = child.api.nvim_create_namespace "GitHunks"
    return #child.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {}) == 0
  end)

  child.lua_func(function()
    _G.last_notification = nil
    --- @param message string
    --- @param level vim.log.levels
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(message, level)
      _G.last_notification = { message, level }
    end
  end)
  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys "<Plug>GitHunksResetHunk"
  expect_lines { "line1", "line2 changed" }
  eq(
    child.lua_func(function()
      return _G.last_notification[1]
    end),
    "[git-hunks.nvim]: Missing diff state for this buffer"
  )
end

T["reset hunk"] = new_set()

T["reset hunk"]["resets a single-line hunk"] = function()
  prepare_diff(
    [[line1
line2
line3
line4
line5
]],
    { "line1", "line2 changed", "line3", "line4", "line5" }
  )

  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys "<Plug>GitHunksResetHunk"

  expect_lines { "line1", "line2", "line3", "line4", "line5" }
end

T["reset hunk"]["resets a multi-line hunk"] = function()
  prepare_diff(
    [[line1
line2
line3
line4
line5
]],
    { "line1", "line2 changed", "line3 changed", "line4", "line5" }
  )

  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.type_keys "<Plug>GitHunksResetHunk"

  expect_lines { "line1", "line2", "line3", "line4", "line5" }
end

T["reset hunk"]["resets a deleted hunk"] = function()
  prepare_diff(
    [[line1
line2
line3
line4
line5
]],
    { "line1", "line3", "line4", "line5" }
  )

  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.type_keys "<Plug>GitHunksResetHunk"

  expect_lines { "line1", "line2", "line3", "line4", "line5" }
end

T["reset hunk"]["resets a leading deletion"] = function()
  prepare_diff(
    [[gone
line1
line2
]],
    { "line1", "line2" }
  )

  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.type_keys "<Plug>GitHunksResetHunk"

  expect_lines { "gone", "line1", "line2" }
end

T["reset hunk"]["does nothing when cursor is not on a hunk"] = function()
  prepare_diff(
    [[line1
line2
line3
line4
line5
]],
    { "line1", "line2 changed", "line3", "line4", "line5" }
  )

  child.api.nvim_win_set_cursor(0, { 4, 0 })
  child.type_keys "<Plug>GitHunksResetHunk"

  expect_lines { "line1", "line2 changed", "line3", "line4", "line5" }
end

T["reset hunk"]["resets a visually selected range"] = function()
  prepare_diff(
    [[line1
line2
line3
line4
line5
]],
    { "line1", "line2 changed", "line3 changed", "line4", "line5" }
  )

  child.api.nvim_win_set_cursor(0, { 2, 0 })
  child.lua_func(function()
    vim.keymap.set("v", "<F1>", "<Plug>GitHunksResetHunk", { noremap = false, buffer = true })
  end)
  child.type_keys "V"
  child.type_keys "j"
  child.type_keys "<F1>"

  expect_lines { "line1", "line2", "line3", "line4", "line5" }
end

T["reset file"] = new_set()

T["reset file"]["resets a leading deletion"] = function()
  prepare_diff(
    [[gone
line1
line2
line3
line4
]],
    { "line1", "line2 changed", "line3", "line4" }
  )

  child.type_keys "<Plug>GitHunksResetFile"

  expect_lines { "gone", "line1", "line2", "line3", "line4" }
end

T["reset file"]["resets the entire file"] = function()
  prepare_diff(
    [[line1
line2
line3
line4
line5
]],
    { "line1 changed", "line2", "line3 changed", "line4", "line5 changed" }
  )

  child.type_keys "<Plug>GitHunksResetFile"

  expect_lines { "line1", "line2", "line3", "line4", "line5" }
end

T["reset file"]["resets an inserted file to empty index content"] = function()
  prepare_diff("", { "inserted" })

  child.type_keys "<Plug>GitHunksResetFile"

  expect_lines { "" }
end

return T
