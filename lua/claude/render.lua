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

-- Sticky-bottom: capture before a mutation which windows are "following" the
-- stream (cursor on the last line). After the mutation, only those windows
-- get their cursor pushed to the new EOF — windows where the user has
-- scrolled up stay put. Call capture_sticky() before any buf_append /
-- ensure_newline / append_blank_line, then autoscroll(buf, sticky) after.
local function capture_sticky(buf)
  local sticky = {}
  local last = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_cursor(win)[1] >= last then
      sticky[#sticky + 1] = win
    end
  end
  return sticky
end

local function autoscroll(buf, sticky)
  if not sticky or #sticky == 0 then return end
  local now = (vim.uv or vim.loop).hrtime()
  if (autoscroll_last[buf] or 0) + AUTOSCROLL_THROTTLE_NS > now then return end
  autoscroll_last[buf] = now
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, win in ipairs(sticky) do
    if vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 })
    end
  end
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
  -- User pressed send → force-scroll every window showing this transcript
  -- to the new bottom, regardless of whether they were following the
  -- stream or scrolled up reading history. Rationale: you want to see
  -- your own message land, and reset "sticky follow" for the reply. The
  -- capture_sticky mechanism that governs streaming is bypassed for
  -- this one mutation only.
  local force_sticky = vim.fn.win_findbuf(buf)
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
  -- Bypass the streaming throttle so the cursor definitely makes it to
  -- the bottom, even if we autoscrolled <33ms ago.
  autoscroll_last[buf] = 0
  autoscroll(buf, force_sticky)
end

function M.begin_assistant(buf)
  local sticky = capture_sticky(buf)
  buf_ensure_newline(buf)
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  local s = state.find_by_buf(buf)
  if s then
    s.last_assistant_start = start_row
    s._assistant_tagged_to = start_row - 1
    s._last_kind = nil
  end
  autoscroll(buf, sticky)
end

function M.append_assistant_delta(buf, text)
  local sticky = capture_sticky(buf)
  local s = state.find_by_buf(buf)
  -- When resuming assistant text after a tool call or thinking block,
  -- insert a blank line so the preceding section visually detaches from
  -- the assistant prose that follows.
  if s and (s._last_kind == "tool" or s._last_kind == "thinking") then
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
  autoscroll(buf, sticky)
end

-- Thinking blocks (extended-thinking models). Rendered as a muted italic
-- block headed with `💭 thinking…` so it's visually distinct from both
-- assistant prose and tool-call lines. Streaming-only: we don't re-render
-- from the JSONL on resume because persisted assistant text already
-- includes a summary.
function M.append_thinking_delta(buf, text)
  if not text or text == "" then return end
  local sticky = capture_sticky(buf)
  local s = state.find_by_buf(buf)
  -- First thinking delta in this run: drop a header line.
  if not s or s._last_kind ~= "thinking" then
    buf_ensure_newline(buf)
    if s and s._last_kind then append_blank_line(buf) end
    local header_row = vim.api.nvim_buf_line_count(buf) - 1
    buf_append(buf, "💭 thinking")
    buf_ensure_newline(buf)
    vim.api.nvim_buf_set_extmark(buf, NS, header_row, 0, {
      line_hl_group = "ClaudeThinkingLine",
      right_gravity = false,
    })
    if s then s._thinking_tagged_to = header_row end
  end
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, text)
  local end_row = vim.api.nvim_buf_line_count(buf) - 1
  local from = (s and s._thinking_tagged_to or (start_row - 1)) + 1
  if from < start_row then from = start_row end
  for r = from, end_row do
    vim.api.nvim_buf_set_extmark(buf, NS, r, 0, {
      line_hl_group = "ClaudeThinkingLine",
      right_gravity = false,
    })
  end
  if s then
    s._thinking_tagged_to = end_row
    s._last_kind = "thinking"
  end
  autoscroll(buf, sticky)
end

