local M = {}

M.defaults = {
  -- ---- subprocess ----------------------------------------------------------
  claude_bin = "claude",
  -- `--dangerously-skip-permissions` bypasses all tool-permission checks.
  -- On by default here because this plugin is typically launched in trusted
  -- local dirs. Set false to fall back to `permission_mode`.
  -- Superseded when `ask_permissions = true` — the PreToolUse hook gates
  -- everything in that path.
  dangerously_skip_permissions = true,
  permission_mode = "acceptEdits",
  model = nil,                       -- nil inherits the Claude Code CLI's default

  -- ---- session discovery ---------------------------------------------------
  projects_dir = vim.fn.expand("~/.claude/projects"),
  title_max_len = 80,
  title_skip_prefixes = {
    "<local-command-",
    "<system-reminder>",
    "<command-name>",
    "<command-message>",
    "<command-args>",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
    "<user-memory-input>",
    "[Request interrupted",
    "Caveat:",
  },

  -- ---- layout (all values 0.0–1.0 of available space) ---------------------
  layout = {
    prompt_height = 0.33, -- bottom prompt pane, fraction of transcript height
    prompt_height_min = 6,
  },

  -- ---- transcript rendering ------------------------------------------------
  signs = {
    char = "▎",
    -- Only errors get a gutter bar by default — everything else relies on
    -- inline prefixes + line background for differentiation. Set any of
    -- these to a hl group name to bring the gutter bar back for that role.
    user = nil,
    assistant = nil,
    tool = nil,
    error = "ClaudeErrorSign",
    user_prefix = "» ",
  },
  tool_output_max_lines = 14,

  -- ---- tabline -------------------------------------------------------------
  tabline = true,

  -- ---- statusline ----------------------------------------------------------
  subscription_usage = true,         -- see :h claude-subscription-usage

  -- ---- interactive permissions --------------------------------------------
  ask_permissions = false,
  permission_tools = { "Bash", "Write", "Edit" },
  permission_always_allow = {},      -- e.g. { "Read", "Grep", "Glob" }

  -- ---- keymaps -------------------------------------------------------------
  -- Set a value to false or "" to disable that binding. Keymaps apply only
  -- inside Claude tab buffers (prompt + transcript).
  keymaps = {
    send            = "<CR>",
    interrupt       = "<C-c>",
    focus_prompt    = "<leader>ca",
    focus_transcript = "<leader>ct",
    pick            = "<leader>cs",
    new_here        = "<leader>cn",
    yank_last       = "<leader>cy",
    yank_block      = "gy",
    close_tab       = "<leader>cc",
    quit_all        = "<leader>cq",
    next_marker     = "]m",
    prev_marker     = "[m",
    peek_file       = "<CR>",
    -- Transcript is read-only: these keys redirect to the prompt in insert
    -- mode. Set to {} or nil to disable.
    transcript_to_insert = { "i", "a", "o", "I", "A", "O" },
  },
}

M.opts = vim.deepcopy(M.defaults)

function M.setup(user)
  M.opts = vim.tbl_deep_extend("force", M.defaults, user or {})
end

return M
