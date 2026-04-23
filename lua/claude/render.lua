-- Transcript rendering. Role markers are extmarks with virt_lines_above +
-- right_gravity=false so they stay anchored to their own message row even
-- as we append text/newlines after them.

local state = require("claude.state")
local config = require("claude.config")

local M = {}

local NS = vim.api.nvim_create_namespace("claude_roles")

local function buf_append(buf, text)
  local lines = vim.split(text, "\n", { plain = true })
  local last_line = vim.api.nvim_buf_line_count(buf) - 1
  local last_col = #vim.api.nvim_buf_get_lines(buf, last_line, last_line + 1, false)[1]
  vim.api.nvim_buf_set_text(buf, last_line, last_col, last_line, last_col, lines)
  local new_last = last_line + #lines - 1
  local new_col = #vim.api.nvim_buf_get_lines(buf, new_last, new_last + 1, false)[1]
  return last_line, new_last, new_col
end

local function buf_ensure_newline(buf)
  local last_line = vim.api.nvim_buf_line_count(buf) - 1
  local text = vim.api.nvim_buf_get_lines(buf, last_line, last_line + 1, false)[1] or ""
  if text ~= "" then
    vim.api.nvim_buf_set_text(buf, last_line, #text, last_line, #text, { "", "" })
  end
end

-- Throttle cursor-pinning so streaming many small deltas doesn't slam the
-- redraw path. We miss at most ~33ms of "catch-up"; a trailing autoscroll
-- fires naturally on the next append, and end_assistant's buf_ensure_newline
-- always triggers one more.
local AUTOSCROLL_THROTTLE_NS = 33 * 1e6
local autoscroll_last = {}

local function autoscroll(buf)
  local now = (vim.uv or vim.loop).hrtime()
  if (autoscroll_last[buf] or 0) + AUTOSCROLL_THROTTLE_NS > now then return end
  autoscroll_last[buf] = now
  local s = state.find_by_buf(buf)
  if not s or not s.transcript_win or not vim.api.nvim_win_is_valid(s.transcript_win) then
    return
  end
  if vim.api.nvim_win_get_buf(s.transcript_win) ~= buf then return end
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_set_cursor(s.transcript_win, { line_count, 0 })
end

-- Each message line gets a coloured bar in the sign column. Different hl per
-- role; the gutter bar is the visual identifier — no inline text labels.
-- Char and hl group names come from config.opts.signs.

local function sign_line(buf, row, role)
  local s = config.opts.signs or {}
  local hl = s[role]
  if not hl then return end
  local opts = {
    sign_text = s.char or "▎",
    sign_hl_group = hl,
    right_gravity = false,
  }
  -- Give user messages a subtle background tint so the turn clearly stands
  -- out from claude's freeform output.
  if role == "user" then
    opts.line_hl_group = "ClaudeUserLine"
  end
  vim.api.nvim_buf_set_extmark(buf, NS, row, 0, opts)
end

local function append_blank_line(buf)
  local lc = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, lc, lc, false, { "" })
end

local function sign_range(buf, from_row, to_row, role)
  if from_row > to_row then return end
  for r = from_row, to_row do sign_line(buf, r, role) end
end

function M.init_buffer(buf, name)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  if name then pcall(vim.api.nvim_buf_set_name, buf, name) end
end

function M.configure_window(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].list = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "yes:1"
  vim.wo[win].foldenable = false
  -- Disable native cursorline so the cursor position doesn't paint a
  -- ClaudeUserLine-coloured bg on claude's rows.
  vim.wo[win].cursorline = false
end

function M.append_user(buf, text)
  buf_ensure_newline(buf)
  -- One blank line above a user turn, unless we're at buffer start.
  if vim.api.nvim_buf_line_count(buf) > 1 then
    append_blank_line(buf)
  end
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, text)
  local end_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_ensure_newline(buf)
  -- Two trailing blanks: one is space below the user turn, the other gets
  -- absorbed by begin_assistant when claude's reply arrives (the first
  -- delta fills it). Net: a clear gap between "you" and "claude".
  append_blank_line(buf)
  append_blank_line(buf)
  sign_range(buf, start_row, end_row, "user")
  -- Inline prefix character on the first row so "you" is visually identified
  -- without a dedicated virt_line label.
  local prefix = (config.opts.signs and config.opts.signs.user_prefix) or "» "
  if prefix ~= "" then
    vim.api.nvim_buf_set_extmark(buf, NS, start_row, 0, {
      virt_text = { { prefix, "ClaudeUserPrefix" } },
      virt_text_pos = "inline",
      right_gravity = false,
    })
  end
  autoscroll(buf)
end

