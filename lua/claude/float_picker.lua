-- Shared floating-window picker used by both AskUserQuestion (questions.lua)
-- and the slash-command picker (slash.lua).
--
-- Single buffer, rendered as:
--
--   Prompt text (wrapped)
--   [filter: xxx]         (filterable mode only)
--   ──────────
--   ▶ [✓] Option A
--     [ ] Option B
--   ──────────
--   Full description of the option under the cursor (wrapped)
--   ──────────
--   j/k nav · <Space> toggle · <CR> confirm · <Esc> cancel
--
-- Calls `cb(picks_array)` exactly once when the user confirms or cancels.
-- `picks_array` is empty on cancel / dismiss.
--
-- `opts.filterable = true` enables a substring filter over option.label +
-- option.description. Printable chars append to the filter; <BS> pops.
-- In filterable mode the j/k navigation bindings are dropped (j/k would
-- otherwise be eaten by the filter) — use arrow keys / <C-n>/<C-p>.

local M = {}

function M.open(header, prompt, options, multi, cb, opts)
  opts = opts or {}
  if #options == 0 then cb({}); return end
  local filterable = opts.filterable and true or false

  local buf = vim.api.nvim_create_buf(false, true)
  local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }
  local width = math.max(40, math.min(110, math.floor(ui.width * 0.75)))
  local height = math.max(14, math.min(34, math.floor(ui.height * 0.7)))
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. (header or "Claude") .. " ",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "claude-picker"

  local NS = vim.api.nvim_create_namespace("claude_float_picker")
  local sep = string.rep("─", math.max(10, width - 2))

  local state = { cursor = 1, selected = {} }
  local option_rows = {}
  local filter = ""
  local visible = options -- options filtered by current `filter`; defaults to all

  local function apply_filter()
    if filter == "" then
      visible = options
    else
      visible = {}
      local needle = filter:lower()
      for _, o in ipairs(options) do
        local hay = ((o.label or "") .. " " .. (o.description or "")):lower()
        if hay:find(needle, 1, true) then visible[#visible + 1] = o end
      end
    end
    if state.cursor > #visible then state.cursor = #visible end
    if state.cursor < 1 then state.cursor = 1 end
  end

  local function render()
    vim.bo[buf].modifiable = true
    local lines = {}
    option_rows = {}

    for _, l in ipairs(vim.split(prompt or "?", "\n", { plain = true })) do
      table.insert(lines, l)
    end
    if filterable then
      table.insert(lines, "filter: " .. filter)
    end
    table.insert(lines, sep)

    if #visible == 0 then
      table.insert(lines, "  (no matches)")
    else
      for i, opt in ipairs(visible) do
        local arrow = (i == state.cursor) and "▶ " or "  "
        local mark = ""
        if multi then mark = state.selected[opt] and "[✓] " or "[ ] " end
        option_rows[i] = #lines
        table.insert(lines, arrow .. mark .. (opt.label or "?"))
      end
    end

    table.insert(lines, sep)

    local cur = visible[state.cursor]
    if cur then
      if cur.label and cur.label ~= "" then
        table.insert(lines, cur.label)
        table.insert(lines, "")
      end
      local desc = cur.description or "(no description)"
      for _, l in ipairs(vim.split(desc, "\n", { plain = true })) do
        table.insert(lines, l)
      end
    end

    table.insert(lines, "")
    table.insert(lines, sep)
    local nav_hint = filterable and "↑/↓: nav" or "j/k: nav"
    if multi then
      table.insert(lines,
        nav_hint .. "   <Space>: toggle   <CR>: confirm   <Esc>: cancel")
    elseif filterable then
      table.insert(lines,
        nav_hint .. "   type to filter   <BS>: back   <CR>: confirm   <Esc>: cancel")
    else
      table.insert(lines, nav_hint .. "   <CR>: confirm   <Esc>: cancel")
    end

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    local cur_row = option_rows[state.cursor]
    if cur_row and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_buf_set_extmark(buf, NS, cur_row, 0, {
        line_hl_group = "Visual",
        right_gravity = false,
      })
      pcall(vim.api.nvim_win_set_cursor, win, { cur_row + 1, 0 })
    end
  end

  local done = false
  local function finish(picks)
    if done then return end
    done = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    vim.schedule(function() cb(picks or {}) end)
  end

  local function bmap(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  local function move(delta)
    local n = #visible
    if n == 0 then return end
    state.cursor = ((state.cursor - 1 + delta) % n) + 1
    render()
  end

  -- Arrow keys always work. j/k only in non-filterable mode (they'd
  -- otherwise get swallowed as filter input).
  bmap("<Down>", function() move(1) end)
  bmap("<Up>", function() move(-1) end)
  bmap("<C-n>", function() move(1) end)
  bmap("<C-p>", function() move(-1) end)
  if not filterable then
    bmap("j", function() move(1) end)
    bmap("k", function() move(-1) end)
    bmap("gg", function() state.cursor = 1; render() end)
    bmap("G", function() state.cursor = #visible; render() end)
  end

  if multi then
    bmap("<Space>", function()
      local cur = visible[state.cursor]
      if cur then
        state.selected[cur] = not state.selected[cur]
        render()
      end
    end)
  end

  bmap("<CR>", function()
    if #visible == 0 then return end
    local picks = {}
    if multi then
      -- In filter mode the selection set is keyed by option table so
      -- toggles survive filter changes.
      for _, o in ipairs(options) do
        if state.selected[o] then table.insert(picks, o) end
      end
      if #picks == 0 then picks = { visible[state.cursor] } end
    else
      local cur = visible[state.cursor]
      if cur then picks = { cur } end
    end
    finish(picks)
  end)
  bmap("<Esc>", function() finish({}) end)
  bmap("<C-c>", function() finish({}) end)
  if not filterable then
    -- `q` is a common "close" key but in filter mode it's a valid
    -- filter character, so only bind it outside filterable mode.
    bmap("q", function() finish({}) end)
  end
  bmap("<BS>", function()
    if filterable and #filter > 0 then
      filter = filter:sub(1, -2)
      apply_filter()
      render()
    end
  end)

  if filterable then
    -- Printable ASCII range as single-key bindings; typing any of these
    -- appends to the filter. Excludes whitespace (bound separately) and
    -- special keys like <CR>, <Esc>.
    local function bind_char(ch)
      bmap(ch, function()
        filter = filter .. ch
        apply_filter()
        render()
      end)
    end
    for code = 33, 126 do
      local ch = string.char(code)
      -- Skip `<` so `<Esc>`, `<CR>`, `<BS>`, `<C-c>` lhs parsing isn't
      -- ambiguous; `<` is rarely needed in filters anyway.
      if ch ~= "<" then bind_char(ch) end
    end
    if not multi then
      -- <Space> doubles as filter input when there's no multi-toggle
      -- consumer competing for it.
      bmap("<Space>", function()
        filter = filter .. " "
        apply_filter()
        render()
      end)
    end
  end

  -- Safety net: if the float is closed by anything else (user :q's it,
  -- buffer wiped, etc.) resolve as cancelled so tempfile pollers unblock.
  vim.api.nvim_create_autocmd({ "WinClosed", "BufWipeout" }, {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function() if not done then finish({}) end end)
    end,
  })

  render()
  vim.cmd("stopinsert")
end

return M
