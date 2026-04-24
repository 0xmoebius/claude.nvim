-- Prompt buffer + :ClaudeSend.
-- Each Claude tab has its own prompt buffer; we operate on the CURRENT tab's
-- record (state.current()).

local state = require("claude.state")
local render = require("claude.render")
local spawn = require("claude.spawn")
local statusline = require("claude.statusline")

local M = {}

-- Turn indicator lives in the statusline (statusline.render reads
-- rec.spinner_idx / rec.turn_phase / rec.turn_started_at / rec.queue).
-- A 200ms timer advances spinner_idx and forces a statusline redraw.
local function clear_spinner(rec)
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

-- Walk through rec.history and load the selected entry into the prompt.
-- direction +1 = older (higher index), -1 = newer (lower index); idx 0
-- means "blank / live edit" so stepping past index 1 in the newer
-- direction clears the buffer.
local function step_history(rec, direction)
  if not rec or not rec.prompt_buf then return end
  if not vim.api.nvim_buf_is_valid(rec.prompt_buf) then return end
  rec.history = rec.history or {}
  if #rec.history == 0 then return end
  local idx = (rec.history_idx or 0) + direction
  if idx < 0 then idx = 0 end
  if idx > #rec.history then idx = #rec.history end
  rec.history_idx = idx
  if idx == 0 then
    clear_prompt(rec)
  else
    local lines = vim.split(rec.history[idx], "\n", { plain = true })
    vim.api.nvim_buf_set_lines(rec.prompt_buf, 0, -1, false, lines)
  end
  -- Move cursor to end of buffer so the user can continue typing naturally.
  local last = vim.api.nvim_buf_line_count(rec.prompt_buf)
  local line = vim.api.nvim_buf_get_lines(rec.prompt_buf, last - 1, last, false)[1] or ""
  if rec.prompt_win and vim.api.nvim_win_is_valid(rec.prompt_win) then
    pcall(vim.api.nvim_win_set_cursor, rec.prompt_win, { last, #line })
  end
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

  local turn = {
    had_error = false,
    error_text = nil,
    got_text = false,     -- at least one text_delta received
    got_result = false,   -- terminal result event received
  }

  -- Stderr is often noisy (deprecation notices, debug lines). Match
  -- known failure signals so we surface quota / auth / network blowups
  -- instead of letting the turn die silently.
  local STDERR_ERROR_PATTERNS = {
    "error", "failed", "fatal",
    "rate limit", "quota", "exceeded",
    "unauthor", "forbidden", "429",
    "credit", "usage", "invalid api",
  }
  local function stderr_is_error(text)
    local lower = text:lower()
    for _, p in ipairs(STDERR_ERROR_PATTERNS) do
      if lower:find(p, 1, true) then return true end
    end
    return false
  end

  -- Start the turn + animated statusline indicator.
  rec.turn_started_at = os.time()
  rec.turn_phase = "thinking"
  rec.spinner_idx = 0
  if rec.turn_timer then
    pcall(function() rec.turn_timer:stop() end)
    pcall(function() rec.turn_timer:close() end)
  end
  rec.turn_timer = (vim.uv or vim.loop).new_timer()
  rec.turn_timer:start(200, 200, vim.schedule_wrap(function()
    if not rec.turn_started_at then return end
    rec.spinner_idx = (rec.spinner_idx or 0) + 1
    statusline.redraw()
  end))
  statusline.redraw()

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
      turn.got_text = true
      if rec.turn_phase ~= "streaming" then
        rec.turn_phase = "streaming"
        statusline.redraw()
      end
      render.append_assistant_delta(rec.transcript_buf, d.text)
    end,
    thinking_delta = function(d)
      render.append_thinking_delta(rec.transcript_buf, d.text)
    end,
    tool_call = function(d)
      render.append_tool_call(rec.transcript_buf, d)
    end,
    tool_result = function(d)
      render.append_tool_result(rec.transcript_buf, d)
    end,
    result = function(d)
      turn.got_result = true
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
      -- Surface any error the CLI reported. Previously we needed BOTH
      -- is_error and a populated errors[] — which meant quota blowups
      -- (is_error=true, errors=nil/empty) rendered nothing and the turn
      -- just silently stopped. Always show SOMETHING when is_error is
      -- set; fall back to stop_reason or a generic label.
      if d.is_error then
        local msg
        if d.errors and #d.errors > 0 then
          msg = table.concat(d.errors, "\n")
        elseif d.stop_reason and d.stop_reason ~= "" then
          msg = "[claude: " .. d.stop_reason .. "]"
        else
          msg = "[claude: request failed (likely quota / rate limit / auth)]"
        end
        turn.had_error = true
        turn.error_text = msg
        render.append_error(rec.transcript_buf, msg)
      end
    end,
    error = function(d)
      turn.had_error = true
      turn.error_text = d.text or "unknown error"
      render.append_error(rec.transcript_buf, turn.error_text)
    end,
    stderr = function(d)
      if d.text and d.text ~= "" and stderr_is_error(d.text) then
        turn.had_error = true
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
      elseif not turn.got_text and not turn.had_error then
        -- Clean exit but nothing was streamed — the CLI bailed silently.
        -- Most common cause in practice: the user's 5h quota / credit
        -- balance is out, or the API key is invalid. Tell them so they
        -- don't stare at an empty transcript wondering if the process
        -- is still thinking.
        render.append_error(rec.transcript_buf,
          "[no response from claude — check usage, credits, or auth]")
        turn.had_error = true
      end
      statusline.redraw()
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

  -- Client-side slash commands: intercept BEFORE queue / subprocess.
  -- These never travel over stdin to `claude -p`; they're emulated
  -- locally (see lua/claude/commands.lua).
  if require("claude.commands").dispatch(rec, text) then
    return
  end

  if rec.job then
    rec.queue = rec.queue or {}
    table.insert(rec.queue, text)
    statusline.redraw()
    return
  end

  spawn_turn(rec, text)
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

  -- Prompt history: K = older, J = newer. Intentionally overrides vim's
  -- default J (join lines) / K (keywordprg) inside the prompt only.
  if km.history_prev and km.history_prev ~= "" then
    vim.keymap.set("n", km.history_prev, function() step_history(rec, 1) end,
      { buffer = buf, desc = "Claude: older prompt history" })
  end
  if km.history_next and km.history_next ~= "" then
    vim.keymap.set("n", km.history_next, function() step_history(rec, -1) end,
      { buffer = buf, desc = "Claude: newer prompt history" })
  end

  -- Slash-command picker.
  if km.slash_cmd and km.slash_cmd ~= "" then
    vim.keymap.set("n", km.slash_cmd,
      function() require("claude.slash").pick() end,
      { buffer = buf, desc = "Claude: slash command picker" })
  end

  -- @-mention file completion. Wires `completefunc` and remaps `@` in
  -- insert mode to also trigger the completion popup so candidates
  -- appear the moment the user types `@`.
  pcall(function()
    vim.bo[buf].completefunc = "v:lua.require'claude.mentions'.complete"
  end)
  vim.keymap.set("i", "@", "@<C-x><C-u>",
    { buffer = buf, noremap = true, silent = true,
      desc = "Claude: @-mention file completion" })
end

return M
