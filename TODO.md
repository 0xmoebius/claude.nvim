# TODO

## Statusline flicker / disappears while typing

**Symptom.** After opening a Claude tab the status bar (branch · ctx · 5h)
renders fine in Normal mode. Entering Insert mode and typing characters causes
the bar to flicker and go blank. It eventually reappears after enough input or
on returning to Normal mode. Reproduced on the user's AstroNvim / heirline
setup; not reproducible in plain `nvim -u NONE`.

**What we tried (all in `lua/claude/statusline.lua`, see git history).**
1. Per-window `vim.wo[win].statusline` — silently stomped whenever someone
   later does `vim.o.statusline = …` (setting a global-local option with `:set`
   writes the current window's local value too).
2. Explicit `nvim_set_option_value(scope="local")` — ditto, same stomp.
3. `OptionSet` autocmd reasserting — does NOT fire for `vim.o.x = y` Lua
   assignments in practice, so never triggered.
4. 250ms uv watchdog polling + equality-checked `reassert()` — too slow; the
   bar is observably blank mid-keystroke before we recover.
5. Autocmd reassert on every plausible insert-mode event:
   `InsertEnter/InsertLeave/InsertChange/ModeChanged/TextChangedI/`
   `TextChangedP/CursorMovedI/CompleteChanged/CursorHoldI/TabEnter/`
   `CmdlineEnter/CmdlineLeave/WinEnter/BufEnter`, all deferred with
   `vim.schedule` so we run after heirline's synchronous handler in the same
   event tick. Still flickers for the user.

**Current state in the repo.** Per-window statusline + all the autocmds
above + 250ms watchdog. Works cleanly in headless tests against a fake
heirline that stomps on `InsertEnter`/`TextChangedI`/`CursorMovedI`.
Real-world AstroNvim still flickers, so something else is writing to the
statusline on an event we haven't caught, or via a uv timer we can't
intercept with autocmds.

**Next approach to try.** Stop sharing nvim's `statusline` option with
heirline entirely: render our bar into a **floating window** overlay
(`nvim_open_win` with `relative=editor`, `style=minimal`, `focusable=false`,
`zindex` high) positioned on the row just above the cmdline, full-width,
sized by `VimResized`. Update via the existing `statusline.redraw()` path
and the 200ms turn-spinner timer. This bypasses heirline's option writes
completely — there's nothing for them to stomp.

Open questions for the float-overlay approach:
- Should it cover the whole screen bottom (single bar for the Claude tab)
  or only the prompt pane?
- Hide on non-Claude tabs — likely a `TabEnter` open/close dance, or create
  the float once and toggle `hide=true` via `nvim_win_set_config`.
- Highlight: `winhighlight = "Normal:StatusLine"` keeps it visually
  indistinguishable from a real statusline.
- Interaction with `cmdheight=0` (AstroNvim's default): verify the float
  doesn't get clobbered when the cmdline expands to show a message.

## Done / parking lot for tomorrow

- Remove push/desktop notifications — done (will redo from scratch).

## QOL backlog (2026-04-24 brainstorm)

Ordered roughly by ROI.

### Medium

- **Transcript search + jump** — `/` or telescope over message rows. Long
  chats are scroll-only today.
- **Quickfix from tool calls** — `render.append_tool_call` already maps
  row → path (used by peek). Extend into a `:ClaudeQuickfix` that populates
  qflist with every Read/Write/Edit for the current turn so `:copen` jumps
  between referenced files.
- **Pipe diagnostics / visual selection → prompt** —
  `:ClaudeSendSelection`, `:ClaudeSendDiagnostics`. Tight LSP glue.
- **render-markdown.nvim passthrough** — confirm the transcript's `nofile`
  buftype doesn't block it; document an opt-in config.
- **Image / file paste into prompt** — paste handler → temp file →
  `@path` injection. Matches official Code UX.
- **Retry last turn** — if the subprocess exits non-zero or the stream
  truncates, one-keystroke re-send from the last user message.
- **Tool output "expand full"** — today truncates silently at
  `tool_output_max_lines`. Add an inline `[+N lines]` extmark with `<CR>`
  to expand into a float.
- **Model / permission presets** — saved profiles per tab
  (`prod = opus + manual`, `hack = sonnet + skip`). Config-driven.
- **Permission-hook failure visibility** — if the socket is stale, today
  it silently denies. Surface a badge in the winbar.

### Larger

- **Checkpoint / fork session** — copy this JSONL up to line N into a new
  tab. The JSONL-as-session model makes it mostly a file copy.
- **Tabline grouping / sorting** — sort by recency, group by project cwd,
  filter. Useful past ~6 open tabs.

### Polish

- **Peek follows scroll** — the file-preview float is pinned; should close
  or re-anchor when the source line scrolls off.
