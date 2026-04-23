if vim.g.loaded_claude_nvim == 1 then return end
vim.g.loaded_claude_nvim = 1

-- Highlight groups. `default = true` means user-defined groups in their
-- colorscheme win; these apply only when the group isn't already set.
local function set_hl(name, link)
  vim.api.nvim_set_hl(0, name, { link = link, default = true })
end
-- Gutter-bar colors per role. Override in your colorscheme to taste.
local function apply_defaults()
  set_hl("ClaudeUserSign", "DiagnosticOk")        -- green-ish
  set_hl("ClaudeAssistantSign", "Function")       -- theme accent
  set_hl("ClaudeToolSign", "DiagnosticWarn")      -- yellow/orange
  set_hl("ClaudeErrorSign", "DiagnosticError")    -- red
  set_hl("ClaudeTab", "TabLine")
  set_hl("ClaudeTabSel", "TabLineSel")
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
