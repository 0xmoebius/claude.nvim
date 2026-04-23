local config = require("claude.config")
local state = require("claude.state")
local picker = require("claude.picker")
local layout = require("claude.layout")
local prompt = require("claude.prompt")
local render = require("claude.render")
local tabline = require("claude.tabline")

local M = {}

function M.setup(user)
  config.setup(user)
end

-- Close the caller's empty no-name tab after a session tab takes focus, so
-- gt/gT only cycles real Claude tabs.
local function maybe_close_empty_tab(tab)
  if not tab or not vim.api.nvim_tabpage_is_valid(tab) then return end
  if tab == vim.api.nvim_get_current_tabpage() then return end
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  if #wins ~= 1 then return end
  local buf = vim.api.nvim_win_get_buf(wins[1])
  local name = vim.api.nvim_buf_get_name(buf)
  local line_count = vim.api.nvim_buf_line_count(buf)
  local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
  if name == "" and line_count == 1 and first_line == "" then
    pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tab) .. "tabclose")
  end
end

-- Register a TabClosed autocmd once, globally.
local cleanup_registered = false
local function ensure_cleanup_autocmd()
  if cleanup_registered then return end
  cleanup_registered = true
  vim.api.nvim_create_autocmd("TabClosed", {
    callback = function(ev)
      -- ev.file is the closed tab's number as a string; handle resolution
      -- is lost once closed, so garbage-collect any stale records.
      for tab, rec in pairs(state.all()) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          if rec.job then pcall(function() rec.job:kill("sigterm") end) end
          for _, b in ipairs({ rec.transcript_buf, rec.prompt_buf }) do
            if b and vim.api.nvim_buf_is_valid(b) then
              pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
          end
          state.remove(tab)
        end
      end
    end,
  })
end

local function replay_session(session_path, buf)
  if not session_path then return end
  local f = io.open(session_path, "r")
  if not f then return end
  local function extract(content)
    if type(content) == "string" then return content end
    if type(content) == "table" then
      local parts = {}
      for _, c in ipairs(content) do
        if type(c) == "table" and c.type == "text" and c.text then
          table.insert(parts, c.text)
        end
      end
      return table.concat(parts, "\n")
    end
  end
  local skip = config.opts.title_skip_prefixes
  local function is_bp(t)
    if not t or t == "" then return true end
    for _, p in ipairs(skip) do
      if t:sub(1, #p) == p then return true end
    end
    return false
  end
  for line in f:lines() do
    local ok, d = pcall(vim.json.decode, line)
    if ok and type(d) == "table" and d.message then
      if d.type == "user" then
        local t = extract(d.message.content)
        if t and not is_bp(t) then render.append_user(buf, t) end
      elseif d.type == "assistant" then
        local t = extract(d.message.content)
        if t and t ~= "" then
          render.begin_assistant(buf)
          render.append_assistant_delta(buf, t)
          render.end_assistant(buf)
        end
      end
    end
  end
  f:close()
end

-- Open a new Claude tab for the chosen picker entry.
local function activate(entry)
  ensure_cleanup_autocmd()
  local rec = layout.open(entry.cwd)
  if entry.kind == "session" then
    rec.session_id = entry.id
    replay_session(entry.path, rec.transcript_buf)
  end

  prompt.setup_keymaps(rec)

  -- Buffer-scoped keymaps. Each lhs is read from config.opts.keymaps so the
  -- user can override or disable (set to false/"" to skip binding).
  local km = config.opts.keymaps or {}
  local function bind(buf, lhs, fn, desc)
    if not lhs or lhs == "" then return end
    if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, desc = desc })
  end

  for _, buf in ipairs({ rec.transcript_buf, rec.prompt_buf }) do
    bind(buf, km.pick, function() M.pick() end,
      "Claude: pick session (new tab)")
    bind(buf, km.new_here, function() M.new_here() end,
      "Claude: new session in cwd")
    bind(buf, km.yank_last,
      function() require("claude.yank").yank_last_assistant() end,
      "Claude: yank last reply")
    bind(buf, km.close_tab, function() M.close_current() end,
      "Claude: close this tab")
    bind(buf, km.quit_all, function() M.quit() end,
      "Claude: quit all + exit nvim")
    bind(buf, km.focus_prompt,
      function() layout.focus_prompt(state.current()) end,
      "Claude: focus prompt (insert)")
    bind(buf, km.focus_transcript,
      function() layout.focus_transcript(state.current()) end,
      "Claude: focus transcript")
  end

  if rec.transcript_buf and vim.api.nvim_buf_is_valid(rec.transcript_buf) then
    -- Transcript is read-only; redirect insert-mode starters to the prompt.
    for _, key in ipairs(km.transcript_to_insert or {}) do
      bind(rec.transcript_buf, key,
        function() layout.focus_prompt(state.current()) end,
        "Claude: focus prompt")
    end
    bind(rec.transcript_buf, km.yank_block,
      function() require("claude.yank").yank_block() end,
      "Claude: yank fenced block")
    bind(rec.transcript_buf, km.next_marker,
      function() M.jump_next_marker(1) end,
      "Claude: next message marker")
    bind(rec.transcript_buf, km.prev_marker,
      function() M.jump_next_marker(-1) end,
      "Claude: previous message marker")
  end
  return rec
