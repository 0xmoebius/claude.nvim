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
