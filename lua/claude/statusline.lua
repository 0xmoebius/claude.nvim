-- Per-window statusline. Uses g:statusline_winid to find out which window
-- nvim is rendering for, then looks up the session record by its buffer.

local state = require("claude.state")
local config = require("claude.config")
local git = require("claude.git")

local M = {}

local function fmt_pct(n)
  if n == nil then return "—" end
  return string.format("%d%%", math.floor(n + 0.5))
end

local function context_pct(rec)
  if not rec.context_window or rec.context_window == 0 then return nil end
  if not rec.context_tokens or rec.context_tokens == 0 then return nil end
  return rec.context_tokens / rec.context_window * 100
end

function M.render(rec)
  local parts = {}

  local branch = git.branch(rec.session_cwd)
  if branch then table.insert(parts, " " .. branch) end

  local pct = context_pct(rec)
  if pct then table.insert(parts, "ctx " .. fmt_pct(pct)) end

  if config.opts.subscription_usage then
    local u = require("claude.usage").get()
    if u and u.five_hour and u.five_hour.utilization ~= nil then
      table.insert(parts, "5h " .. fmt_pct(u.five_hour.utilization))
    end
  end

  if rec.session_id then
    table.insert(parts, rec.session_id:sub(1, 8))
  end

  if #parts == 0 then return "" end
  local out = "  " .. table.concat(parts, "  ·  ") .. " "
  return (out:gsub("%%", "%%%%"))
end

_G._claude_statusline = function()
  local win = vim.g.statusline_winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then return "" end
  local buf = vim.api.nvim_win_get_buf(win)
  local rec = state.find_by_buf(buf) or state.current()
  if not rec then return "" end
  return M.render(rec)
end

function M.attach(win)
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  vim.wo[win].statusline = "%!v:lua._claude_statusline()"
end

local timer
function M.start_timer()
  if timer then return end
  timer = (vim.uv or vim.loop).new_timer()
  timer:start(30000, 30000, vim.schedule_wrap(function()
    pcall(vim.cmd, "redrawstatus!")
  end))
end

function M.redraw()
  pcall(vim.cmd, "redrawstatus!")
end

return M
