# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Neovim frontend for the Claude Code CLI. It reads/writes the same
`~/.claude/projects/*/*.jsonl` session store as the official `claude` CLI, so
the two are interchangeable. Core must remain dependency-free (no plenary,
no nui); telescope / oil / neo-tree are optional graceful-degradations.

## Smoke-testing changes

There is no test suite. The contributor ground rule (see README §Contributing)
is to smoke-test in headless nvim before opening a PR — `require` each changed
module and exercise its behavior:

```sh
nvim --headless -c "set rtp+=$(pwd)" -c "runtime! plugin/claude.lua" \
  -c "lua require('claude').setup({})" -c "lua print('ok')" -c "qa!"
```

For end-to-end behavior use `./bin/cc` from any directory — it self-bootstraps
the plugin's rtp so you don't need the in-development copy wired into your
nvim config.

## Architecture

One Claude tab = one session record. No long-running daemon; each turn spawns
a fresh `claude -p` subprocess.

### Turn lifecycle

`prompt.send()` → `spawn.send()` builds argv:

```
claude -p --output-format stream-json --verbose --include-partial-messages \
       [--resume <sid>] [--dangerously-skip-permissions | --permission-mode X]
       [--settings <hook-json>] [--model X]
```

`vim.system` pipes the user message into stdin and streams NDJSON from stdout.
`stream.lua` parses each line and dispatches via `vim.schedule` to handlers in
`prompt.lua`, which call `render.lua` to mutate the transcript buffer. When
the subprocess exits the parser flushes and the turn is done. Session identity
is just the JSONL filename UUID — resume re-attaches by passing `--resume`.

### Module map (lua/claude/)

- `init.lua` — public API (`setup`, `launch`, `pick`, `new_here`, `quit`,
  `cd`, `close_current`, `send`, `interrupt`); `activate()` wires keymaps
  and replays the JSONL on resume.
- `state.lua` — per-tab records keyed by tab handle. Fields on each record
  include `session_id`, `session_cwd`, `transcript_buf`/`prompt_buf`, `job`,
  `context_tokens`/`context_window`, `turn_phase`, `turn_timer`,
  `permission_always` (tab-scoped allowlist).
- `session.lua` + `picker.lua` — enumerate `~/.claude/projects/**/*.jsonl`,
  extract first-prompt titles (skipping boilerplate prefixes like
  `<local-command-…>` / `<system-reminder>`), present via telescope or
  `vim.ui.select`.
- `layout.lua` — tab/window/buffer creation, focus helpers. Also owns
  the "chat-window guard" BufWinEnter autocmd: any non-chat buffer that
  tries to display in the transcript or prompt window gets diverted to a
  new tab so the chat layout stays intact.
- `render.lua` — transcript rendering (user-row bg tint, tool-call one-liners,
  error gutter signs, fenced-block extmarks).
- `prompt.lua` — prompt buffer, `:ClaudeSend`, stream-event handlers, queueing
  (sending during an in-flight turn enqueues rather than dropping).
- `spawn.lua` — `vim.system` wrapper; always passes a `--settings` JSON
  with at least an AskUserQuestion PreToolUse matcher, plus the
  `permission_tools` matchers when `ask_permissions = true`.
- `stream.lua` — newline-delimited JSON parser.
- `statusline.lua` / `tabline.lua` — per-tab winbar and tabline.
- `usage.lua` — opt-in client for the **undocumented** OAuth
  `/api/oauth/usage` endpoint (180s disk cache, 30s lock); reads token from
  macOS keychain then `~/.claude/.credentials.json`. Can break at any time.
- `permissions.lua` + `bin/claude-nvim-auth` — PreToolUse hook (Python 3,
  stdlib only) forwards tool details into nvim via `nvim --remote-expr`; the
  user's answer is returned as the hook's `permissionDecision`.
