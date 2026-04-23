-- Per-window winbar. We avoid the statusline entirely — it competes with
-- AstroNvim / heirline and repaints on every keystroke, producing flicker.
-- Winbar is a separate per-window strip nvim manages independently, and we
-- push a pre-built literal string to it (no `%!` eval), so nvim just reads
-- the option on redraw. The string only changes when a real state change
-- fires (turn start/end, branch/context/usage update), at which point we
-- rewrite both Claude windows' winbar.

local state = require("claude.state")
local config = require("claude.config")
local git = require("claude.git")

local M = {}

local function fmt_pct(n)
  if n == nil then return "—" end
  return string.format("%d%%", math.floor(n + 0.5))
end

-- Show 0% for fresh sessions instead of hiding the field so users don't
-- perceive ctx as "broken" until their first turn.
local function context_pct(rec)
  if not rec.context_window or rec.context_window == 0 then return nil end
  return (rec.context_tokens or 0) / rec.context_window * 100
end

function M.render(rec)
  local parts = {}

  -- The turn-in-flight indicator (spinner, phase, elapsed, queued) lives as
  -- a right-aligned virt_text on the prompt buffer (see
  -- prompt.render_spinner). Keeping it off the statusline is what finally
  -- killed the terminal flicker — buffer virt_text redraws at line scope,
  -- statusline updates redraw the whole status bar.

  -- Fall back to the tab's cwd if session_cwd hasn't been populated yet
  -- (it's set at layout creation, but be defensive).
  local cwd = rec.session_cwd
  if not cwd or cwd == "" then
    local ok, v = pcall(vim.fn.getcwd)
    cwd = ok and v or nil
  end
  local branch = git.branch(cwd)
  if branch then table.insert(parts, branch) end

  local pct = context_pct(rec)
  if pct then table.insert(parts, "ctx " .. fmt_pct(pct)) end

  if config.opts.subscription_usage then
    local u = require("claude.usage").get()
    if u and u.five_hour and u.five_hour.utilization ~= nil then
      table.insert(parts, "5h " .. fmt_pct(u.five_hour.utilization))
    else
      table.insert(parts, "5h —")
    end
  end

  -- Session id / uuid hash intentionally omitted — it's not information
  -- anyone wants to read on every screen refresh. Use :ClaudePick to see it.

  if #parts == 0 then return "" end
  local out = "  " .. table.concat(parts, "  ·  ") .. " "
  return (out:gsub("%%", "%%%%"))
end

-- Attach: set up winbar on both Claude windows of `rec`, and push the
-- current content. Called once when the layout opens, and then each time
-- state changes, via M.redraw().
function M.attach(rec_or_win)
  if type(rec_or_win) == "number" then
    -- Legacy call shape from layout.lua — just a window handle. No-op; the
    -- state-backed M.redraw() will fill it in.
    return
  end
  M.redraw()
end

-- Apply the current content string to all visible Claude windows.
function M.redraw()
  for _, rec in pairs(state.all()) do
    local str = M.render(rec)
    if str ~= rec._last_winbar then
      rec._last_winbar = str
      for _, win in ipairs({ rec.transcript_win, rec.prompt_win }) do
        if win and vim.api.nvim_win_is_valid(win) then
          pcall(function() vim.wo[win].winbar = str end)
        end
      end
    end
  end
end

-- Periodic timer only needed if something time-based surfaces in the bar.
-- Currently everything is event-driven, so no-op.
function M.start_timer() end

return M
