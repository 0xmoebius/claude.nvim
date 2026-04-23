-- Prompt buffer + :ClaudeSend.
-- Each Claude tab has its own prompt buffer; we operate on the CURRENT tab's
-- record (state.current()).

local state = require("claude.state")
local render = require("claude.render")
local spawn = require("claude.spawn")
local statusline = require("claude.statusline")
local notify = require("claude.notify")

local M = {}

-- Animated turn indicator (spinner + phase + elapsed + queued) implemented
-- as a right-aligned virt_text extmark on the prompt buffer. This keeps
-- the animation out of the statusline — previous attempts drove flicker
-- because redrawstatus repaints the whole status bar, whereas an extmark
-- update only redraws its own line.

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local SPINNER_NS = vim.api.nvim_create_namespace("claude_spinner")

local function fmt_elapsed(started)
  local s = os.time() - (started or os.time())
  if s < 60 then return string.format("%ds", s) end
  local m = math.floor(s / 60)
  return string.format("%dm%02ds", m, s - m * 60)
end

local function render_spinner(rec)
  if not rec.prompt_buf or not vim.api.nvim_buf_is_valid(rec.prompt_buf) then
    return
  end
  local frame = SPINNER[((rec.spinner_idx or 0) % #SPINNER) + 1]
  local phase = rec.turn_phase or "working"
  local elapsed = fmt_elapsed(rec.turn_started_at)
  local q = (rec.queue and #rec.queue > 0)
    and string.format(" +%d", #rec.queue) or ""
  local text = string.format(" %s %s %s%s ", frame, phase, elapsed, q)
  local opts = {
    virt_text = { { text, "ClaudeAssistantSign" } },
    virt_text_pos = "right_align",
  }
  if rec.spinner_mark_id then opts.id = rec.spinner_mark_id end
  rec.spinner_mark_id = vim.api.nvim_buf_set_extmark(
    rec.prompt_buf, SPINNER_NS, 0, 0, opts)
end

local function clear_spinner(rec)
  if rec.prompt_buf and vim.api.nvim_buf_is_valid(rec.prompt_buf) then
    pcall(vim.api.nvim_buf_clear_namespace,
      rec.prompt_buf, SPINNER_NS, 0, -1)
  end
  rec.spinner_mark_id = nil
  if rec.turn_timer then
    pcall(function() rec.turn_timer:stop() end)
    pcall(function() rec.turn_timer:close() end)
    rec.turn_timer = nil
  end
end

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

-- Render the user's message into the transcript + push it into history.
-- Called synchronously on send, BEFORE spawn, so queued messages appear in
-- the chat immediately rather than waiting for the current turn to finish.
local function render_user(rec, text)
  add_history(rec, text)
  render.append_user(rec.transcript_buf, text)
end

-- Fire the actual subprocess for `text`. Does NOT re-render the user
-- message (that's render_user's job). Used both for fresh turns and for
-- turns flushed from the queue.
local function spawn_turn(rec, text)
  render.begin_assistant(rec.transcript_buf)

  local turn = { had_error = false, error_text = nil }

  -- Start the turn + animated indicator. The spinner is an extmark on the
  -- prompt buffer (updated via timer); the statusline is not touched.
  rec.turn_started_at = os.time()
  rec.turn_phase = "thinking"
  rec.spinner_idx = 0
  if rec.turn_timer then
    pcall(function() rec.turn_timer:stop() end)
    pcall(function() rec.turn_timer:close() end)
  end
  rec.turn_timer = (vim.uv or vim.loop).new_timer()
  rec.turn_timer:start(120, 120, vim.schedule_wrap(function()
    if not rec.turn_started_at then return end
    rec.spinner_idx = (rec.spinner_idx or 0) + 1
    render_spinner(rec)
  end))
  render_spinner(rec)

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
      if rec.turn_phase ~= "streaming" then
        rec.turn_phase = "streaming"
        render_spinner(rec)
      end
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
      -- Stream is DONE. Stop the spinner immediately instead of waiting
      -- for the subprocess to exit (can trail the result event by 1–2s).
      rec.turn_started_at = nil
      rec.turn_phase = nil
      clear_spinner(rec)
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
      rec.turn_started_at = nil
      rec.turn_phase = nil
      clear_spinner(rec)
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
      -- Flush one queued message. The user's message was rendered into
      -- the transcript when they pressed send; we just spawn the subprocess.
      if rec.queue and #rec.queue > 0 then
        local next_text = table.remove(rec.queue, 1)
        vim.defer_fn(function()
          if state.find_by_buf(rec.transcript_buf) == rec then
            spawn_turn(rec, next_text)
          end
        end, 50)
      end
    end,
  }

  rec.job = spawn.send(text, {
    session_id = rec.session_id,
    cwd = rec.session_cwd,
  }, handlers)
end

-- Public entry. Reads the prompt buffer, clears it, and either fires a new
-- turn immediately or appends to rec.queue while a turn is in flight.
function M.send()
  local rec = active_record()
  if not rec then
    vim.notify("claude.nvim: no active Claude session", vim.log.levels.WARN)
    return
  end
  local text = prompt_text(rec)
  if text:gsub("%s", "") == "" then return end
  clear_prompt(rec)

  -- Always render the user's message into the transcript immediately so
  -- they see their input land in the chat even when it's queued behind an
  -- in-flight turn.
  render_user(rec, text)

  if rec.job then
    rec.queue = rec.queue or {}
    table.insert(rec.queue, text)
    statusline.redraw()
    return
  end

  spawn_turn(rec, text)
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
    rec.turn_started_at = nil
    rec.turn_phase = nil
    clear_spinner(rec)
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
  -- `k` on the top row of the prompt jumps to the transcript. Below that it
  -- falls through to vim's default (move up a line). Uses expr=true so the
  -- "fall through" returns the literal key.
  vim.keymap.set("n", "k", function()
    if vim.api.nvim_win_get_cursor(0)[1] == 1 then
      vim.schedule(function()
        require("claude.layout").focus_transcript(require("claude.state").current())
      end)
      return ""
    end
    return "k"
  end, { buffer = buf, expr = true, silent = true,
         desc = "Claude: up, or escape to transcript at top" })
end

return M