- `questions.lua` — floating-window picker for `AskUserQuestion`. The hook
  script dispatches AskUserQuestion here instead of `permissions`. Uses a
  tempfile handoff (async picker + polling in the hook) because running the
  picker inside `--remote-expr` freezes the TUI. Wired unconditionally.
  Answer returns to the model as the tool_result via deny+reason — the
  CLI flags it `is_error:true`, but the reason text IS the answer.
- `float_picker.lua` — shared primitive used by `questions.lua`: a
  centered floating window with options + preview pane, j/k nav, Space
  toggle (multi), CR confirm, Esc cancel.
- `peek.lua` — `<CR>` on a transcript `↳ Read/Write/Edit path` line
  opens a read-only floating preview of the referenced file. Row→path
  mapping is recorded on the session record by `render.append_tool_call`
  (stable because the transcript only appends).
- `commands.lua` — client-side slash-command dispatcher. `claude -p`
  doesn't interpret slash commands on stdin, so we intercept a curated
  subset (`/clear`, `/model`, `/cost`, `/memory`) in `prompt.send`
  BEFORE spawning. Handlers mutate `rec` and call
  `render.append_system` for feedback; the subprocess is never spawned
  for a handled command. `slash.lua` reads `commands.list()` — the
  picker only lists what `dispatch()` will actually run.
- `slash.lua` — `<leader>/` picker over the supported slash commands.
  Uses `float_picker` with `filterable = true` (type-to-filter).
- `mentions.lua` — `@`-mention file completion for the prompt buffer.
  `completefunc` walks `git ls-files` (falls back to `vim.fs.dir`).
  Triggered by an insert-mode `@` remap; 5s per-cwd cache.

### Config & commands

`config.lua` holds defaults + user-override merge. User commands and
highlight-group defaults are declared in `plugin/claude.lua`
(`Claude`, `ClaudePick`, `ClaudeNew`, `ClaudeSend`, `ClaudeInterrupt`,
`ClaudeYankBlock`, `ClaudeYankLast`, `ClaudeQuit`, `ClaudeCd`,
`ClaudeUsageDebug`). Every default keymap is driven by `config.opts.keymaps`
and buffer-scoped — **do not bind global keymaps**.

## Conventions specific to this repo

- Requires Neovim ≥ 0.10 (`vim.system`, `vim.uv`, modern extmark API). OK to
  use these freely; don't add 0.9 fallbacks.
- Prefer pure Lua; shelling out is only acceptable for genuinely shell-shaped
  tasks (`git`, `osascript`, `curl`).
- Status info is rendered in the **winbar**, not the statusline — the bottom
  statusline is untouched on purpose (avoids fighting AstroNvim/heirline).
- Highlight groups are set with `default = true` so user colorschemes win,
  and re-applied on `ColorScheme`.
- The `cc` script deliberately raises `ulimit -n` before exec'ing nvim; don't
  remove it (AstroNvim + many LSPs exhausts the macOS default of 256).

## Before staging / committing / pushing

Whenever the user asks to stage, commit, or push, do a sweep *before*
running `git add`:

1. **Clean up orphans.** Delete files/modules/functions/keymaps/config
   entries that your changes left unreferenced. This includes scratch
   files in `/tmp`, commented-out blocks, dead branches in `if` ladders,
   and imports nothing uses. Grep for references before deleting to be
   sure nothing else points at them.
2. **Update docs alongside the code.** If you added/removed a user
   command, keymap, config key, module, CLI flag, or behavior, the
   following must stay in sync in the same commit:
   - `CLAUDE.md` (module map, config & commands, conventions)
   - `README.md` (Features, Default keymaps table, Configuration block,
     File layout, Troubleshooting)
   - `doc/claude.txt` if a new command or keymap would belong there
   - `TODO.md` — cross off anything the commit actually shipped
3. **Verify with a smoke test.** Run the headless `require` + exercise
   check from §Smoke-testing changes for every module you touched.
   Don't commit red.

Do this without being asked — the user should not have to prompt for
cleanup or doc updates.
