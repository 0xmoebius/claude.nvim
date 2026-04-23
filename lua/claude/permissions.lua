-- Permission prompt UI, called cross-process by bin/claude-nvim-auth.
--
-- The hook script invokes `nvim --server $SOCK --remote-expr
-- 'v:lua.require("claude.permissions").prompt(tool, input_json)'` and waits
-- synchronously for the stdout value ("allow" | "deny"). We show a modal
-- confirm in the user's nvim; `vim.fn.confirm` blocks the remote-expr call
-- until the user chooses.

local state = require("claude.state")
local config = require("claude.config")

local M = {}

local function count_lines(s)
  if not s or s == "" then return 0 end
  local n = 1
  for _ in s:gmatch("\n") do n = n + 1 end
  return n
end

-- Short human-readable one/few-line summary of a tool call.
local function summarize(tool, input)
  input = input or {}
  if tool == "Bash" then
    local s = "$ " .. (input.command or "?")
    if input.description then s = s .. "   # " .. input.description end
    return s
  elseif tool == "Write" then
    return string.format("Write %s  (%d lines)",
      input.file_path or "?", count_lines(input.content))
  elseif tool == "Edit" then
    local s = "Edit " .. (input.file_path or "?")
    local old = (input.old_string or ""):gsub("\n", "⏎")
    local new = (input.new_string or ""):gsub("\n", "⏎")
    if #old > 60 then old = old:sub(1, 60) .. "…" end
    if #new > 60 then new = new:sub(1, 60) .. "…" end
    return s .. "\n  - " .. old .. "\n  + " .. new
  else
    local preview = input and next(input) and vim.json.encode(input) or ""
    if #preview > 200 then preview = preview:sub(1, 197) .. "…" end
    return tool .. (preview ~= "" and ("  " .. preview) or "")
  end
end

-- Invoked from the hook script via --remote-expr.
-- Returns the literal string "allow" or "deny".
-- Operates on the CURRENT tab's record (whichever Claude tab the user is on
-- when the hook fires).
function M.prompt(tool, input_json)
  local ok, input = pcall(vim.json.decode, input_json)
  if not ok then input = {} end

  local rec = state.current()

  -- Tab-local always-allow list (set via confirm "Always").
  if rec and rec.permission_always and rec.permission_always[tool] then
    return "allow"
  end

  -- Config-level always-allow list (safe read tools etc.).
  for _, name in ipairs(config.opts.permission_always_allow or {}) do
    if name == tool then return "allow" end
  end

  local summary = summarize(tool, input)
  local msg = string.format(
    "[claude.nvim]  %s wants to run:\n\n%s\n\nApprove?",
    tool, summary
  )
  local choice = vim.fn.confirm(msg, "&Yes\n&No\n&Always " .. tool, 2, "Question")
  if choice == 1 then
    return "allow"
  elseif choice == 3 then
    if rec then
      rec.permission_always = rec.permission_always or {}
      rec.permission_always[tool] = true
    end
    return "allow"
  else
    return "deny"
  end
end

-- Kept for back-compat; the per-tab record is reset when a tab closes.
function M.reset() end

return M
