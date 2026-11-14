local M = {}

-- ====================
-- Async helpers
-- ====================

local async_iterators = require "git-hunks.async-iterators"

--- @param callback fun(...: any): any
--- @return fun(...: any): nil
local cb_async = function(callback)
  return function(...)
    local arguments = { ... }
    local argument_count = select("#", ...)
    vim.async
      .run("cb_async_task", function()
        callback(unpack(arguments, 1, argument_count))
      end)
      :raise_on_error()
  end
end

local ensure_main_loop = function()
  vim.async.sleep(0)
end

-- ====================
-- Misc utils
-- ====================

--- @param level vim.log.levels
--- @param msg string
--- @param ... any
local notify = function(level, msg, ...)
  msg = "[git-hunks.nvim]: " .. msg
  vim.notify(msg:format(...), level)
end

--- @param input table
local tbl_reverse = function(input)
  local reversed = {}
  for index = #input, 1, -1 do
    table.insert(reversed, input[index])
  end
  return reversed
end

--- @param start_line_1i integer
--- @param end_line_1i integer
--- @return integer, integer
local get_visual_selection_range = function(start_line_1i, end_line_1i)
  return math.min(start_line_1i, end_line_1i), math.max(start_line_1i, end_line_1i)
end

--- @param unified string
--- @return string[]
local split_unified_hunks = function(unified)
  local unified_hunks = {}
  local curr_hunk_lines = {}
  local unified_lines = vim.split(unified, "\n", { plain = true, trimempty = true })
  for _, line in ipairs(unified_lines) do
    if line:match "^@@ " then
      if #curr_hunk_lines > 0 then
        local curr_hunk = table.concat(curr_hunk_lines, "\n") .. "\n"
        table.insert(unified_hunks, curr_hunk)
      end
      curr_hunk_lines = {}
    end

    table.insert(curr_hunk_lines, line)
  end

  if #curr_hunk_lines > 0 then
    local curr_hunk = table.concat(curr_hunk_lines, "\n") .. "\n"
    table.insert(unified_hunks, curr_hunk)
  end

  return unified_hunks
end

-- ====================
-- Diff
-- ====================

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

--- @alias IndicesHunkUnpacked InsertionHunk | DeletionHunk | ChangeHunk

--- @alias IndicesHunk { [1]: integer, [2]: integer, [3]: integer, [4]: integer }
--- @param hunk IndicesHunk
--- @return IndicesHunkUnpacked
M.unpack_indices_hunk = function(hunk)
  local start_old_1i, count_old, start_new_1i, count_new = unpack(hunk)

  local kind = (function()
    if count_old == 0 then
      return "insertion"
    end
    if count_new == 0 then
      return "deletion"
    end
    return "change"
  end)()

  local old_side
  if kind == "insertion" then
    old_side = {
      after_old_1i = start_old_1i,
      after_old_1i_visible = math.max(1, start_old_1i),
    }
  else
    local end_old_1i_excl = start_old_1i + count_old
    old_side = {
      start_old_1i = start_old_1i,
      start_old_0i = start_old_1i - 1,
      count_old = count_old,
      end_old_1i_excl = end_old_1i_excl,
      end_old_1i_incl = end_old_1i_excl - 1,
      end_old_0i_excl = end_old_1i_excl - 1,
      end_old_0i_incl = end_old_1i_excl - 2,
    }
  end

  local new_side
  if kind == "deletion" then
    new_side = {
      after_new_1i = start_new_1i,
      after_new_1i_visible = math.max(1, start_new_1i),
    }
  else
    local end_new_1i_excl = start_new_1i + count_new
    new_side = {
      start_new_1i = start_new_1i,
      start_new_0i = start_new_1i - 1,
      count_new = count_new,
      end_new_1i_excl = end_new_1i_excl,
      end_new_1i_incl = end_new_1i_excl - 1,
      end_new_0i_excl = end_new_1i_excl - 1,
      end_new_0i_incl = end_new_1i_excl - 2,
    }
  end

  local is_leading = (kind == "insertion" and start_old_1i == 0)
    or (kind == "deletion" and start_new_1i == 0)

  return vim.tbl_extend("error", old_side, new_side, { kind = kind, is_leading = is_leading })
end

--- @type fun(cmd: string[], opts: vim.SystemOpts?): vim.SystemCompleted
local system_async = vim.async.wrap(3, vim.system)

