-- Yank helpers for the transcript buffer. Each works on the current tab's
-- session record.

local state = require("claude.state")

local M = {}

local function current_transcript_buf()
  local cur_buf = vim.api.nvim_get_current_buf()
  local rec = state.find_by_buf(cur_buf) or state.current()
  if rec then return rec.transcript_buf, rec end
  return nil
end

local function fenced_block_at_cursor()
  local cur_buf = vim.api.nvim_get_current_buf()
  local rec = state.find_by_buf(cur_buf)
  if not rec or cur_buf ~= rec.transcript_buf then return nil end
  local cur_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local total = vim.api.nvim_buf_line_count(cur_buf)
  local open_row
  for r = cur_row, 0, -1 do
    local line = vim.api.nvim_buf_get_lines(cur_buf, r, r + 1, false)[1] or ""
    if line:match("^```") then open_row = r; break end
  end
  if not open_row then return nil end
  local close_row
  for r = cur_row, total - 1 do
    if r > open_row then
      local line = vim.api.nvim_buf_get_lines(cur_buf, r, r + 1, false)[1] or ""
      if line:match("^```") then close_row = r; break end
    end
  end
  if not close_row or close_row - 1 < open_row + 1 then return nil end
  return { buf = cur_buf, start_row = open_row + 1, end_row = close_row - 1 }
end

function M.yank_block()
  local range = fenced_block_at_cursor()
  if not range then
    vim.notify("claude.nvim: cursor is not inside a fenced code block",
      vim.log.levels.WARN)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(range.buf,
    range.start_row, range.end_row + 1, false)
  local text = table.concat(lines, "\n")
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
  vim.notify(string.format("claude.nvim: yanked %d lines", #lines))
end

function M.yank_last_assistant()
  local buf, rec = current_transcript_buf()
  if not rec or not rec.last_assistant_start then
    vim.notify("claude.nvim: no assistant message yet", vim.log.levels.WARN)
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local start_row = rec.last_assistant_start
  local end_row = vim.api.nvim_buf_line_count(buf) - 1
  local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row + 1, false)
  while #lines > 0 and lines[1] == "" do table.remove(lines, 1) end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  local text = table.concat(lines, "\n")
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
  vim.notify(string.format("claude.nvim: yanked last reply (%d lines)", #lines))
end

return M