function M.begin_assistant(buf)
  buf_ensure_newline(buf)
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  local s = state.find_by_buf(buf)
  if s then
    s.last_assistant_start = start_row
    s._assistant_tagged_to = start_row - 1
  end
  sign_line(buf, start_row, "assistant")
  if s then s._assistant_tagged_to = start_row end
  autoscroll(buf)
end

function M.append_assistant_delta(buf, text)
  local s = state.find_by_buf(buf)
  buf_append(buf, text)
  if s and s._assistant_tagged_to ~= nil then
    local end_row = vim.api.nvim_buf_line_count(buf) - 1
    sign_range(buf, s._assistant_tagged_to + 1, end_row, "assistant")
    s._assistant_tagged_to = end_row
  end
  autoscroll(buf)
end

function M.end_assistant(buf)
  buf_ensure_newline(buf)
  -- Force a final scroll to EOF, bypassing the streaming throttle.
  autoscroll_last[buf] = 0
  autoscroll(buf)
end

local function max_output_lines()
  return config.opts.tool_output_max_lines or 14
end

local function count_lines(s)
  if not s or s == "" then return 0 end
  local n = 1
  for _ in s:gmatch("\n") do n = n + 1 end
  return n
end

local function format_tool_header(name, input)
  input = input or {}
  if name == "Bash" then
    local cmd = input.command or "?"
    local desc = input.description and ("   # " .. input.description) or ""
    return "$ " .. cmd .. desc
  elseif name == "Read" then
    local s = "Read " .. (input.file_path or "?")
    if input.offset or input.limit then
      s = s .. string.format("  (%s:%s)",
        tostring(input.offset or ""), tostring(input.limit or ""))
    end
    return s
  elseif name == "Write" then
    return string.format("Write %s  (%d lines)",
      input.file_path or "?", count_lines(input.content))
  elseif name == "Edit" then
    return "Edit " .. (input.file_path or "?")
  elseif name == "Grep" then
    local s = "Grep '" .. (input.pattern or "?") .. "'"
    if input.path then s = s .. " in " .. input.path end
    return s
  elseif name == "Glob" then
    local s = "Glob '" .. (input.pattern or "?") .. "'"
    if input.path then s = s .. " in " .. input.path end
    return s
  elseif name == "Task" then
    return "Task " .. (input.subagent_type or "")
      .. (input.description and (": " .. input.description) or "")
  elseif name == "TodoWrite" then
    return "TodoWrite"
  elseif name == "WebFetch" then
    return "WebFetch " .. (input.url or "?")
  elseif name == "WebSearch" then
    return "WebSearch '" .. (input.query or "?") .. "'"
  else
    local preview = ""
    if input and next(input) then preview = vim.json.encode(input) end
    if #preview > 120 then preview = preview:sub(1, 117) .. "…" end
    return name .. (preview ~= "" and ("  " .. preview) or "")
  end
end

local function format_edit_diff(input)
  local lines = {}
  if input.old_string and input.old_string ~= "" then
    for line in (input.old_string .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, "- " .. line)
    end
  end
  if input.new_string and input.new_string ~= "" then
    for line in (input.new_string .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(lines, "+ " .. line)
    end
  end
  return lines
end

local function truncate_lines(lines, max)
  if #lines <= max then return lines, false end
  local out = {}
  for i = 1, max do out[i] = lines[i] end
  out[max + 1] = string.format("… (%d more lines)", #lines - max)
  return out, true
end

function M.append_tool_call(buf, call)
  buf_ensure_newline(buf)
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, format_tool_header(call.name, call.input))
  if call.name == "Edit" and call.input then
    buf_ensure_newline(buf)
    local diff = format_edit_diff(call.input)
    diff = truncate_lines(diff, max_output_lines())
    buf_append(buf, table.concat(diff, "\n"))
  end
  local end_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_ensure_newline(buf)
  sign_range(buf, start_row, end_row, "tool")
  autoscroll(buf)
end

function M.append_tool_result(buf, result)
  if not result.text or result.text == "" then return end
  local lines = vim.split(result.text, "\n", { plain = true })
  lines = truncate_lines(lines, max_output_lines())
  buf_ensure_newline(buf)
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  local indented = "  " .. table.concat(lines, "\n  ")
  buf_append(buf, indented)
  local end_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_ensure_newline(buf)
  sign_range(buf, start_row, end_row, result.is_error and "error" or "tool")
  autoscroll(buf)
end

function M.append_error(buf, text)
  buf_ensure_newline(buf)
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, text)
  local end_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_ensure_newline(buf)
  sign_range(buf, start_row, end_row, "error")
  autoscroll(buf)
end

-- Back-compat shim (rarely used).
function M.append_tool(buf, label)
  buf_ensure_newline(buf)
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, label)
  buf_ensure_newline(buf)
  sign_range(buf, start_row, start_row, "tool")
  autoscroll(buf)
end

return M