--- @type fun(cmd: string[], opts: vim.SystemOpts?): vim.async.Task<string, string, integer>
local system = function(cmd, opts)
  --- @return string, string, integer
  return vim.async.run(function()
    local out = system_async(cmd, opts)
    --- @diagnostic disable-next-line: redundant-return-value
    return out.stderr or "", out.stdout or "", out.code
  end)
end

--- @param stderr string
--- @return string
local get_failure_msg = function(stderr)
  local msg = vim.trim(stderr)
  if msg == "" then
    return "unknown error"
  end
  return msg
end

--- @return vim.async.Task<string, string, integer>
local get_git_root = function()
  return vim.async.run(
    --- @return string, string, integer
    function()
      --- @type string, string, integer
      local stderr, stdout, code = vim.async.await(system { "git", "rev-parse", "--show-toplevel" }) --[[@as any]]
      --- @diagnostic disable-next-line: redundant-return-value
      return stderr, vim.trim(stdout), code
    end
  )
end

--- @param rel_filename string
--- @return vim.async.Task<string, string, integer>
local list_index_paths = function(rel_filename)
  return system { "git", "ls-files", "--cached", "--", rel_filename }
end

--- @param rel_filename string
--- @return vim.async.Task<boolean?>
M.is_file_untracked = function(rel_filename)
  return vim.async.run(
    --- @return boolean?
    function()
      --- @type string, string, integer
      local stderr, stdout, code = vim.async.await(list_index_paths(rel_filename)) --[[@as any]]
      if code ~= 0 then
        notify(vim.log.levels.ERROR, "%s", get_failure_msg(stderr))
        return nil
      end

      return stdout == ""
    end
  )
end

--- @param rel_filename string
--- @return vim.async.Task<string, string, integer>
M.read_index_file = function(rel_filename)
  return vim.async.run(
    --- @return string, string, integer
    function()
      --- @type string, string, integer
      local paths_stderr, paths_stdout, paths_code = vim.async.await(list_index_paths(rel_filename)) --[[@as any]]
      if paths_code ~= 0 then
        --- @diagnostic disable-next-line: redundant-return-value
        return paths_stderr, "", paths_code
      end
      if paths_stdout == "" then
        --- @diagnostic disable-next-line: redundant-return-value
        return "", "", 0
      end

      --- @type string, string, integer
      local stderr, stdout, code = vim.async.await(system { "git", "show", ":" .. rel_filename }) --[[@as any]]
      --- @diagnostic disable-next-line: redundant-return-value
      return stderr, stdout, code
    end
  )
end

--- @class GenerateDiffParams
--- @field rel_filename string
--- @field file_bufnr number

--- @type fun(opts: GenerateDiffParams): vim.async.Task<{indices: IndicesHunk[], unified: string}?>
local generate_diff = function(opts)
  --- @return {indices: IndicesHunk[], unified: string}?
  return vim.async.run(function()
    --- @type string, string, integer
    local stderr, old_str, code = vim.async.await(M.read_index_file(opts.rel_filename)) --[[@as any]]
    if code ~= 0 then
      notify(vim.log.levels.ERROR, "%s", get_failure_msg(stderr))
      return nil
    end
    if old_str ~= "" then
      old_str = old_str:gsub("\n$", "") .. "\n"
    end
    ensure_main_loop()
    if not vim.api.nvim_buf_is_valid(opts.file_bufnr) then
      return nil
    end
    local new_lines = vim.api.nvim_buf_get_lines(opts.file_bufnr, 0, -1, false)
    local new_str = table.concat(new_lines, "\n"):gsub("\n$", "") .. "\n"
    local indices = vim.text.diff(old_str, new_str, { result_type = "indices" }) --[[@as IndicesHunk[]?]]
    local unified = vim.text.diff(old_str, new_str, { result_type = "unified" }) --[[@as string]]
    return { indices = indices, unified = unified }
  end)
end

--- @class DiffState
--- @field indices_hunks_unpacked IndicesHunkUnpacked[]
--- @field unified_hunks string[]
--- @field index_lines string[]
--- @field is_untracked boolean

--- @type table<number, DiffState>
local buffer_state = {}

--- @type table<number, integer>
local buffer_update_id = {}

local ns_id = vim.api.nvim_create_namespace "GitHunks"

local clear_state_for_buf = function(bufnr, update_id)
  if update_id ~= nil and buffer_update_id[bufnr] ~= update_id then
    return
  end
  buffer_state[bufnr] = nil
  ensure_main_loop()
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
end

