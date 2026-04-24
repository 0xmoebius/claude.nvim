-- Per-window status bar for claude.nvim.
--
-- We set `vim.wo[win].statusline` directly on each Claude window. Heirline
-- reassigns `vim.o.statusline` on various autocmd events (TextChangedI,
-- ModeChanged, InsertEnter…), but window-local options always override the
-- global, so our setting persists without needing to fight heirline per
-- keystroke. `laststatus=2` keeps per-window statuslines visible.
--
-- We clear `winbar` globally (heirline's winbar is the "bar above the input
-- box" the user saw). Non-Claude windows in other tabs are untouched
-- because winbar is restored on :ClaudeQuit.

local state = require("claude.state")
local config = require("claude.config")
local git = require("claude.git")

local M = {}

local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function fmt_pct(n)
  if n == nil then return "—" end
  return string.format("%d%%", math.floor(n + 0.5))
end

local function fmt_elapsed(started)
  local s = os.time() - (started or os.time())
  if s < 60 then return string.format("%ds", s) end
  local m = math.floor(s / 60)
  return string.format("%dm%02ds", m, s - m * 60)
end

local function context_pct(rec)
  if not rec.context_window or rec.context_window == 0 then return nil end
  local pct = (rec.context_tokens or 0) / rec.context_window * 100
  if pct > 100 then pct = 100 end
  return pct
end

function M.render(rec)
  local parts = {}

  if rec.turn_started_at then
    local phase = rec.turn_phase or "working"
    local frame = SPINNER[((rec.spinner_idx or 0) % #SPINNER) + 1]
    local s = frame .. " " .. phase .. " " .. fmt_elapsed(rec.turn_started_at)
    if rec.queue and #rec.queue > 0 then
      s = s .. string.format(" +%d", #rec.queue)
    end
    table.insert(parts, s)
  end

  local branch
  if rec.session_cwd and rec.session_cwd ~= "" then
    branch = git.branch(rec.session_cwd)
  end
  if not branch then
    local ok, tabcwd = pcall(vim.fn.getcwd)
    if ok and tabcwd and tabcwd ~= "" and tabcwd ~= rec.session_cwd then
      branch = git.branch(tabcwd)
    end
  end
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

  if #parts == 0 then return "" end
  local out = "  " .. table.concat(parts, "  ·  ") .. " "
  return (out:gsub("%%", "%%%%"))
end

-- Window-local statusline function. g:statusline_winid is set by nvim to
-- the window whose statusline is being evaluated; we pick the matching
-- Claude rec by buffer. For windows we don't own this is never called
-- (we only assign the expression to our windows).
_G._claude_statusline = function()
  local winid = vim.g.statusline_winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then return "" end
  local buf = vim.api.nvim_win_get_buf(winid)
  local rec = state.find_by_buf(buf)
  if not rec then return "" end
  return M.render(rec)
end

local installed = false
local augroup
local watchdog
local saved = { winbar = nil, laststatus = nil }

-- Set window-local option with explicit scope, so subsequent global
-- reassignments (from heirline etc.) cannot stomp our value. Using
-- `vim.wo[win].x = v` is ambiguous and can silently fall through to global.
local function set_local(win, name, value)
  pcall(vim.api.nvim_set_option_value, name, value,
    { scope = "local", win = win })
end

local PROMPT_SL = "%!v:lua._claude_statusline()"
local TRANSCRIPT_SL = " "

local function get_local(win, name)
  local ok, v = pcall(vim.api.nvim_get_option_value, name,
    { scope = "local", win = win })
  if ok then return v end
  return nil
end

function M.attach(rec)
  if rec.transcript_win and vim.api.nvim_win_is_valid(rec.transcript_win) then
    set_local(rec.transcript_win, "statusline", TRANSCRIPT_SL)
    set_local(rec.transcript_win, "winbar", "")
    local cur = vim.wo[rec.transcript_win].winhighlight or ""
    if not cur:find("StatusLine:") then
      local add = "StatusLine:Normal,StatusLineNC:Normal"
      set_local(rec.transcript_win, "winhighlight",
        cur == "" and add or (cur .. "," .. add))
    end
  end
  if rec.prompt_win and vim.api.nvim_win_is_valid(rec.prompt_win) then
    set_local(rec.prompt_win, "statusline", PROMPT_SL)
    set_local(rec.prompt_win, "winbar", "")
  end
end

-- Reassert our local statusline/winbar on our Claude windows if someone
-- (heirline) stomped them via `:set`. Equality-checked to avoid recursion
-- and, more importantly, per-keystroke flicker: if our local value is
-- already correct, we don't touch anything.
local function reassert()
  for _, rec in pairs(state.all()) do
    if rec.prompt_win and vim.api.nvim_win_is_valid(rec.prompt_win) then
      if get_local(rec.prompt_win, "statusline") ~= PROMPT_SL then
        set_local(rec.prompt_win, "statusline", PROMPT_SL)
      end
      if get_local(rec.prompt_win, "winbar") ~= "" then
        set_local(rec.prompt_win, "winbar", "")
      end
    end
    if rec.transcript_win and vim.api.nvim_win_is_valid(rec.transcript_win) then
      if get_local(rec.transcript_win, "statusline") ~= TRANSCRIPT_SL then
        set_local(rec.transcript_win, "statusline", TRANSCRIPT_SL)
      end
      if get_local(rec.transcript_win, "winbar") ~= "" then
        set_local(rec.transcript_win, "winbar", "")
      end
    end
  end
end

function M.install()
  if installed then return end
  installed = true
  saved.winbar = vim.o.winbar
  saved.laststatus = vim.o.laststatus
  vim.o.laststatus = 2
  vim.o.winbar = ""
  augroup = vim.api.nvim_create_augroup("ClaudeStatusbar", { clear = true })
  -- Mode transitions are when heirline reassigns `vim.o.statusline` (its
  -- InsertEnter/InsertLeave/ModeChanged handlers). That `:set` writes the
  -- current window's local value too, so our prompt window's statusline
  -- goes blank the moment you enter insert mode. These autocmds fire ONCE
  -- per transition (not per keystroke), so reasserting here is flicker-free.
  vim.api.nvim_create_autocmd(
    { "InsertEnter", "InsertLeave", "InsertChange", "ModeChanged",
      "TextChangedI", "TextChangedP", "CursorMovedI", "CompleteChanged",
      "CursorHoldI", "TabEnter", "CmdlineEnter", "CmdlineLeave",
      "WinEnter", "BufEnter" },
    {
      group = augroup,
      callback = function()
        -- vim.schedule defers to after the current event tick, which is
        -- where heirline's handlers run. Our reassert is equality-checked
        -- (no write when already ours), so in the steady state nvim sees
        -- no option change and emits no redraw. When heirline stomps, our
        -- deferred handler fires in the same tick before nvim paints, so
        -- the user sees only the final (ours) content — no visible flicker.
        if not state.current() then return end
        vim.schedule(reassert)
      end,
    })
  -- Watchdog: a plain `vim.o.statusline = x` (which heirline uses) does
  -- NOT fire OptionSet in practice, so we can't rely on it. Instead, poll
  -- every 250ms and reassert our per-window locals if they've been stomped.
  -- reassert() is equality-checked, so when our values are already correct
  -- nothing is written and no repaint is triggered. 250ms means a short
  -- visible blip (well below a human-perceptible "flicker") if heirline
  -- ever wins; in practice it shouldn't, because window-local >= global.
  watchdog = (vim.uv or vim.loop).new_timer()
  watchdog:start(250, 250, vim.schedule_wrap(reassert))
end

function M.uninstall()
  if not installed then return end
  installed = false
  if augroup then pcall(vim.api.nvim_del_augroup_by_id, augroup); augroup = nil end
  if watchdog then
    pcall(function() watchdog:stop() end)
    pcall(function() watchdog:close() end)
    watchdog = nil
  end
  if saved.laststatus ~= nil then vim.o.laststatus = saved.laststatus end
  if saved.winbar ~= nil then vim.o.winbar = saved.winbar end
  saved = { winbar = nil, laststatus = nil }
end

-- Compatibility shims.
function M.ensure_laststatus() end
function M.restore_laststatus() M.uninstall() end
function M.start_timer() end

function M.redraw()
  pcall(vim.cmd, "redrawstatus")
end

return M