function M.end_assistant(buf)
  local sticky = capture_sticky(buf)
  buf_ensure_newline(buf)
  -- Force a final scroll to EOF, bypassing the streaming throttle.
  autoscroll_last[buf] = 0
  autoscroll(buf, sticky)
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
  elseif name == "AskUserQuestion" then
    -- Render the first question inline so the transcript shows what was
    -- asked, not the raw tool name. Multi-question payloads show the count.
    local qs = input.questions or {}
    if #qs == 0 then
      s = "AskUserQuestion"
    elseif #qs == 1 then
      s = "Ask: " .. (qs[1].question or "?")
    else
      s = string.format("Ask (%d questions): %s", #qs, qs[1].question or "?")
    end
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

-- Extract the file path a tool call references, if any. Used by the
-- transcript peek binding — only tools with a concrete file_path count.
local function tool_call_path(name, input)
  input = input or {}
  if name == "Read" or name == "Write" or name == "Edit" then
    return input.file_path
  end
  return nil
end

-- Tool calls render as a single flush-left, muted-italic one-liner — no
-- diff, no output. Full details are still in the session JSONL on disk if
-- you need them.
function M.append_tool_call(buf, call)
  local sticky = capture_sticky(buf)
  buf_ensure_newline(buf)
  local row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, "↳ " .. format_tool_compact(call.name, call.input))
  buf_ensure_newline(buf)
  vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
    line_hl_group = "ClaudeToolLine",
    right_gravity = false,
  })
  local s = state.find_by_buf(buf)
  if s then
    s._last_kind = "tool"
    -- Record the file path at this row so <CR> can peek it. Rows are
    -- stable because the transcript only ever appends.
    local path = tool_call_path(call.name, call.input)
    if path then
      s.tool_call_paths = s.tool_call_paths or {}
      s.tool_call_paths[row] = path
    end
  end
  autoscroll(buf, sticky)
end

-- Tool results are noisy. We skip them entirely unless they're an error,
-- in which case we render a compact header + the first few output lines
-- so debugging is still possible. Header gets the tool-call italic style
-- (so the visual grammar matches the preceding ↳ call line); body rows
-- get the error sign in the gutter.
function M.append_tool_result(buf, result)
  if not result.is_error then return end
  local text = result.text
  if not text or text == "" then text = "(no output)" end
  local lines = vim.split(text, "\n", { plain = true })
  lines = truncate_lines(lines, max_output_lines())

  local sticky = capture_sticky(buf)
  buf_ensure_newline(buf)
  local header_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, "  ✗ error")
  buf_ensure_newline(buf)
  local body_start = vim.api.nvim_buf_line_count(buf) - 1
  local indented = "    " .. table.concat(lines, "\n    ")
  buf_append(buf, indented)
  local body_end = vim.api.nvim_buf_line_count(buf) - 1
  buf_ensure_newline(buf)

  -- Header: italic muted (matches tool-call line).
  vim.api.nvim_buf_set_extmark(buf, NS, header_row, 0, {
    line_hl_group = "ClaudeToolLine",
    right_gravity = false,
  })
  -- Body: red gutter bar + italic muted background line (so multi-line
  -- error output is visually chunked with the tool call, not mixed with
  -- assistant prose).
  for r = body_start, body_end do
    vim.api.nvim_buf_set_extmark(buf, NS, r, 0, {
      sign_text = (config.opts.signs and config.opts.signs.char) or "▎",
      sign_hl_group = "ClaudeErrorSign",
      line_hl_group = "ClaudeToolLine",
      right_gravity = false,
    })
  end
  local s = state.find_by_buf(buf)
  if s then s._last_kind = "tool" end
  autoscroll(buf, sticky)
end

-- System messages: locally-generated transcript output from the
-- client-side slash-command layer (e.g. `/clear`, `/model`, `/cost`).
-- Rendered with its own `› ` prefix + ClaudeSystemLine tint so the user
-- can tell at a glance that the text came from claude.nvim, not from
-- the model or from a tool.
function M.append_system(buf, text)
  local sticky = capture_sticky(buf)
  local s = state.find_by_buf(buf)
  if s then s._last_kind = "system" end
  buf_ensure_newline(buf)
  if vim.api.nvim_buf_line_count(buf) > 1 then
    append_blank_line(buf)
  end
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, text)
  local end_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_ensure_newline(buf)
  append_blank_line(buf)
  for r = start_row, end_row do
    vim.api.nvim_buf_set_extmark(buf, NS, r, 0, {
      line_hl_group = "ClaudeSystemLine",
      right_gravity = false,
    })
  end
  vim.api.nvim_buf_set_extmark(buf, NS, start_row, 0, {
    virt_text = { { "› ", "ClaudeSystemPrefix" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
  -- Bypass the streaming throttle — system messages are one-shot.
  autoscroll_last[buf] = 0
  autoscroll(buf, sticky)
end

function M.append_error(buf, text)
  local sticky = capture_sticky(buf)
  buf_ensure_newline(buf)
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, text)
  local end_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_ensure_newline(buf)
  sign_range(buf, start_row, end_row, "error")
  autoscroll(buf, sticky)
end

-- Back-compat shim (rarely used).
function M.append_tool(buf, label)
  local sticky = capture_sticky(buf)
  buf_ensure_newline(buf)
  local start_row = vim.api.nvim_buf_line_count(buf) - 1
  buf_append(buf, label)
  buf_ensure_newline(buf)
  sign_range(buf, start_row, start_row, "tool")
  autoscroll(buf, sticky)
end

return M