--- @type fun(bufnr: number): vim.async.Task
local update_state_for_buf = function(bufnr)
  local update_id = (buffer_update_id[bufnr] or 0) + 1
  buffer_update_id[bufnr] = update_id

  return vim.async.run("update_state_for_buf_task", function()
    ensure_main_loop()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      clear_state_for_buf(bufnr, update_id)
      return
    end
    local bufname = vim.fs.relpath(vim.fn.getcwd(), vim.api.nvim_buf_get_name(bufnr))
    if bufname == nil or vim.bo[bufnr].buftype ~= "" or vim.fn.isdirectory(bufname) == 1 then
      clear_state_for_buf(bufnr, update_id)
      return
    end

    local diff = vim.async.await(generate_diff {
      rel_filename = bufname,
      file_bufnr = bufnr,
    }) --[[@as {indices: IndicesHunk[], unified: string}?]]
    if buffer_update_id[bufnr] ~= update_id then
      return
    end
    if diff == nil then
      clear_state_for_buf(bufnr, update_id)
      return
    end

    --- @type string, string, integer
    local _, index_str, index_code = vim.async.await(M.read_index_file(bufname)) --[[@as any]]
    if buffer_update_id[bufnr] ~= update_id then
      return
    end
    if index_code ~= 0 then
      clear_state_for_buf(bufnr, update_id)
      return
    end
    local index_lines = vim.split(index_str:gsub("\n$", "") .. "\n", "\n", { trimempty = true })
    local is_untracked = false
    if #index_lines == 0 then
      local untracked = vim.async.await(M.is_file_untracked(bufname)) --[[@as boolean?]]
      is_untracked = untracked == true
    end

    local indices_hunks_unpacked = {}
    for _, raw_hunk in ipairs(diff.indices) do
      table.insert(indices_hunks_unpacked, M.unpack_indices_hunk(raw_hunk))
    end

    local unified_hunks = split_unified_hunks(diff.unified)

    buffer_state[bufnr] = {
      indices_hunks_unpacked = indices_hunks_unpacked,
      unified_hunks = unified_hunks,
      index_lines = index_lines,
      is_untracked = is_untracked,
    }
  end)
end

local update_signs = function()
  local curr_bufnr = vim.api.nvim_get_current_buf()
  local buf_state = buffer_state[curr_bufnr]

  if buf_state == nil then
    return
  end

  local rows_to_hl = {}
  for _, hunk in ipairs(buf_state.indices_hunks_unpacked) do
    local hunk_hl_group = (function()
      if hunk.kind == "deletion" then
        return "DiffSignDelete"
      end
      if hunk.kind == "insertion" then
        return "DiffSignAdd"
      end
      return "DiffSignChange"
    end)()

    local first_row_1i, last_row_1i
    if hunk.kind == "deletion" then
      first_row_1i = hunk.after_new_1i_visible
      last_row_1i = hunk.after_new_1i_visible
    else
      first_row_1i = hunk.start_new_1i
      last_row_1i = hunk.end_new_1i_incl
    end
    for row_1i = first_row_1i, last_row_1i do
      local row_0i = row_1i - 1
      if row_0i >= 0 then
        table.insert(rows_to_hl, { row_0i = row_0i, hl = hunk_hl_group })
      end
    end
  end

  vim.api.nvim_buf_clear_namespace(curr_bufnr, ns_id, 0, -1)
  for _, row_to_hl in ipairs(rows_to_hl) do
    vim.api.nvim_buf_set_extmark(curr_bufnr, ns_id, row_to_hl.row_0i, 0, {
      number_hl_group = row_to_hl.hl,
    })
  end
end

--- @param hunk IndicesHunkUnpacked
--- @return integer
local get_first_new_row_1i = function(hunk)
  if hunk.kind == "deletion" then
    return hunk.after_new_1i_visible
  end
  return hunk.start_new_1i
end

