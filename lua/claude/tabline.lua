-- Custom tabline: renders Claude tabs as [cwd-basename], non-Claude tabs
-- fall back to the buffer tail. Current tab gets TabLineSel; others TabLine.
--
-- Opt-in via config.tabline = true (default). Disable to keep your existing
-- tabline (e.g. heirline/lualine).

local state = require("claude.state")

local M = {}

local function label_for(tab)
  local rec = state.all()[tab]
  if rec then
    local cwd = rec.session_cwd or ""
    local base = vim.fn.fnamemodify(cwd, ":t")
    if base == "" then base = cwd ~= "" and cwd or "claude" end
    return base
  end
  -- Non-Claude tab: use focused window's buffer tail.
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  local win = wins[1]
  if not win then return "[No Name]" end
  local buf = vim.api.nvim_win_get_buf(win)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return "[No Name]" end
  return vim.fn.fnamemodify(name, ":t")
end

function M.render()
  local cur = vim.api.nvim_get_current_tabpage()
  local tabs = vim.api.nvim_list_tabpages()
  local parts = {}
  for i, tab in ipairs(tabs) do
    local is_cur = (tab == cur)
    local is_claude = state.all()[tab] ~= nil
    local hl
    if is_cur then
      hl = is_claude and "%#ClaudeTabSel#" or "%#TabLineSel#"
    else
      hl = is_claude and "%#ClaudeTab#" or "%#TabLine#"
    end
    -- Make each tab clickable (switches to it).
    local clickable = "%" .. i .. "T"
    parts[#parts + 1] = clickable .. hl .. " " .. i .. " " .. label_for(tab) .. " "
  end
  parts[#parts + 1] = "%#TabLineFill#%T"
  return table.concat(parts)
end

_G._claude_tabline = function() return M.render() end

local installed = false
local saved = {
  tabline = nil,
  showtabline = nil,
}

function M.install()
  if installed then return end
  installed = true
  saved.tabline = vim.o.tabline
  saved.showtabline = vim.o.showtabline
  vim.o.tabline = "%!v:lua._claude_tabline()"
  vim.o.showtabline = 2
end

function M.uninstall()
  if not installed then return end
  installed = false
  vim.o.tabline = saved.tabline or ""
  vim.o.showtabline = saved.showtabline or 1
end

return M
