-- Shared floating-window picker used by both AskUserQuestion (questions.lua)
-- and sensitive-path approval (permissions.lua).
--
-- Single buffer, rendered as:
--
--   Prompt text (wrapped)
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

local M = {}

function M.open(header, prompt, options, multi, cb)
  if #options == 0 then cb({}); return end

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

  local function render()
    vim.bo[buf].modifiable = true
    local lines = {}
    option_rows = {}

    for _, l in ipairs(vim.split(prompt or "?", "\n", { plain = true })) do
      table.insert(lines, l)
    end
    table.insert(lines, sep)

    for i, opt in ipairs(options) do
      local arrow = (i == state.cursor) and "▶ " or "  "
      local mark = ""
      if multi then mark = state.selected[i] and "[✓] " or "[ ] " end
      option_rows[i] = #lines
      table.insert(lines, arrow .. mark .. (opt.label or "?"))
    end

    table.insert(lines, sep)

    local cur = options[state.cursor]
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
    if multi then
      table.insert(lines, "j/k: nav   <Space>: toggle   <CR>: confirm   <Esc>: cancel")
    else
      table.insert(lines, "j/k: nav   <CR>: confirm   <Esc>: cancel")
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
    local n = #options
    if n == 0 then return end
    state.cursor = ((state.cursor - 1 + delta) % n) + 1
    render()
  end

  bmap("j", function() move(1) end)
  bmap("<Down>", function() move(1) end)
  bmap("k", function() move(-1) end)
  bmap("<Up>", function() move(-1) end)
  bmap("gg", function() state.cursor = 1; render() end)
  bmap("G", function() state.cursor = #options; render() end)

  if multi then
    bmap("<Space>", function()
      state.selected[state.cursor] = not state.selected[state.cursor]
      render()
    end)
  end

  bmap("<CR>", function()
    local picks = {}
    if multi then
      for i = 1, #options do
        if state.selected[i] then table.insert(picks, options[i]) end
      end
      if #picks == 0 then picks = { options[state.cursor] } end
    else
      local cur = options[state.cursor]
      if cur then picks = { cur } end
    end
    finish(picks)
  end)
  bmap("<Esc>", function() finish({}) end)
  bmap("q", function() finish({}) end)
  bmap("<C-c>", function() finish({}) end)

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