--- @param direction 'next' | 'prev'
local function navigate_hunk(direction)
  local curr_bufnr = vim.api.nvim_get_current_buf()
  local buf_state = buffer_state[curr_bufnr]

  if buf_state == nil then
    return notify(vim.log.levels.ERROR, "Missing diff state for this buffer")
  end

  local hunks = (function()
    if direction == "next" then
      return buf_state.indices_hunks_unpacked
    end
    return tbl_reverse(buf_state.indices_hunks_unpacked)
  end)()

  if #hunks == 0 then
    return
  end

  local row_1i = vim.api.nvim_win_get_cursor(0)[1]
  local next_hunk_row_1i = nil

  for _, hunk in ipairs(hunks) do
    local hunk_row_1i = get_first_new_row_1i(hunk)
    if direction == "next" then
      if hunk_row_1i > row_1i then
        next_hunk_row_1i = hunk_row_1i
        break
      end
    else
      if hunk_row_1i < row_1i then
        next_hunk_row_1i = hunk_row_1i
        break
      end
    end
  end

  if next_hunk_row_1i == nil then
    if direction == "next" then
      local hunk = buf_state.indices_hunks_unpacked[1]
      vim.api.nvim_win_set_cursor(0, { get_first_new_row_1i(hunk), 0 })
      return notify(vim.log.levels.INFO, "Wrapping to the first hunk")
    else
      local hunk = buf_state.indices_hunks_unpacked[#buf_state.indices_hunks_unpacked]
      vim.api.nvim_win_set_cursor(0, { get_first_new_row_1i(hunk), 0 })
      return notify(vim.log.levels.INFO, "Wrapping to the last hunk")
    end
  end

  vim.api.nvim_win_set_cursor(0, { next_hunk_row_1i, 0 })
end

--- @class MatchingHunk
--- @field indices_hunk_unpacked IndicesHunkUnpacked
--- @field unified_hunk string

--- @class GetMatchingHunksOpts
--- @field state DiffState
--- @field start_line_1i number
--- @field end_line_1i_incl number
--- @field curr_bufnr number

--- @param opts GetMatchingHunksOpts
local function get_matching_hunks(opts)
  --- @type MatchingHunk[]
  local matching_hunks = {}
  for idx, hunk in ipairs(opts.state.indices_hunks_unpacked) do
    local hunk_overlaps_range = false
    if hunk.kind == "deletion" then
      hunk_overlaps_range = hunk.after_new_1i_visible >= opts.start_line_1i
        and hunk.after_new_1i_visible <= opts.end_line_1i_incl
    else
      hunk_overlaps_range = hunk.end_new_1i_incl >= opts.start_line_1i
        and hunk.start_new_1i <= opts.end_line_1i_incl
    end

    if hunk_overlaps_range then
      local unified_hunk = opts.state.unified_hunks[idx]

      --- @type MatchingHunk
      local matching_hunk = {
        indices_hunk_unpacked = hunk,
        unified_hunk = unified_hunk,
      }
      table.insert(matching_hunks, matching_hunk)
    end
  end
  return matching_hunks
end

--- @param opts GetMatchingHunksOpts
local function reset_hunks(opts)
  if opts.state.is_untracked then
    return notify(vim.log.levels.WARN, "Cannot reset hunks of an untracked file")
  end

  local matching_hunks = get_matching_hunks(opts)

  for _, matching_hunk in ipairs(tbl_reverse(matching_hunks)) do
    --- @type IndicesHunkUnpacked
    local hunk = matching_hunk.indices_hunk_unpacked
    local head_chunk = hunk.kind == "insertion" and {}
      or vim.list_slice(opts.state.index_lines, hunk.start_old_1i, hunk.end_old_1i_incl)

    if hunk.kind == "deletion" then
      local insert_index_0i = hunk.after_new_1i
      vim.api.nvim_buf_set_lines(
        opts.curr_bufnr,
        insert_index_0i,
        insert_index_0i,
        true,
        head_chunk
      )
    else
      vim.api.nvim_buf_set_lines(
        opts.curr_bufnr,
        hunk.start_new_0i,
        hunk.end_new_0i_excl,
        true,
        head_chunk
      )
    end
  end
end

--- @param opts GetMatchingHunksOpts
local stage_hunks = cb_async(function(opts)
  local bufname = vim.api.nvim_buf_get_name(opts.curr_bufnr)
  --- @type string, string, integer
  local git_root_stderr, git_root, git_root_code = vim.async.await(get_git_root()) --[[@as any]]
  ensure_main_loop()
  if git_root_code ~= 0 then
    return notify(vim.log.levels.ERROR, "%s", get_failure_msg(git_root_stderr))
  end

  local rel_filename = vim.fs.relpath(git_root, bufname)
  if rel_filename == nil then
    return notify(vim.log.levels.ERROR, "File is not inside the Git root")
  end

  local matching_hunks = get_matching_hunks(opts)
  if #matching_hunks == 0 then
    return notify(vim.log.levels.WARN, "No hunks under the cursor")
  end

  local matching_unified_hunks = {}
  for _, matching_hunk in ipairs(matching_hunks) do
    table.insert(matching_unified_hunks, matching_hunk.unified_hunk)
  end

  local patch = string.format(
    [[diff --git a/%s b/%s
--- a/%s
+++ b/%s
%s]],
    rel_filename,
    rel_filename,
    rel_filename,
    rel_filename,
    table.concat(matching_unified_hunks, "\n") .. "\n"
  )

  --- @type string, string, integer
  local stderr, _, code = vim.async.await(
    system({ "git", "apply", "--cached", "--unidiff-zero", "-" }, { stdin = patch })
  ) --[[@as any]]
  if code ~= 0 then
    return notify(vim.log.levels.ERROR, "Failed to stage hunk: %s", get_failure_msg(stderr))
  end

  ensure_main_loop()
  update_signs()
end)

local setup_highlights = function()
  local set_default_highlights = function()
    vim.api.nvim_set_hl(0, "DiffSignDelete", { default = true, link = "DiffDelete" })
    vim.api.nvim_set_hl(0, "DiffSignAdd", { default = true, link = "DiffAdd" })
    vim.api.nvim_set_hl(0, "DiffSignChange", { default = true, link = "DiffChange" })
  end

  set_default_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("GitHunksHighlights", { clear = true }),
    callback = set_default_highlights,
  })
