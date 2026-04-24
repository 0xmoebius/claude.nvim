# claude.nvim

A vim-native alternative frontend for [Claude Code](https://claude.com/product/claude-code).

Run Claude Code from any directory on your machine, pick any prior session
from any project, and drive it from inside neovim — with real vim motions,
buffer-level copy/paste, per-session tabs, and a status bar that shows context
usage and git branch.

## Features

- **`cc` launcher** — run it from any shell, anywhere. You get a fuzzy
  picker across every Claude Code session on your machine, each row showing
  the project it belongs to, when you last touched it, and its first prompt.
- **Real vim motions in the prompt.** The input is a normal nvim buffer;
  `ciw`/`.`/macros/registers/LSP/snippets all just work.
- **Clean copy from responses.** Transcript uses `wrap + linebreak`, so
  visual-selecting and yanking returns the original unwrapped text — no more
  stripping terminal-wrap linebreaks by hand.
- **Per-session tabs.** Each pick opens in its own tab; switch with native
  `gt`/`gT`. Tabline labels tabs by project cwd.
- **Shares sessions with the official CLI.** Reads and writes the same
  `~/.claude/projects/…/*.jsonl` store, so a session you start in nvim is
  visible in `claude -c` and vice versa.
- **Compact tool-call rendering.** Each call shows as a muted italic
  one-liner (`↳ Bash ls -la`); output is hidden unless it's an error.
- **User-turn styling.** User messages get a subtle background tint, bold
  weight, and a `» ` prefix. Claude's replies are plain. Visually
  distinct turns without cluttering the view with labels.
- **Animated turn indicator.** Right-aligned spinner + phase + elapsed
  time + queued count, rendered as a virt_text extmark on the prompt
  pane (off the statusline, so it doesn't flicker).
- **Message queueing.** Press send while a turn is in flight — your
  message lands in the transcript immediately and auto-fires when the
  previous turn completes.
- **Winbar** at the top of each Claude window shows: git branch, context %,
  optional 5-hour subscription usage %. No session id noise.
- **Interactive permission prompts.** Optional: route tool-permission
  decisions into a nvim modal instead of auto-accepting.
- **Cross-pane navigation.** `k` at the top of the prompt jumps to the
  transcript; `j` at an empty bottom of the transcript jumps back to the
  prompt. `<leader>ca` / `<leader>ct` also work.

## Requirements

- Neovim ≥ 0.10 (uses `vim.system`, `vim.uv`, modern extmark API)
- [Claude Code](https://claude.com/product/claude-code) CLI on `$PATH`
  (`claude --version` should work)
- Python 3 (only for the permission-forwarding hook; stdlib-only)
- Optional:
  - [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) — for
    the session picker (falls back to `vim.ui.select` otherwise)
  - [oil.nvim](https://github.com/stevearc/oil.nvim) or
    [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim) — for the
    file pane (falls back to netrw)

## Install

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "your-fork/claude.nvim",
  cmd = { "Claude", "ClaudePick", "ClaudeNew", "ClaudeQuit" },
  dependencies = {
    "nvim-telescope/telescope.nvim", -- optional
  },
  opts = {
    -- see "Configuration" below
  },
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "your-fork/claude.nvim",
  requires = { "nvim-telescope/telescope.nvim" },
  config = function() require("claude").setup({}) end,
}
```

### Manual

```sh
git clone https://github.com/your-fork/claude.nvim ~/code/claude.nvim
```

```lua
vim.opt.rtp:append("~/code/claude.nvim")
require("claude").setup({})
```

### The `cc` launcher

Symlink it onto your `$PATH`:

```sh
ln -s ~/code/claude.nvim/bin/cc ~/.local/bin/cc
```

`cc` is a self-bootstrapping shell script — it invokes nvim with the
plugin's runtimepath appended, so it works even if you haven't wired
claude.nvim into your nvim config. If you _have_ wired it, the duplicate
rtp entry is a no-op.

> ⚠ `cc` is also the conventional name for the system C compiler on
> Unix-likes (`/usr/bin/cc`). If you compile C code, this symlink shadows
> it — either use `clang` / `gcc` directly, or rename to something else
> (e.g. `ln -s ...bin/cc ~/.local/bin/cced` to keep the old name).

## Usage

```sh
$ cc            # anywhere on disk — picker across all sessions
```

From inside nvim:

- `:Claude`       — open the picker
- `:ClaudePick`   — alias; opens in a new tab if a different session is picked
- `:ClaudeNew`    — new session in current cwd
- `:ClaudeSend`   — send the prompt buffer contents
- `:ClaudeYankBlock`, `:ClaudeYankLast` — copy helpers
- `:ClaudeQuit`   — close all Claude tabs and exit nvim

### Default keymaps (inside a Claude tab)

| Keys                             | Action                                       |
|----------------------------------|----------------------------------------------|
| `<CR>` (prompt, normal)          | Send message                                 |
| `<C-c>` (prompt)                 | Interrupt in-flight turn                     |
| `<leader>ca`                     | Focus the prompt (enter insert)              |
| `<leader>ct`                     | Focus the transcript                         |
| `i`/`a`/`o`/`I`/`A`/`O` (transcript) | Jump to prompt + insert (read-only redirect) |
| `]m` / `[m` (transcript)         | Jump next / prev message                     |
| `<leader>cs`                     | Open picker (new tab)                        |
| `<leader>cn`                     | New session in cwd                           |
| `<leader>cc`                     | Close this Claude tab                        |
| `<leader>cq`                     | Close all + quit nvim                        |
| `<leader>cy`                     | Yank last assistant reply                    |
| `gy` (transcript)                | Yank fenced code block under cursor          |
| `gt` / `gT`                      | Switch between Claude tabs (vim native)      |

All of these are configurable; see below.

## Configuration

Every option lives under `require("claude").setup({...})` (or `opts = {...}`
in lazy.nvim). Defaults:

```lua
require("claude").setup({
  -- Claude CLI / subprocess
  claude_bin = "claude",
  dangerously_skip_permissions = true,  -- pass --dangerously-skip-permissions
  permission_mode = "acceptEdits",      -- fallback when both perms off
  model = nil,                          -- nil inherits CLI default

  -- Session discovery
  projects_dir = vim.fn.expand("~/.claude/projects"),
  title_max_len = 80,

  -- Layout (fractions of available space)
  layout = {
    prompt_height = 0.33,
    prompt_height_min = 6,
  },

  -- Role markers. Only errors get a gutter bar by default; user/assistant
  -- rely on background tint / italic + inline prefix for differentiation.
  signs = {
    char = "▎",
    user = nil,           -- nil = no gutter bar for that role
    assistant = nil,
    tool = nil,
    error = "ClaudeErrorSign",
    user_prefix = "» ",   -- inline prefix on each user turn
  },
  tool_output_max_lines = 14,

  -- Winbar / tabline / subscription
  tabline = true,
  subscription_usage = true,            -- 5h quota in the winbar

  -- Interactive permissions (off by default; when on, supersedes
  -- dangerously_skip_permissions and routes every listed tool through a
  -- nvim confirm)
  ask_permissions = false,
  permission_tools = { "Bash", "Write", "Edit" },
  permission_always_allow = {},

  -- Keymaps (set any to false or "" to disable)
  keymaps = {
    send             = "<CR>",
    interrupt        = "<C-c>",
    focus_prompt     = "<leader>ca",
    focus_transcript = "<leader>ct",
    pick             = "<leader>cs",
    new_here         = "<leader>cn",
    yank_last        = "<leader>cy",
    yank_block       = "gy",
    close_tab        = "<leader>cc",
    quit_all         = "<leader>cq",
    next_marker      = "]m",
    prev_marker      = "[m",
    transcript_to_insert = { "i", "a", "o", "I", "A", "O" },
  },
})
```

### Highlight groups

Override in your colorscheme or via `:hi`:

| Group                    | Default                    | Where it shows                |
|--------------------------|----------------------------|-------------------------------|
| `ClaudeUserLine`         | `CursorLine.bg` + bold     | Full-line bg tint on user rows |
| `ClaudeUserPrefix`       | `ClaudeUserSign`           | `» ` prefix on user turns     |
| `ClaudeAssistantSign`    | `Function`                 | Right-aligned spinner fg       |
| `ClaudeToolLine`         | `Comment.fg` + italic      | Tool-call one-liners          |
| `ClaudeErrorSign`        | `DiagnosticError`          | Gutter bar on error rows      |
| `ClaudePromptBg`         | `NormalFloat`              | Prompt pane background         |
| `ClaudeTab` / `ClaudeTabSel` | `TabLine` / `TabLineSel` | Tabline inactive / active    |

```lua
vim.api.nvim_set_hl(0, "ClaudeUserLine",      { bg = "#2a2c3c", bold = true })
vim.api.nvim_set_hl(0, "ClaudeAssistantSign", { fg = "#cba6f7" })
vim.api.nvim_set_hl(0, "ClaudeToolLine",      { fg = "#6c7086", italic = true })
```

### Subscription usage

`subscription_usage = true` (default) adds a `5h XX%` segment to the winbar.
The plugin reads your Claude Code OAuth token from the macOS keychain
(fallback: `~/.claude/.credentials.json`) and POSTs it to the **undocumented**
endpoint `https://api.anthropic.com/api/oauth/usage` with a 180s disk cache
+ 30s min-interval lock (same mechanism as `ccstatusline`). This is not an
official API; it can break or rate-limit at any time. Set to `false` to
disable. `:ClaudeUsageDebug` prints the current fetch state.

### Interactive permissions

Set `ask_permissions = true` to route tool-permission prompts into nvim
instead of auto-accepting. On any listed tool, Claude's run is suspended and
you see:

```
[claude.nvim]  Bash wants to run:

$ rm -rf /tmp/data   # Cleaning up

Approve?  (Y)es  (N)o  (A)lways Bash
```

Mechanics: a PreToolUse hook in a temp `--settings` JSON points at
`bin/claude-nvim-auth`, which forwards the tool details to nvim via
`--remote-expr`. Your answer travels back to Claude as the hook's
`permissionDecision`.

The "Always X" choice is scoped to the current tab only.

## How it works

Each turn spawns:

```
claude -p --output-format stream-json --verbose --include-partial-messages \
       --resume <session-id> --permission-mode <mode>
```

`vim.system` pipes your prompt into stdin and streams newline-delimited JSON
events from stdout. A small parser (`stream.lua`) turns each event into
renderer calls via `vim.schedule`. There's no long-running Claude process —
one `claude -p` subprocess per turn. Session identity is just the JSONL
filename UUID; resume with `--resume`.

### File layout

```
claude.nvim/
├── bin/
│   ├── cc                       shell launcher
│   └── claude-nvim-auth         PreToolUse hook (Python 3)
├── lua/claude/
│   ├── init.lua                 setup, launch, pick, new_here, quit
│   ├── config.lua               defaults + user overrides
│   ├── state.lua                per-tab session records
│   ├── session.lua              discover sessions in ~/.claude/projects/
│   ├── picker.lua               Telescope + vim.ui.select fallback
│   ├── layout.lua               create/close/focus tabs + panes
│   ├── render.lua               transcript rendering, gutter signs
│   ├── prompt.lua               prompt buffer, :ClaudeSend, handlers
│   ├── spawn.lua                vim.system wrapper around claude -p
│   ├── stream.lua               NDJSON stream-json parser
│   ├── statusline.lua           per-tab statusline
│   ├── tabline.lua              per-tab tabline
│   ├── yank.lua                 clean-copy helpers
│   ├── permissions.lua          PreToolUse prompt handler
│   ├── usage.lua                OAuth /api/oauth/usage client (opt-in)
│   └── git.lua                  branch lookup w/ TTL cache
├── plugin/claude.lua            user commands + hl group defaults
├── doc/claude.txt               :h claude
└── README.md
```

## Troubleshooting

- **"no nvim socket; cannot forward permissions"** — you set
  `ask_permissions = true` but your nvim has no server socket. The plugin
  calls `vim.fn.serverstart()` on first send, so this shouldn't happen
  unless your config disables servers. Check `:echo v:servername`.

- **`ctx X%` on resume** — seeded from the persisted `message.usage` in the
  JSONL. On a fresh new session you start at `ctx 0%`; each subsequent turn
  refreshes it from the `message_start.usage` event.

- **Statusline flickers** — our status info is rendered in the **winbar**
  (top of each Claude window), not the statusline. The bottom statusline is
  whatever your plugin manager / AstroNvim / heirline normally draws; we
  don't touch it. If the winbar itself flickers, AstroNvim may be
  overriding it on `BufEnter` — we re-apply on `WinEnter`/`BufEnter`/
  `TabEnter` but if a plugin fights harder, you may need to disable it.

- **Turn hangs silently** — if `claude -p` hits a network/API issue it can
  hang without emitting events. `<C-c>` in the prompt SIGINTs the
  subprocess and resets state. (Your in-flight message won't be in the
  JSONL because claude -p never persisted it.)

- **Telescope picker doesn't find a session** — the picker only reads
  `~/.claude/projects/*/*.jsonl`. If a project doesn't show, check that
  directory. Title extraction skips boilerplate prefixes
  (`<local-command-…>`, `<system-reminder>`, etc.) and may fall through to
  "(no prompt)" for sessions with only slash commands or caveats as user
  turns.

- **Permissions hang forever** — the auth hook blocks on
  `nvim --remote-expr`. If the socket path becomes stale (e.g. original nvim
  died), the hook times out after `CLAUDE_NVIM_TIMEOUT` seconds (default
  3600) and returns "deny".

- **Subscription usage shows `5h —`** — Anthropic returned 429 or no token
  found. Check `~/.cache/claude.nvim/usage.json` and the lockfile.

## Contributing

PRs welcome. A few ground rules:

- Keep the core dependency-free (no plenary, no nui). Optional plugins are
  graceful degradations.
- Prefer pure Lua over shelling out, except where a shell tool is the
  simplest honest answer (`git`, `osascript`, `curl`).
- Don't bind global keymaps; scope to Claude buffers.
- Tests: smoke-test in headless nvim (`nvim --headless -c ...`) and verify
  module load + behavior before opening a PR.

## License

MIT. See [LICENSE](./LICENSE).
