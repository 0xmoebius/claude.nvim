-- Prompt buffer + :ClaudeSend.
-- Each Claude tab has its own prompt buffer; we operate on the CURRENT tab's
-- record (state.current()).

local state = require("claude.state")
local render = require("claude.render")
local spawn = require("claude.spawn")
local statusline = require("claude.statusline")
local notify = require("claude.notify")

local M = {}

local function prompt_text(rec)
  if not rec.prompt_buf or not vim.api.nvim_buf_is_valid(rec.prompt_buf) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(rec.prompt_buf, 0, -1, false)
  return table.concat(lines, "\n")
end

local function clear_prompt(rec)
  if not rec.prompt_buf or not vim.api.nvim_buf_is_valid(rec.prompt_buf) then return end
  vim.api.nvim_buf_set_lines(rec.prompt_buf, 0, -1, false, { "" })
end

local function add_history(rec, text)
  rec.history = rec.history or {}
  table.insert(rec.history, 1, text)
  while #rec.history > 100 do table.remove(rec.history) end
  rec.history_idx = 0
end

-- Work out which tab this call is operating on. If the user invokes
-- :ClaudeSend while not on a Claude tab, fall back to finding the session
-- owning the current buffer (e.g. they're in the prompt buffer via <CR>).
local function active_record()
  local rec = state.current()
  if rec and rec.prompt_buf then return rec end
  return state.find_by_buf(vim.api.nvim_get_current_buf())
end

function M.send()
  local rec = active_record()
  if not rec then
    vim.notify("claude.nvim: no active Claude session", vim.log.levels.WARN)
    return
  end
  if rec.job then
    vim.notify("claude.nvim: a turn is already in flight on this tab",
      vim.log.levels.WARN)
    return
  end
  local text = prompt_text(rec)
  if text:gsub("%s", "") == "" then return end

  add_history(rec, text)
  render.append_user(rec.transcript_buf, text)
  clear_prompt(rec)
  render.begin_assistant(rec.transcript_buf)

  local turn = { had_error = false, error_text = nil }

  local handlers = {
    init = function(data)
      if not rec.session_id then
        rec.session_id = data.session_id
        rec.session_cwd = data.cwd or rec.session_cwd
      end
      if data.model then rec.model = data.model end
      statusline.redraw()
    end,
    message_start = function(data)
      if data.usage then
        rec.context_tokens = (data.usage.input_tokens or 0)
          + (data.usage.cache_read_input_tokens or 0)
          + (data.usage.cache_creation_input_tokens or 0)
      end
      if data.model then rec.model = data.model end
      statusline.redraw()
    end,
    text_delta = function(d)
      render.append_assistant_delta(rec.transcript_buf, d.text)
    end,
    tool_call = function(d)
      render.append_tool_call(rec.transcript_buf, d)
    end,
    tool_result = function(d)
      render.append_tool_result(rec.transcript_buf, d)
    end,
    result = function(d)
      if d.model_usage then
        for _, u in pairs(d.model_usage) do
          if type(u) == "table" and u.contextWindow then
            rec.context_window = u.contextWindow
            break
          end
        end
      end
      statusline.redraw()
      if d.is_error and d.errors and d.errors[1] then
        turn.had_error = true
        turn.error_text = table.concat(d.errors, "\n")
        render.append_error(rec.transcript_buf, turn.error_text)
      end
    end,
    error = function(d)
      turn.had_error = true
      turn.error_text = d.text or "unknown error"
      render.append_error(rec.transcript_buf, turn.error_text)
    end,
    stderr = function(d)
      if d.text and d.text:lower():match("error") then
        render.append_error(rec.transcript_buf, d.text)
      end
    end,
    exit = function(d)
      render.end_assistant(rec.transcript_buf)
      rec.job = nil
      if d.code ~= 0 and d.code ~= nil then
        render.append_error(rec.transcript_buf,
          string.format("[claude exited with code %d]", d.code))
        turn.had_error = true
      end
      statusline.redraw()
      local project = vim.fn.fnamemodify(rec.session_cwd or "", ":t")
      if project == "" then project = "claude" end
      if turn.had_error then
        local preview = (turn.error_text or ""):gsub("%s+", " ")
        notify.notify(project .. " — error",
          preview ~= "" and preview:sub(1, 200) or "claude exited with error",
          { sound = "Basso" })
      else
        notify.notify(project .. " — ready",
          M.last_assistant_preview(rec, 200) or "response ready")
      end
    end,
  }

  rec.job = spawn.send(text, {
    session_id = rec.session_id,
    cwd = rec.session_cwd,
  }, handlers)
end

function M.last_assistant_preview(rec, max_chars)
  if not rec or not rec.last_assistant_start or not rec.transcript_buf then
    return nil
  end
  local buf = rec.transcript_buf
  if not vim.api.nvim_buf_is_valid(buf) then return nil end
  local start_row = rec.last_assistant_start
  local end_row = vim.api.nvim_buf_line_count(buf) - 1
  local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row + 1, false)
  local text = table.concat(lines, " ")
    :gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  if #text > max_chars then text = text:sub(1, max_chars - 1) .. "…" end
  return text
end

function M.interrupt()
  local rec = active_record()
  if rec and rec.job then
    pcall(function() rec.job:kill("sigint") end)
    render.append_error(rec.transcript_buf, "[interrupted]")
    render.end_assistant(rec.transcript_buf)
    rec.job = nil
  end
end

function M.setup_keymaps(rec)
  if not rec or not rec.prompt_buf then return end
  local buf = rec.prompt_buf
  local km = require("claude.config").opts.keymaps or {}
  if km.send and km.send ~= "" then
    vim.keymap.set("n", km.send, M.send,
      { buffer = buf, desc = "Claude: send" })
  end
  if km.interrupt and km.interrupt ~= "" then
    vim.keymap.set("n", km.interrupt, M.interrupt,
      { buffer = buf, desc = "Claude: interrupt" })
  end
end

return M