end

local file_watcher = nil

local setup_global_autocmds = function()
  local timer = nil
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = vim.api.nvim_create_augroup("GitHunksTextEvents", { clear = true }),
    callback = function(event)
      if timer then
        vim.fn.timer_stop(timer)
      end

      timer = vim.fn.timer_start(
        300,
        cb_async(function()
          if event.buf ~= vim.api.nvim_get_current_buf() then
            return
          end
          vim.async.await(update_state_for_buf(event.buf))
          ensure_main_loop()
          update_signs()
        end)
      )
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "BufWritePost" }, {
    group = vim.api.nvim_create_augroup("GitHunksBufEvents", { clear = true }),
    callback = cb_async(function(event)
      if event.buf ~= vim.api.nvim_get_current_buf() then
        return
      end
      vim.async.await(update_state_for_buf(event.buf))
      ensure_main_loop()
      update_signs()
    end),
  })

  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("GitHunksIndexEvents", { clear = true }),
    pattern = { "GitIndexChanged" },
    callback = cb_async(function()
      local bufs = {}
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[bufnr].buftype == "" and vim.api.nvim_buf_is_loaded(bufnr) then
          table.insert(bufs, bufnr)
        end
      end

      async_iterators.batched_iterator {
        iterator_factory = function()
          local iterator_state = { index = 0 }
          return function(state)
            state.index = state.index + 1
            return bufs[state.index]
          end,
            iterator_state,
            0
        end,
        on_iteration = function(bufnr)
          vim.async.await(update_state_for_buf(bufnr))
        end,
      }
      ensure_main_loop()
      update_signs()
    end),
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = vim.api.nvim_create_augroup("GitHunksCleanup", { clear = true }),
    callback = function(event)
      buffer_update_id[event.buf] = (buffer_update_id[event.buf] or 0) + 1
      buffer_state[event.buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("GitHunksWatcherCleanup", { clear = true }),
    callback = function()
      if file_watcher ~= nil and not file_watcher:is_closing() then
        file_watcher:close()
      end
      file_watcher = nil
    end,
  })
end

local file_watcher_setup_pending = false

--- @type fun():nil
local setup_file_watcher = cb_async(function()
  if file_watcher ~= nil or file_watcher_setup_pending then
    return
  end
  file_watcher_setup_pending = true

  --- @type string, string, integer
  local git_dir_stderr, git_dir, git_dir_code =
    vim.async.await(system { "git", "rev-parse", "--absolute-git-dir" }) --[[@as any]]
  ensure_main_loop()
  if git_dir_code ~= 0 then
    file_watcher_setup_pending = false
    return notify(vim.log.levels.ERROR, "%s", get_failure_msg(git_dir_stderr))
  end
  local git_dir_path = vim.trim(git_dir)

  local index_watch = vim.uv.new_fs_event()
  if index_watch == nil then
    file_watcher_setup_pending = false
    return notify(vim.log.levels.ERROR, "Failed to create Git directory watcher")
  end

  local started, err = index_watch:start(
    git_dir_path,
    {},
    cb_async(function(_, filename)
      ensure_main_loop()
      if filename == "index" then
        vim.api.nvim_exec_autocmds("User", { pattern = "GitIndexChanged" })
      elseif filename == "HEAD" then
        vim.api.nvim_exec_autocmds("User", { pattern = "GitHeadChanged" })
      end
    end)
  )
  if not started then
    index_watch:close()
    file_watcher_setup_pending = false
    return notify(vim.log.levels.ERROR, "Failed to watch Git directory: %s", err or "unknown error")
  end

  file_watcher = index_watch
  file_watcher_setup_pending = false
end)

