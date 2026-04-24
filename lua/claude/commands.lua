-- Client-side slash-command layer.
--
-- `claude -p` is non-interactive: slash commands typed into its stdin
-- are sent to the model as plain text, not interpreted. So the CLI's
-- built-in `/clear`, `/model`, etc. do nothing here. This module
-- intercepts a curated subset before the subprocess spawns and
-- implements them locally, writing feedback into the transcript via
-- `render.append_system`.
--
-- Only commands we can fully emulate without the interactive CLI are
-- supported — the picker (slash.lua) lists exactly what dispatch()
-- will actually handle.

local render = require("claude.render")

local M = {}

local function feedback(rec, text)
  if rec and rec.transcript_buf and vim.api.nvim_buf_is_valid(rec.transcript_buf) then
    render.append_system(rec.transcript_buf, text)
  end
end

-- ---- handlers ------------------------------------------------------------

-- Drop session id, wipe transcript, reset per-turn render state.
-- Next `prompt.send()` will spawn a fresh `claude -p` without --resume,
-- which starts a brand new session id.
local function h_clear(rec, _args)
  rec.session_id = nil
  rec.context_tokens = nil
  rec.context_window = nil
  rec._last_kind = nil
  rec.last_assistant_start = nil
  rec._assistant_tagged_to = nil
  rec._thinking_tagged_to = nil
  rec.tool_call_paths = nil
  if rec.transcript_buf and vim.api.nvim_buf_is_valid(rec.transcript_buf) then
    local NS = vim.api.nvim_get_namespaces()["claude_roles"]
    if NS then
      vim.api.nvim_buf_clear_namespace(rec.transcript_buf, NS, 0, -1)
    end
    vim.api.nvim_buf_set_lines(rec.transcript_buf, 0, -1, false, { "" })
  end
  feedback(rec, "[cleared — next turn starts a new session]")
  pcall(function() require("claude.statusline").redraw() end)
end

-- /model           → show current model
-- /model <name>    → set per-session model override
local function h_model(rec, args)
  local config = require("claude.config")
  if not args or args == "" then
    local cur = rec.model or config.opts.model or "(CLI default)"
    feedback(rec, "[model: " .. cur .. "]")
    return
  end
  rec.model = args
  feedback(rec, "[model set to " .. args .. " for this session]")
  pcall(function() require("claude.statusline").redraw() end)
end

-- Render a context-usage summary from whatever we already harvested
-- from the stream (we don't have per-turn cost data in -p mode, so
-- this is a context snapshot rather than a dollar figure).
local function h_cost(rec, _args)
  local tokens = rec.context_tokens or 0
  local window = rec.context_window or 0
  local pct = (window > 0) and math.floor(tokens / window * 100) or 0
  local model = rec.model or require("claude.config").opts.model or "(default)"
  local lines = {
    string.format("[cost / context snapshot]"),
    string.format("  model:    %s", model),
    string.format("  context:  %d / %d tokens (%d%%)",
      tokens, window, pct),
  }
  feedback(rec, table.concat(lines, "\n"))
end

-- Open CLAUDE.md for editing in a new tab. Prefer the project-local
-- one (session_cwd); fall back to the user-global one.
local function h_memory(rec, _args)
  local candidates = {}
  if rec.session_cwd and rec.session_cwd ~= "" then
    candidates[#candidates + 1] = rec.session_cwd .. "/CLAUDE.md"
  end
  candidates[#candidates + 1] = vim.fn.expand("~/.claude/CLAUDE.md")
  local target
  for _, p in ipairs(candidates) do
    if vim.fn.filereadable(p) == 1 then target = p; break end
  end
  if not target then
    -- Nothing exists yet; offer to create the project-local one.
    target = candidates[1] or candidates[2]
    feedback(rec, "[memory: no CLAUDE.md found — opening a new buffer at " .. target .. "]")
  else
    feedback(rec, "[memory: opening " .. target .. "]")
  end
  vim.schedule(function()
    vim.cmd("tabedit " .. vim.fn.fnameescape(target))
  end)
end

-- ---- registry ------------------------------------------------------------

M.handlers = {
  ["/clear"]  = {
    fn = h_clear,
    description = "Drop session id and wipe the transcript — next turn starts fresh",
  },
  ["/model"]  = {
    fn = h_model,
    description = "Show or set the session's model (e.g. /model opus, /model sonnet)",
  },
  ["/cost"]   = {
    fn = h_cost,
    description = "Show context-window usage for this session",
  },
  ["/memory"] = {
    fn = h_memory,
    description = "Open CLAUDE.md for this cwd (falls back to ~/.claude/CLAUDE.md)",
  },
}

-- Return a picker-ready option list (label + description), sorted.
function M.list()
  local out = {}
  for cmd, h in pairs(M.handlers) do
    out[#out + 1] = { label = cmd, description = h.description }
  end
  table.sort(out, function(a, b) return a.label < b.label end)
  return out
end

-- Try to handle `text` as a slash command. Returns true iff a handler
-- ran (and thus the caller should skip spawning the subprocess).
function M.dispatch(rec, text)
  if not text or text == "" then return false end
  -- Only match when the first non-whitespace token is a slash command
  -- on its own line. "/clear" at the start of a paragraph is a command;
  -- "/path/to/file" mid-sentence is not.
  local first = text:match("^%s*([^\n]*)") or ""
  local cmd, args = first:match("^(/[%w_%-]+)%s*(.*)$")
  if not cmd then return false end
  local h = M.handlers[cmd]
  if not h then return false end
  local ok, err = pcall(h.fn, rec, vim.trim(args or ""))
  if not ok then
    feedback(rec, "[" .. cmd .. " failed: " .. tostring(err) .. "]")
  end
  return true
end

return M
