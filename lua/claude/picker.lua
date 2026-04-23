-- Cross-project session picker. Prefers telescope, falls back to vim.ui.select.

local session = require("claude.session")

local M = {}

local function basename(p)
  if not p then return "?" end
  local b = vim.fn.fnamemodify(p, ":t")
  if b == "" then b = p end
  return b
end

-- Build the full row list: [new session entry] + all sessions.
local function build_entries(origin_cwd)
  local rows = {}
  rows[#rows + 1] = {
    kind = "new",
    cwd = origin_cwd,
    title = "+ new session in " .. origin_cwd,
  }
  for _, s in ipairs(session.list()) do
    rows[#rows + 1] = vim.tbl_extend("force", s, { kind = "session" })
  end
  return rows
end

local function format_row(row)
  if row.kind == "new" then return row.title end
  return string.format("%-22s %5s  %s",
    basename(row.cwd):sub(1, 22),
    session.reltime(row.mtime),
    row.title)
end

-- Telescope implementation.
local function telescope_picker(origin_cwd, on_select)
  local ok_t, pickers = pcall(require, "telescope.pickers")
  if not ok_t then return false end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local rows = build_entries(origin_cwd)

  pickers.new({}, {
    prompt_title = "cc — sessions",
    finder = finders.new_table({
      results = rows,
      entry_maker = function(row)
        return {
          value = row,
          display = format_row(row),
          ordinal = (row.kind == "new" and "new " or "") ..
            (row.cwd or "") .. " " .. (row.title or ""),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(bufnr, _)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(bufnr)
        if entry then on_select(entry.value) end
      end)
      return true
    end,
    layout_config = { width = 0.8, height = 0.7, preview_width = 0 },
    previewer = false,
  }):find()
  return true
end

local function fallback_picker(origin_cwd, on_select)
  local rows = build_entries(origin_cwd)
  vim.ui.select(rows, {
    prompt = "cc — pick a session:",
    format_item = format_row,
  }, function(row)
    if row then on_select(row) end
  end)
end

function M.open(opts, on_select)
  opts = opts or {}
  local origin = opts.origin_cwd or vim.fn.getcwd()
  if not telescope_picker(origin, on_select) then
    fallback_picker(origin, on_select)
  end
end

return M
