-- Session discovery: scan ~/.claude/projects/**/*.jsonl and produce
-- a flat list of { id, path, cwd, mtime, title }.

local config = require("claude.config")

local M = {}

local function read_head_lines(path, max_lines, max_bytes)
  -- Read up to max_lines or max_bytes, whichever comes first.
  local f = io.open(path, "r")
  if not f then return {} end
  local lines = {}
  local bytes = 0
  for _ = 1, max_lines do
    local line = f:read("*l")
    if not line then break end
    bytes = bytes + #line
    lines[#lines + 1] = line
    if bytes >= max_bytes then break end
  end
  f:close()
  return lines
end

local function is_boilerplate(text)
  if not text or text == "" then return true end
  if text:sub(1, 1) == "/" and not text:match("^/[^%s]+%s") then
    -- bare slash command like "/compact" or "/pl-log:setup"
    return true
  end
  for _, prefix in ipairs(config.opts.title_skip_prefixes) do
    if text:sub(1, #prefix) == prefix then return true end
  end
  return false
end

local function extract_text(content)
  if type(content) == "string" then return content end
  if type(content) == "table" then
    for _, c in ipairs(content) do
      if type(c) == "table" and c.type == "text" and c.text then
        return c.text
      end
    end
  end
  return nil
end

local function parse_session(path)
  local lines = read_head_lines(path, 80, 256 * 1024)
  local cwd, title
  for _, raw in ipairs(lines) do
    local ok, d = pcall(vim.json.decode, raw)
    if ok and type(d) == "table" then
      if not cwd and type(d.cwd) == "string" then
        cwd = d.cwd
      end
      if not title and d.type == "user" and d.message then
        local text = extract_text(d.message.content)
        if text and not is_boilerplate(text) then
          title = text
        end
      end
      if cwd and title then break end
    end
  end
  if not title then title = "(no prompt)" end
  -- collapse whitespace, truncate
  title = title:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #title > config.opts.title_max_len then
    title = title:sub(1, config.opts.title_max_len - 1) .. "…"
  end
  local stat = vim.uv.fs_stat(path)
  return {
    id = vim.fn.fnamemodify(path, ":t:r"),
    path = path,
    cwd = cwd,
    mtime = stat and stat.mtime.sec or 0,
    title = title,
    size = stat and stat.size or 0,
  }
end

local function reltime(mtime)
  local diff = os.time() - mtime
  if diff < 60 then return "now" end
  if diff < 3600 then return string.format("%dm", math.floor(diff / 60)) end
  if diff < 86400 then return string.format("%dh", math.floor(diff / 3600)) end
  if diff < 86400 * 7 then return string.format("%dd", math.floor(diff / 86400)) end
  if diff < 86400 * 30 then return string.format("%dw", math.floor(diff / (86400 * 7))) end
  if diff < 86400 * 365 then return string.format("%dmo", math.floor(diff / (86400 * 30))) end
  return string.format("%dy", math.floor(diff / (86400 * 365)))
end

function M.list()
  local root = config.opts.projects_dir
  local sessions = {}
  local project_dirs = vim.fn.glob(root .. "/*", false, true)
  for _, dir in ipairs(project_dirs) do
    if vim.fn.isdirectory(dir) == 1 then
      local jsonls = vim.fn.glob(dir .. "/*.jsonl", false, true)
      for _, path in ipairs(jsonls) do
        local session = parse_session(path)
        -- Skip sessions with no cwd (corrupted/incomplete) or empty files.
        if session.cwd and session.size > 0 then
          sessions[#sessions + 1] = session
        end
      end
    end
  end
  table.sort(sessions, function(a, b) return a.mtime > b.mtime end)
  return sessions
end

function M.reltime(mtime) return reltime(mtime) end

-- Dir-name encoding used by Claude Code for new sessions. We only need this
-- for the "new session in $PWD" case where we want to pre-seed the JSONL
-- location; but in practice `claude -p` creates it for us, so this is unused
-- for MVP. Kept here for future use.
function M.encode_cwd(cwd)
  return cwd:gsub("[^%w]", "-")
end

return M
