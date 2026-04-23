-- Open a fresh tab with a transcript + file pane + prompt buffer, bind it to
-- a new per-tab session record in state.tabs.

local state = require("claude.state")
local render = require("claude.render")
local statusline = require("claude.statusline")

local M = {}

-- Counter to give each tab's buffers unique names so switching between two
-- open sessions never clashes on :buffers names.
local SEQ = 0

local function next_seq()
  SEQ = SEQ + 1
  return SEQ
end

local function make_transcript_buf(seq)
  local buf = vim.api.nvim_create_buf(false, true)
  render.init_buffer(buf, string.format("claude://%d/transcript", seq))
  return buf
end

local function make_prompt_buf(seq)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  pcall(vim.api.nvim_buf_set_name, buf, string.format("claude://%d/prompt", seq))
  return buf
end

-- Open a new tab and wire up all the panes. Returns the session record.
function M.open(session_cwd)
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local rec = state.get_or_create(tab)
  local seq = next_seq()

  if session_cwd and session_cwd ~= "" then
    if not pcall(vim.cmd.tcd, vim.fn.fnameescape(session_cwd)) then
      vim.notify("claude.nvim: could not cd into " .. session_cwd,
        vim.log.levels.WARN)
    end
  end
  rec.session_cwd = session_cwd

  -- Transcript
  local transcript_buf = make_transcript_buf(seq)
  vim.api.nvim_set_current_buf(transcript_buf)
  rec.transcript_buf = transcript_buf
  rec.transcript_win = vim.api.nvim_get_current_win()
  render.configure_window(rec.transcript_win)

  -- File pane on right
  local layout_cfg = require("claude.config").opts.layout or {}
  vim.cmd("rightbelow vsplit")
  rec.files_win = vim.api.nvim_get_current_win()
  local files_w = math.floor(vim.o.columns * (layout_cfg.files_width or 0.25))
  vim.api.nvim_win_set_width(rec.files_win, files_w)
  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(rec.files_win, scratch)
  local files_cwd = session_cwd and session_cwd ~= "" and session_cwd or vim.fn.getcwd()
  local opened = false
  if pcall(vim.cmd, "Oil " .. vim.fn.fnameescape(files_cwd)) then
    opened = true
  elseif pcall(vim.cmd, string.format(
      "Neotree filesystem position=current dir=%s", vim.fn.fnameescape(files_cwd))) then
    opened = true
  end
  if not opened then
    pcall(vim.cmd, "Explore " .. vim.fn.fnameescape(files_cwd))
  end

  -- Back to transcript → prompt split below
  vim.api.nvim_set_current_win(rec.transcript_win)
  vim.cmd("belowright split")
  rec.prompt_win = vim.api.nvim_get_current_win()
  rec.prompt_buf = make_prompt_buf(seq)
  vim.api.nvim_win_set_buf(rec.prompt_win, rec.prompt_buf)
  local height = vim.api.nvim_win_get_height(rec.transcript_win)
  local prompt_h = math.max(
    layout_cfg.prompt_height_min or 6,
    math.floor(height * (layout_cfg.prompt_height or 0.33)))
  vim.api.nvim_win_set_height(rec.prompt_win, prompt_h)

  vim.wo[rec.prompt_win].wrap = true
  vim.wo[rec.prompt_win].linebreak = true
  vim.wo[rec.prompt_win].number = false
  vim.wo[rec.prompt_win].relativenumber = false

  statusline.attach(rec.transcript_win)
  statusline.attach(rec.prompt_win)
  statusline.start_timer()

  vim.api.nvim_set_current_win(rec.prompt_win)
  vim.cmd("startinsert")
  return rec
end

-- Close the Claude tab owning `rec`, wipe its buffers, remove from state.
function M.close(rec)
  if not rec then return end
  if rec.job then
    pcall(function() rec.job:kill("sigterm") end)
  end
  if rec.tab and vim.api.nvim_tabpage_is_valid(rec.tab) then
    pcall(vim.cmd, vim.api.nvim_tabpage_get_number(rec.tab) .. "tabclose")
  end
  for _, b in ipairs({ rec.transcript_buf, rec.prompt_buf }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  if rec.tab then state.remove(rec.tab) end
end

-- Jump focus to the tab owning this session record.
function M.focus(rec)
  if rec and rec.tab and vim.api.nvim_tabpage_is_valid(rec.tab) then
    vim.api.nvim_set_current_tabpage(rec.tab)
    if rec.prompt_win and vim.api.nvim_win_is_valid(rec.prompt_win) then
      vim.api.nvim_set_current_win(rec.prompt_win)
    end
  end
end

-- Focus the prompt pane (and enter insert mode).
function M.focus_prompt(rec)
  if not rec then return end
  if rec.prompt_win and vim.api.nvim_win_is_valid(rec.prompt_win) then
    vim.api.nvim_set_current_win(rec.prompt_win)
    vim.cmd("startinsert")
  end
end

-- Focus the transcript pane.
function M.focus_transcript(rec)
  if not rec then return end
  if rec.transcript_win and vim.api.nvim_win_is_valid(rec.transcript_win) then
    if vim.fn.mode() == "i" then vim.cmd("stopinsert") end
    vim.api.nvim_set_current_win(rec.transcript_win)
  end
end

return M
