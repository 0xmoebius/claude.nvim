-- Desktop notifications for when a Claude turn finishes or errors.
-- Only fires when the hosting terminal isn't frontmost (so you don't get a
-- ping while you're staring at the transcript).
--
-- macOS:  osascript display notification  (always available)
-- Linux:  notify-send                     (if installed)

local config = require("claude.config")

local M = {}

local function is_macos() return vim.fn.has("macunix") == 1 end
local function is_linux()
  return vim.fn.has("unix") == 1 and not is_macos()
end

-- Terminal hosts we consider "nvim is focused when this app is frontmost".
local TERM_APPS = {
  "iTerm2", "Terminal", "Alacritty", "kitty", "Ghostty",
  "WezTerm", "tmux", "Neovim", "VimR", "MacVim",
}

local function is_nvim_focused()
  if not is_macos() then return true end -- can't tell → assume yes on other OSes
  local ok, r = pcall(function()
    return vim.system({
      "osascript", "-e",
      'tell application "System Events" to get name of first application process whose frontmost is true',
    }, { text = true, timeout = 500 }):wait()
  end)
  if not ok or not r or r.code ~= 0 then return true end
  local front = (r.stdout or ""):gsub("%s+$", "")
  for _, app in ipairs(TERM_APPS) do
    if front == app then return true end
  end
  for _, app in ipairs(config.opts.notification_terminal_apps or {}) do
    if front == app then return true end
  end
  return false
end

local function esc(s) return (s or ""):gsub('\\', '\\\\'):gsub('"', '\\"') end

local function mac_notify(title, body, sound)
  local script = string.format(
    'display notification "%s" with title "%s" subtitle "%s"%s',
    esc(body), esc("claude.nvim"), esc(title),
    sound and (' sound name "' .. esc(sound) .. '"') or ""
  )
  vim.system({ "osascript", "-e", script }, { detach = true })
end

local function linux_notify(title, body)
  vim.system({ "notify-send", title, body }, { detach = true })
end

-- Public API.
--   opts.sound       — macOS sound name (e.g. "Glass", "Basso"); defaults to config
--   opts.only_when_unfocused — default true; skip if terminal is frontmost
function M.notify(title, body, opts)
  opts = opts or {}
  if not config.opts.notifications then return end
  local only_unfocused = opts.only_when_unfocused
  if only_unfocused == nil then only_unfocused = true end
  if only_unfocused and is_nvim_focused() then return end
  if is_macos() then
    mac_notify(title, body, opts.sound or config.opts.notification_sound)
  elseif is_linux() then
    linux_notify(title, body)
  end
end

return M
