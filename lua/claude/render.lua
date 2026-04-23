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
  local opts = { right_gravity = false }
  -- Gutter bar (only roles with a hl configured get one)
  local sign_hl = s[role]
  if sign_hl then
    opts.sign_text = s.char or "▎"
    opts.sign_hl_group = sign_hl
  end
  -- User turns also get a full-line bg tint + bold (ClaudeUserLine).
  if role == "user" then
    opts.line_hl_group = "ClaudeUserLine"
  end
  if not opts.sign_text and not opts.line_hl_group then return end
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
  -- Sign column only appears when errors land in it. Keeps the chat view
  -- flush against the edge when everything's healthy.
  vim.wo[win].signcolumn = "auto:1"
  vim.wo[win].foldenable = false
  -- Disable native cursorline so the cursor position doesn't paint a
  -- ClaudeUserLine-coloured bg on claude's rows.
  vim.wo[win].cursorline = false
end

function M.append_user(buf, text)
  local s = state.find_by_buf(buf)
  if s then s._last_kind = "user" end
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
    s._last_kind = nil
  end
  autoscroll(buf)
end

function M.append_assistant_delta(buf, text)
  local s = state.find_by_buf(buf)
  -- When resuming assistant text after a tool call, insert a blank line
  -- separator so tool blocks visually detach from the surrounding prose.
  if s and s._last_kind == "tool" then
    buf_ensure_newline(buf)
    append_blank_line(buf)
    if s.last_assistant_start then
      s._assistant_tagged_to = vim.api.nvim_buf_line_count(buf) - 2
    end
  end
  buf_append(buf, text)
  if s and s.last_assistant_start then
    local end_row = vim.api.nvim_buf_line_count(buf) - 1
    local from = (s._assistant_tagged_to or (s.last_assistant_start - 1)) + 1
    if from < s.last_assistant_start then from = s.last_assistant_start end
    sign_range(buf, from, end_row, "assistant")
    s._assistant_tagged_to = end_row
  end
  if s then s._last_kind = "assistant" end
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

-- Compact one-line summary: `Bash <command>`, `Read <path>`, etc.
-- Truncated so the line fits on screen.
local function format_tool_compact(name, input)
  input = input or {}
  local s
  if name == "Bash" then
    s = "Bash " .. (input.command or "?")
  elseif name == "Read" then
    s = "Read " .. (input.file_path or "?")
  elseif name == "Write" then
    s = string.format("Write %s (%d lines)",
      input.file_path or "?", count_lines(input.content))
  elseif name == "Edit" then
    s = "Edit " .. (input.file_path or "?")
  elseif name == "Grep" then
    s = "Grep " .. (input.pattern or "?")
    if input.path then s = s .. " in " .. input.path end
  elseif name == "Glob" then
    s = "Glob " .. (input.pattern or "?")
    if input.path then s = s .. " in " .. input.path end
  elseif name == "Task" then
    s = "Task " .. (input.subagent_type or "")
      .. (input.description and (": " .. input.description) or "")
  elseif name == "TodoWrite" then
    s = "TodoWrite"
  elseif name == "WebFetch" then
    s = "WebFetch " .. (input.url or "?")
  elseif name == "WebSearch" then
    s = "WebSearch " .. (input.query or "?")
  else
    s = name
  end
  -- Strip newlines and collapse runs of whitespace so the call stays on one
  -- visual line even for multi-line Bash heredocs.
  s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local max = 140
  if #s > max then s = s:sub(1, max - 1) .. "…" end
  return s
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

-- Tool calls render as a single flush-left, muted-italic one-liner — no
-- diff, no output. Full details are still in the session JSONL on disk if
-- you need them.
function M.append_tool_call(buf, call)
  buf_ensure_newline(buf)
  local row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, "↳ " .. format_tool_compact(call.name, call.input))
  buf_ensure_newline(buf)
  vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
    line_hl_group = "ClaudeToolLine",
    right_gravity = false,
  })
  -- Mark current write kind so append_assistant_delta knows whether it's
  -- resuming from a tool and should insert a separator blank line.
  local s = state.find_by_buf(buf)
  if s then s._last_kind = "tool" end
  autoscroll(buf)
end

-- Tool results are noisy. We skip them entirely unless they're an error,
-- in which case we render the first few lines so debugging is still
-- possible.
function M.append_tool_result(buf, result)
  if not result.is_error then return end
  if not result.text or result.text == "" then return end
  local lines = vim.split(result.text, "\n", { plain = true })
  lines = truncate_lines(lines, max_output_lines())
  buf_ensure_newline(buf)
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  local indented = "  " .. table.concat(lines, "\n  ")
  buf_append(buf, indented)
  local end_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_ensure_newline(buf)
  sign_range(buf, start_row, end_row, "error")
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
