-- Per-tab session records. One claude.nvim tab = one session record.
--
-- Lookups:
--   state.current()            → record for the active tab (or nil)
--   state.find_by_buf(buf)     → record owning this buffer
--   state.find_by_id(sid)      → record with this Claude session_id
--   state.get_or_create(tab)   → record for tab, creating if missing
--
-- The singleton fields from the old design live on each record instead.

local M = {}

M.tabs = {}               -- tab_handle → record
M.origin_cwd = nil        -- cwd of the cc caller; used by the picker

local function empty_record()
  return {
    tab = nil,
    session_id = nil,
    session_cwd = nil,
    transcript_buf = nil,
    transcript_win = nil,
    prompt_buf = nil,
    prompt_win = nil,
    job = nil,
    last_assistant_start = nil,
    history = {},
    history_idx = 0,
    context_tokens = 0,
    context_window = 1000000, -- opus-1M default; updated from result.modelUsage
    model = nil,
    permission_always = {}, -- session-scoped always-allow list
    turn_seq = 0,           -- incremented per send (for unique buf names, etc.)
    turn_started_at = nil,  -- os.time() when current turn was sent, nil when idle
    turn_phase = nil,       -- "thinking" | "streaming" | nil
    turn_timer = nil,       -- uv timer that ticks the statusline while a turn runs
  }
end

function M.current_tab()
  return vim.api.nvim_get_current_tabpage()
end

function M.current()
  return M.tabs[M.current_tab()]
end

function M.get_or_create(tab)
  tab = tab or M.current_tab()
  if not M.tabs[tab] then
    M.tabs[tab] = empty_record()
    M.tabs[tab].tab = tab
  end
  return M.tabs[tab]
end

function M.find_by_buf(buf)
  if not buf then return nil end
  for _, s in pairs(M.tabs) do
    if s.transcript_buf == buf or s.prompt_buf == buf then return s end
  end
end

function M.find_by_id(sid)
  if not sid or sid == "" then return nil end
  for _, s in pairs(M.tabs) do
    if s.session_id == sid then return s end
  end
end

function M.remove(tab)
  local rec = M.tabs[tab]
  M.tabs[tab] = nil
  return rec
end

function M.all() return M.tabs end

return M
