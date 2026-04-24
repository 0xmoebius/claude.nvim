if vim.g.loaded_claude_nvim == 1 then return end
vim.g.loaded_claude_nvim = 1

-- Highlight groups. `default = true` means user-defined groups in their
-- colorscheme win; these apply only when the group isn't already set.
local function set_hl(name, link)
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end
-- Derive ClaudeUserLine from the theme's CursorLine bg (falling back to
-- Visual if CursorLine isn't defined) and make it bold + defaultable.
local function resolve_bg(name)
  local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and h and h.bg then return h.bg end
  return nil
end

local function apply_defaults()
  set_hl("ClaudeUserSign", "DiagnosticOk")        -- green-ish
  set_hl("ClaudeAssistantSign", "Function")       -- theme accent
  set_hl("ClaudeToolSign", "DiagnosticWarn")      -- yellow/orange
  set_hl("ClaudeErrorSign", "DiagnosticError")    -- red
  set_hl("ClaudeTab", "TabLine")
  set_hl("ClaudeTabSel", "TabLineSel")
  set_hl("ClaudeUserPrefix", "ClaudeUserSign")    -- prefix colour matches bar
  set_hl("ClaudePromptBg", "NormalFloat")         -- input pane tint
  -- Explicit italic + fg copied from Comment so tool-call lines are
  -- consistently italic regardless of whether the theme's Comment is.
  local function comment_fg()
    local ok, h = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
    if ok and h and h.fg then return h.fg end
  end
  vim.api.nvim_set_hl(0, "ClaudeToolLine", {
    fg = comment_fg(),
    italic = true,
    default = true,
  })

  -- ClaudeUserLine: the bg tint on user rows. Needs to be bold + a real bg
  -- (linking to CursorLine was confusing because native cursorline shares
  -- the same colour). Copy CursorLine/Visual bg; keep default=true so user
  -- overrides still win.
  local bg = resolve_bg("CursorLine") or resolve_bg("Visual")
  vim.api.nvim_set_hl(0, "ClaudeUserLine", {
    bg = bg,
    bold = true,
    default = true,
  })
end
apply_defaults()
vim.api.nvim_create_autocmd("ColorScheme", { callback = apply_defaults })

local function lazy(name)
  return function(...) return require("claude")[name](...) end
end

vim.api.nvim_create_user_command("Claude", function() require("claude").launch() end,
  { desc = "claude.nvim: launch picker and open session" })
vim.api.nvim_create_user_command("ClaudePick", function() require("claude").pick() end,
  { desc = "claude.nvim: reopen cross-project session picker" })
vim.api.nvim_create_user_command("ClaudeNew", function() require("claude").new_here() end,
  { desc = "claude.nvim: new session in current cwd" })
vim.api.nvim_create_user_command("ClaudeSend", function() require("claude").send() end,
  { desc = "claude.nvim: send prompt buffer contents" })
vim.api.nvim_create_user_command("ClaudeInterrupt", function() require("claude").interrupt() end,
  { desc = "claude.nvim: interrupt in-flight turn" })
vim.api.nvim_create_user_command("ClaudeYankBlock",
  function() require("claude.yank").yank_block() end,
  { desc = "claude.nvim: yank fenced code block under cursor" })
vim.api.nvim_create_user_command("ClaudeYankLast",
  function() require("claude.yank").yank_last_assistant() end,
  { desc = "claude.nvim: yank last assistant reply" })
vim.api.nvim_create_user_command("ClaudeQuit",
  function() require("claude").quit() end,
  { desc = "claude.nvim: close all Claude tabs and quit nvim" })
vim.api.nvim_create_user_command("ClaudeCd",
  function(opts) require("claude").cd(opts.args) end,
  { nargs = "?", complete = "dir",
    desc = "claude.nvim: change current session's cwd (branch, git.branch, etc)" })
vim.api.nvim_create_user_command("ClaudeUsageDebug", function()
  local u = require("claude.usage")
  print(u.debug())
  u.refresh(function(d)
    vim.schedule(function()
      if d then print("refresh: success") else print("refresh: failed") end
      print(u.debug())
    end)
  end)
end, { desc = "claude.nvim: print subscription-usage fetch state" })
