-- TUI-style "quick peek" at a file referenced in the transcript.
--
-- Triggered by <CR> on a tool-call line (↳ Read/Write/Edit path). Opens a
-- read-only scratch copy of the file in a centered float. <Esc> / q
-- dismisses. Keeps the chat layout intact — we never swap a file buffer
-- into the transcript/prompt windows.

local M = {}

local function detect_filetype(path)
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  if ok and ft and ft ~= "" then return ft end
  return ""
end

function M.file(path)
  if not path or path == "" then
    vim.notify("claude.nvim: no file path on this line", vim.log.levels.INFO)
    return
  end
  local expanded = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  if vim.fn.filereadable(expanded) ~= 1 then
    vim.notify("claude.nvim: cannot read " .. expanded, vim.log.levels.WARN)
    return
  end

  local ok_lines, lines = pcall(vim.fn.readfile, expanded)
  if not ok_lines then
    vim.notify("claude.nvim: readfile failed for " .. expanded,
      vim.log.levels.WARN)
    return
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  local ft = detect_filetype(expanded)
  if ft ~= "" then vim.bo[buf].filetype = ft end

  local ui = vim.api.nvim_list_uis()[1] or { width = 100, height = 30 }
  local width = math.max(60, math.floor(ui.width * 0.85))
  local height = math.max(20, math.floor(ui.height * 0.85))
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  local title = vim.fn.fnamemodify(expanded, ":~:.")
  if #title > width - 6 then title = "…" .. title:sub(-(width - 7)) end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].signcolumn = "no"

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  -- Buffer is scratch + bufhidden=wipe, so keymaps here only affect the
  -- peek instance — no leakage to other windows showing the same file.
  for _, lhs in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", lhs, close,
      { buffer = buf, nowait = true, silent = true })
  end
end

return M
