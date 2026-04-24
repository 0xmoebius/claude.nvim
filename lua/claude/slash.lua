-- Slash-command picker. Lists ONLY the commands we can actually
-- execute — i.e. whatever commands.lua has a handler for. The CLI's
-- `-p` mode doesn't interpret slash commands, so anything we can't
-- emulate locally doesn't belong in the picker.
--
-- On select, inserts `<cmd> ` into the prompt (with trailing space so
-- the user can type arguments). Pressing <CR> on the prompt sends it;
-- prompt.send → commands.dispatch runs the handler locally and
-- renders feedback via render.append_system.

local M = {}

function M.pick()
  local state = require("claude.state")
  local layout = require("claude.layout")
  local commands = require("claude.commands")
  local rec = state.current()
  if not rec or not rec.prompt_buf then
    vim.notify("claude.nvim: not on a Claude tab", vim.log.levels.WARN)
    return
  end
  if not vim.api.nvim_buf_is_valid(rec.prompt_buf) then return end

  require("claude.float_picker").open(
    "Slash commands",
    "Type to filter, <CR> to insert into prompt",
    commands.list(),
    false,
    function(picks)
      if #picks == 0 then return end
      local cmd = picks[1].label
      vim.api.nvim_buf_set_lines(rec.prompt_buf, 0, -1, false, { cmd .. " " })
      layout.focus_prompt(rec)
      if rec.prompt_win and vim.api.nvim_win_is_valid(rec.prompt_win) then
        pcall(vim.api.nvim_win_set_cursor, rec.prompt_win, { 1, #cmd + 1 })
      end
    end,
    { filterable = true })
end

return M
