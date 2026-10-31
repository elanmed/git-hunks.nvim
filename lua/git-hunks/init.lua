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
    vim.async
      .run("cb_async_task", function()
        callback(unpack(arguments))
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

-- ====================
-- Diff
-- ====================

--- @class UnpackedHunk
--- @field start_old_1i number
--- @field start_old_1i_visible integer
--- @field start_old_0i number
--- @field count_old number
--- @field end_old_1i_excl number
--- @field end_old_1i_incl number
--- @field end_old_0i_excl number
--- @field end_old_0i_incl number
--- @field start_new_1i number
--- @field start_new_1i_visible integer
--- @field start_new_0i number
--- @field count_new number
--- @field end_new_1i_excl number
--- @field end_new_1i_incl number
--- @field end_new_0i_excl number
--- @field end_new_0i_incl number
--- @field is_deletion boolean
--- @field is_insertion boolean

--- @alias DiffHunk { [1]: integer, [2]: integer, [3]: integer, [4]: integer }
--- @param hunk DiffHunk
--- @return UnpackedHunk
M.unpack_hunk = function(hunk)
  local start_old_1i, count_old, start_new_1i, count_new = unpack(hunk)

  local start_old_0i = start_old_1i - 1
  local start_new_0i = start_new_1i - 1
  local end_old_1i_excl = start_old_1i + count_old
  local end_old_1i_incl = end_old_1i_excl - 1
  local end_old_0i_excl = end_old_1i_excl - 1
  local end_old_0i_incl = end_old_1i_incl - 1

  -- If `old` begins with a deleted line and new has no line there,
  -- vim.text.diff reports start_new_1i as 0
  local start_old_1i_visible = math.max(1, start_old_1i)

  -- If `new` begins with an insertion and old has no line there,
  -- vim.text.diff reports start_old_1i as 0
  local start_new_1i_visible = math.max(1, start_new_1i)

  -- A zero count makes the inclusive end precede the start; that side is empty.
  local end_new_1i_excl = start_new_1i + count_new
  local end_new_1i_incl = end_new_1i_excl - 1
  local end_new_0i_excl = end_new_1i_excl - 1
  local end_new_0i_incl = end_new_1i_incl - 1

  local is_deletion = count_new == 0
  local is_insertion = count_old == 0

  return {
    start_old_1i = start_old_1i,
    start_old_1i_visible = start_old_1i_visible,
    start_old_0i = start_old_0i,
    count_old = count_old,
    end_old_1i_excl = end_old_1i_excl,
    end_old_1i_incl = end_old_1i_incl,
    end_old_0i_excl = end_old_0i_excl,
    end_old_0i_incl = end_old_0i_incl,

    start_new_1i = start_new_1i,
    start_new_1i_visible = start_new_1i_visible,
    start_new_0i = start_new_0i,
    count_new = count_new,
    end_new_1i_excl = end_new_1i_excl,
    end_new_1i_incl = end_new_1i_incl,
    end_new_0i_excl = end_new_0i_excl,
    end_new_0i_incl = end_new_0i_incl,

    is_deletion = is_deletion,
    is_insertion = is_insertion,
  }
end

--- @type fun(cmd: string[], opts: vim.SystemOpts?): vim.SystemCompleted
local system_async = vim.async.wrap(3, vim.system)

--- @type fun(cmd: string[], opts: vim.SystemOpts?): vim.async.Task<string?>
local vim_system_stdout = function(cmd, opts)
  --- @return string?
  return vim.async.run(function()
    local out = system_async(cmd, opts)
    if out.code ~= 0 then
      return nil
    end

    return out.stdout
  end)
end

--- @param rel_filename string
--- @return vim.async.Task<string?>
M.read_index_file = function(rel_filename)
  return vim_system_stdout { "git", "show", ":" .. rel_filename }
end

--- @class GenerateDiffParams
--- @field rel_filename string
--- @field file_bufnr number

--- @type fun(opts: GenerateDiffParams): vim.async.Task<DiffHunk[]?>
local generate_diff = function(opts)
  --- @return DiffHunk[]?
  return vim.async.run(function()
    local old_str = vim.async.await(M.read_index_file(opts.rel_filename)) --[[@as string?]]
    if old_str == nil then
      return nil
    end
    old_str = old_str:gsub("\n$", "") .. "\n"
    ensure_main_loop()
    if not vim.api.nvim_buf_is_valid(opts.file_bufnr) then
      return nil
    end
    local new_lines = vim.api.nvim_buf_get_lines(opts.file_bufnr, 0, -1, false)
    local new_str = table.concat(new_lines, "\n"):gsub("\n$", "") .. "\n"
    return vim.text.diff(old_str, new_str, { result_type = "indices" }) --[[@as DiffHunk[]?]]
  end)
end

--- @class DiffState
--- @field indices DiffHunk[]
--- @field index_lines string[]

--- @type table<number, DiffState>
local buffer_state = {}

local ns_id = vim.api.nvim_create_namespace "GitHunks"

local clear_state_for_buf = function(bufnr)
  buffer_state[bufnr] = nil
  ensure_main_loop()
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
  end
end

--- @type fun(bufnr: number): vim.async.Task
local update_state_for_buf = function(bufnr)
  return vim.async.run("update_state_for_buf_task", function()
    ensure_main_loop()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      clear_state_for_buf(bufnr)
      return
    end
    local bufname = vim.fs.relpath(vim.fn.getcwd(), vim.api.nvim_buf_get_name(bufnr))
    if bufname == nil then
      clear_state_for_buf(bufnr)
      return
    end

    local indices = vim.async.await(generate_diff {
      rel_filename = bufname,
      file_bufnr = bufnr,
    })
    if indices == nil then
      clear_state_for_buf(bufnr)
      return
    end

    local index_str = vim.async.await(M.read_index_file(bufname)) --[[@as string?]]
    if index_str == nil then
      clear_state_for_buf(bufnr)
      return
    end
    local index_lines = vim.split(index_str:gsub("\n$", "") .. "\n", "\n", { trimempty = true })

    buffer_state[bufnr] = {
      indices = indices,
      index_lines = index_lines,
    }
  end)
end

local update_signs = vim.schedule_wrap(function()
  local curr_bufnr = vim.api.nvim_get_current_buf()
  local buf_state = buffer_state[curr_bufnr]

  if buf_state == nil then
    return
  end

  local rows_to_hl = {}
  for _, raw_hunk in ipairs(buf_state.indices) do
    local hunk = M.unpack_hunk(raw_hunk)

    local hunk_hl_group = (function()
      if hunk.is_deletion then
        return "DiffSignDelete"
      end
      if hunk.is_insertion then
        return "DiffSignAdd"
      end
      return "DiffSignChange"
    end)()

    for row_1i = hunk.start_new_1i_visible, math.max(hunk.end_new_1i_incl, hunk.start_new_1i_visible) do
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
end)

--- @param direction 'next' | 'prev'
local function navigate_hunk(direction)
  local curr_bufnr = vim.api.nvim_get_current_buf()
  local buf_state = buffer_state[curr_bufnr]

  if buf_state == nil then
    return notify(vim.log.levels.ERROR, "Missing diff state for this buffer")
  end

  local indices = (function()
    if direction == "next" then
      return buf_state.indices
    end
    return tbl_reverse(buf_state.indices)
  end)()

  if #indices == 0 then
    return notify(vim.log.levels.ERROR, "No hunks")
  end

  local row_1i = vim.api.nvim_win_get_cursor(0)[1]
  local next_hunk_row_1i = nil

  for _, raw_hunk in ipairs(indices) do
    local hunk = M.unpack_hunk(raw_hunk)
    if direction == "next" then
      if hunk.start_new_1i_visible > row_1i then
        next_hunk_row_1i = hunk.start_new_1i_visible
        break
      end
    else
      if hunk.start_new_1i_visible < row_1i then
        next_hunk_row_1i = hunk.start_new_1i_visible
        break
      end
    end
  end

  if next_hunk_row_1i == nil then
    if direction == "next" then
      local hunk = M.unpack_hunk(buf_state.indices[1])
      vim.api.nvim_win_set_cursor(0, { hunk.start_new_1i_visible, 0 })
      return notify(vim.log.levels.INFO, "Wrapping to the first hunk")
    else
      local hunk = M.unpack_hunk(buf_state.indices[#buf_state.indices])
      vim.api.nvim_win_set_cursor(0, { hunk.start_new_1i_visible, 0 })
      return notify(vim.log.levels.INFO, "Wrapping to the last hunk")
    end
  end

  vim.api.nvim_win_set_cursor(0, { next_hunk_row_1i, 0 })
end

--- @class ResetHunkOpts
--- @field state DiffState
--- @field start_line_1i number
--- @field end_line_1i_incl number
--- @field curr_bufnr number
--- @param opts ResetHunkOpts
local function reset_hunk(opts)
  local matching_hunks = {}
  for _, raw_hunk in ipairs(opts.state.indices) do
    local hunk = M.unpack_hunk(raw_hunk)

    local hunk_overlaps_range = false
    if hunk.is_deletion then
      hunk_overlaps_range = hunk.start_new_1i_visible >= opts.start_line_1i
        and hunk.start_new_1i_visible <= opts.end_line_1i_incl
    else
      hunk_overlaps_range = hunk.end_new_1i_incl >= opts.start_line_1i
        and hunk.start_new_1i <= opts.end_line_1i_incl
    end

    if hunk_overlaps_range then
      table.insert(matching_hunks, hunk)
    end
  end

  for _, hunk in ipairs(tbl_reverse(matching_hunks)) do
    local head_chunk =
      vim.list_slice(opts.state.index_lines, hunk.start_old_1i, hunk.end_old_1i_incl)

    if hunk.is_deletion then
      local insert_after_0i = hunk.start_new_0i + 1
      vim.api.nvim_buf_set_lines(
        opts.curr_bufnr,
        insert_after_0i,
        insert_after_0i,
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
      update_signs()
    end),
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = vim.api.nvim_create_augroup("GitHunksCleanup", { clear = true }),
    callback = function(event)
      buffer_state[event.buf] = nil
    end,
  })
end

--- @type fun():nil
local setup_file_watcher = cb_async(function()
  local git_dir = vim.async.await(vim_system_stdout { "git", "rev-parse", "--absolute-git-dir" }) --[[@as string?]]
  ensure_main_loop()
  if git_dir == nil then
    return
  end
  local git_dir_path = vim.trim(git_dir)

  local index_watch = vim.uv.new_fs_event()
  if index_watch == nil then
    return
  end

  index_watch:start(
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
end)

local setup_global_keymaps = function()
  vim.keymap.set("n", "<Plug>GitHunksNextHunk", function()
    navigate_hunk "next"
  end, { desc = "Navigate to the next hunk" })
  vim.keymap.set("n", "<Plug>GitHunksPrevHunk", function()
    navigate_hunk "prev"
  end, { desc = "Navigate to the prev hunk" })

  vim.keymap.set("n", "<Plug>GitHunksResetHunk", function()
    local curr_bufnr = vim.api.nvim_get_current_buf()
    local buf_state = buffer_state[curr_bufnr]
    if buf_state == nil then
      return notify(vim.log.levels.ERROR, "Missing diff state for this buffer")
    end

    local row_1i = vim.api.nvim_win_get_cursor(0)[1]
    reset_hunk {
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

    local start_visual_1i = vim.fn.line "v"
    local end_visual_1i = vim.fn.line "."
    local start_selection_1i = math.min(start_visual_1i, end_visual_1i)
    local end_selection_1i = math.max(start_visual_1i, end_visual_1i)

    reset_hunk {
      state = buf_state,
      curr_bufnr = curr_bufnr,
      start_line_1i = start_selection_1i,
      end_line_1i_incl = end_selection_1i,
    }
  end, { desc = "Reset the visually selected hunk" })

  vim.keymap.set("n", "<Plug>GitHunksResetFile", function()
    local curr_bufnr = vim.api.nvim_get_current_buf()
    local buf_state = buffer_state[curr_bufnr]
    if buf_state == nil then
      return notify(vim.log.levels.ERROR, "Missing diff state for this buffer")
    end

    reset_hunk {
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

return M