local setup_global_keymaps = function()
  vim.keymap.set("n", "<Plug>GitHunksNextHunk", function()
    navigate_hunk "next"
  end, { desc = "Navigate to the next hunk" })
  vim.keymap.set("n", "<Plug>GitHunksPrevHunk", function()
    navigate_hunk "prev"
  end, { desc = "Navigate to the prev hunk" })

  vim.keymap.set("n", "<Plug>GitHunksStageHunk", function()
    local curr_bufnr = vim.api.nvim_get_current_buf()
    local buf_state = buffer_state[curr_bufnr]
    if buf_state == nil then
      return notify(vim.log.levels.ERROR, "Missing diff state for this buffer")
    end

    local row_1i = vim.api.nvim_win_get_cursor(0)[1]
    stage_hunks {
      state = buf_state,
      curr_bufnr = curr_bufnr,
      start_line_1i = row_1i,
      end_line_1i_incl = row_1i,
    }
  end, { desc = "Stage the hunk on the current line" })

  vim.keymap.set("v", "<Plug>GitHunksStageHunk", function()
    local curr_bufnr = vim.api.nvim_get_current_buf()
    local buf_state = buffer_state[curr_bufnr]
    if buf_state == nil then
      return notify(vim.log.levels.ERROR, "Missing diff state for this buffer")
    end

    local start_selection_1i, end_selection_1i_incl =
      get_visual_selection_range(vim.fn.line "v", vim.fn.line ".")
    stage_hunks {
      state = buf_state,
      curr_bufnr = curr_bufnr,
      start_line_1i = start_selection_1i,
      end_line_1i_incl = end_selection_1i_incl,
    }
  end, { desc = "Stage the visually selected hunk" })

  vim.keymap.set("n", "<Plug>GitHunksResetHunk", function()
    local curr_bufnr = vim.api.nvim_get_current_buf()
    local buf_state = buffer_state[curr_bufnr]
    if buf_state == nil then
      return notify(vim.log.levels.ERROR, "Missing diff state for this buffer")
    end

    local row_1i = vim.api.nvim_win_get_cursor(0)[1]
    reset_hunks {
      state = buf_state,
      curr_bufnr = curr_bufnr,
      start_line_1i = row_1i,
      end_line_1i_incl = row_1i,
    }
  end, { desc = "Reset the hunk on the current line" })

  vim.keymap.set("v", "<Plug>GitHunksResetHunk", function()
    local curr_bufnr = vim.api.nvim_get_current_buf()
    local buf_state = buffer_state[curr_bufnr]
    if buf_state == nil then
      return notify(vim.log.levels.ERROR, "Missing diff state for this buffer")
    end

    local start_selection_1i, end_selection_1i_incl =
      get_visual_selection_range(vim.fn.line "v", vim.fn.line ".")

    reset_hunks {
      state = buf_state,
      curr_bufnr = curr_bufnr,
      start_line_1i = start_selection_1i,
      end_line_1i_incl = end_selection_1i_incl,
    }
  end, { desc = "Reset the visually selected hunk" })

  vim.keymap.set("n", "<Plug>GitHunksResetFile", function()
    local curr_bufnr = vim.api.nvim_get_current_buf()
    local buf_state = buffer_state[curr_bufnr]
    if buf_state == nil then
      return notify(vim.log.levels.ERROR, "Missing diff state for this buffer")
    end

    reset_hunks {
      state = buf_state,
      curr_bufnr = curr_bufnr,
      start_line_1i = 1,
      end_line_1i_incl = vim.api.nvim_buf_line_count(curr_bufnr),
    }
  end, { desc = "Reset the entire file" })
end

M.setup = function()
  setup_highlights()
  setup_global_autocmds()
  setup_file_watcher()
  setup_global_keymaps()
end

if rawget(_G, "GIT_HUNKS_TEST") then
  M._internal = {
    get_visual_selection_range = get_visual_selection_range,
    split_unified_hunks = split_unified_hunks,
  }
end

return M