end

-- Jump to the next / prev extmark row in the claude_roles namespace.
-- dir = 1 (next) or -1 (prev).
function M.jump_next_marker(dir)
  local buf = vim.api.nvim_get_current_buf()
  local ns = vim.api.nvim_get_namespaces()["claude_roles"]
  if not ns then return end
  local cur = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  local rows = {}
  for _, m in ipairs(marks) do rows[#rows + 1] = m[2] end
  table.sort(rows)
  -- dedupe
  local uniq = {}
  for _, r in ipairs(rows) do
    if uniq[#uniq] ~= r then uniq[#uniq + 1] = r end
  end
  local target
  if dir >= 0 then
    for _, r in ipairs(uniq) do
      if r > cur then target = r; break end
    end
  else
    for i = #uniq, 1, -1 do
      if uniq[i] < cur then target = uniq[i]; break end
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target + 1, 0 })
  end
end

-- If the selected entry matches a session already open in another tab, jump
-- there instead of opening a duplicate.
local function on_pick(entry)
  if entry.kind == "session" then
    local existing = state.find_by_id(entry.id)
    if existing then
      layout.focus(existing)
      return
    end
  end
  activate(entry)
end

-- Entry point for the cced shell wrapper.
function M.launch(opts)
  opts = opts or {}
  state.origin_cwd = opts.origin_cwd or vim.fn.getcwd()
  if config.opts.tabline then tabline.install() end
  local origin_tab = vim.api.nvim_get_current_tabpage()
  picker.open({ origin_cwd = state.origin_cwd }, function(entry)
    vim.schedule(function()
      on_pick(entry)
      maybe_close_empty_tab(origin_tab)
    end)
  end)
end

function M.pick()
  if config.opts.tabline then tabline.install() end
  picker.open({ origin_cwd = state.origin_cwd or vim.fn.getcwd() }, function(entry)
    vim.schedule(function() on_pick(entry) end)
  end)
end

function M.new_here()
  if config.opts.tabline then tabline.install() end
  activate({ kind = "new", cwd = vim.fn.getcwd() })
end

function M.close_current()
  local rec = state.current()
  if not rec then
    vim.notify("claude.nvim: not on a Claude tab", vim.log.levels.WARN)
    return
  end
  layout.close(rec)
end

-- Quit claude.nvim completely: kill all in-flight jobs, close every
-- Claude tab, wipe buffers, and if no non-Claude tabs remain, quit nvim.
function M.quit()
  for _, rec in pairs(state.all()) do
    if rec.job then pcall(function() rec.job:kill("sigterm") end) end
    for _, b in ipairs({ rec.transcript_buf, rec.prompt_buf }) do
      if b and vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    if rec.tab and vim.api.nvim_tabpage_is_valid(rec.tab) then
      pcall(vim.cmd, vim.api.nvim_tabpage_get_number(rec.tab) .. "tabclose!")
    end
    if rec.tab then state.remove(rec.tab) end
  end
  tabline.uninstall()
  -- If any other tabs survive, stay in nvim. Otherwise quit.
  if #vim.api.nvim_list_tabpages() == 0 then
    vim.cmd("qa!")
  elseif #vim.api.nvim_list_tabpages() == 1 then
    -- Check if the only remaining tab is the empty launcher tab.
    local tab = vim.api.nvim_list_tabpages()[1]
    local wins = vim.api.nvim_tabpage_list_wins(tab)
    if #wins == 1 then
      local buf = vim.api.nvim_win_get_buf(wins[1])
      local name = vim.api.nvim_buf_get_name(buf)
      local lc = vim.api.nvim_buf_line_count(buf)
      local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
      if name == "" and lc == 1 and first == "" then
        vim.cmd("qa!")
      end
    end
  end
end

function M.send() prompt.send() end
function M.interrupt() prompt.interrupt() end

return M
