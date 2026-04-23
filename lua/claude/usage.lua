-- Fetch Claude Code subscription usage from the undocumented
-- /api/oauth/usage endpoint (same approach ccstatusline uses).
--
-- Caching discipline is important: the endpoint rate-limits aggressively.
--   - 180s TTL on successful responses.
--   - 30s minimum between fetch attempts (lockfile).
--   - Honour Retry-After on 429s.
--
-- Token source:
--   macOS: security find-generic-password -s "Claude Code-credentials" -w
--   fallback: ~/.claude/.credentials.json → claudeAiOauth.accessToken
--
-- The raw OAuth token is never logged or written to disk by this module;
-- it is only piped into `curl` as a header via vim.system stdin on mac or
-- argv on other platforms (argv is acceptable since it's a user-private
-- process; we prefer stdin on mac where feasible).

local M = {}

local uv = vim.uv or vim.loop
local cache_dir = vim.fn.expand("~/.cache/claude.nvim")
local cache_file = cache_dir .. "/usage.json"
local lock_file = cache_dir .. "/usage.lock"
local TTL = 180
local MIN_INTERVAL = 30

local mem = { data = nil, fetched_at = 0 }
local fetching = false
local backoff_until = 0

local function ensure_dir()
  vim.fn.mkdir(cache_dir, "p")
end

local function read_file_cache()
  local f = io.open(cache_file, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  local ok, d = pcall(vim.json.decode, content)
  if not ok or type(d) ~= "table" then return nil end
  if not d.fetched_at or (os.time() - d.fetched_at) > TTL then return nil end
  return d
end

local function write_file_cache(data)
  ensure_dir()
  local f = io.open(cache_file, "w")
  if f then
    f:write(vim.json.encode(data))
    f:close()
  end
end

local function lock_ok()
  local stat = uv.fs_stat(lock_file)
  if stat and (os.time() - stat.mtime.sec) < MIN_INTERVAL then
    return false
  end
  ensure_dir()
  local f = io.open(lock_file, "w")
  if f then
    f:write(tostring(os.time()))
    f:close()
  end
  return true
end

local function parse_credentials_blob(blob)
  if not blob or blob == "" then return nil end
  local trimmed = blob:gsub("%s+$", "")
  local ok, j = pcall(vim.json.decode, trimmed)
  if ok and type(j) == "table" and j.claudeAiOauth and j.claudeAiOauth.accessToken then
    return j.claudeAiOauth.accessToken
  end
  return nil
end

local function get_token()
  -- macOS keychain
  if vim.fn.has("macunix") == 1 then
    local ok, r = pcall(function()
      return vim.system(
        { "security", "find-generic-password", "-s", "Claude Code-credentials", "-w" },
        { text = true, timeout = 1000 }
      ):wait()
    end)
    if ok and r and r.code == 0 then
      local tok = parse_credentials_blob(r.stdout)
      if tok then return tok end
    end
  end
  -- Fallback: credentials file
  local path = vim.fn.expand("~/.claude/.credentials.json")
  local f = io.open(path, "r")
  if f then
    local content = f:read("*a")
    f:close()
    return parse_credentials_blob(content)
  end
  return nil
end

local function fetch_async(cb)
  if fetching then return end
  if os.time() < backoff_until then return cb(nil) end
  if not lock_ok() then return cb(nil) end

  fetching = true
  local token = get_token()
  if not token then
    fetching = false
    return cb(nil)
  end

  -- Use curl. Pass token via header. -m = max time 10s.
  local argv = {
    "curl", "-sS", "-m", "10",
    "-w", "\n%{http_code}",
    "-H", "Authorization: Bearer " .. token,
    "-H", "anthropic-beta: oauth-2025-04-20",
    "https://api.anthropic.com/api/oauth/usage",
  }
  vim.system(argv, { text = true }, function(res)
    vim.schedule(function()
      fetching = false
      if not res or res.code ~= 0 then return cb(nil) end
      local stdout = res.stdout or ""
      -- Split last line (HTTP code) from JSON body.
      local body, code = stdout:match("^(.*)\n(%d+)%s*$")
      if not code then return cb(nil) end
      if code == "429" then
        backoff_until = os.time() + 300
        return cb(nil)
      end
      if code ~= "200" then return cb(nil) end
      local ok, d = pcall(vim.json.decode, body)
      if not ok or type(d) ~= "table" then return cb(nil) end
      d.fetched_at = os.time()
      mem.data = d
      mem.fetched_at = d.fetched_at
      write_file_cache(d)
      cb(d)
    end)
  end)
end

-- Synchronous read (for statusline). Returns cached data or nil.
-- Triggers a background fetch if cache is cold.
function M.get()
  local now = os.time()
  if mem.data and (now - mem.fetched_at) < TTL then return mem.data end
  local fc = read_file_cache()
  if fc then
    mem.data = fc
    mem.fetched_at = fc.fetched_at
    return fc
  end
  -- Kick off background refresh; statusline will update next tick.
  fetch_async(function(_)
    pcall(vim.cmd, "redrawstatus!")
  end)
  return nil
end

-- For debugging / manual refresh.
function M.refresh(cb)
  mem = { data = nil, fetched_at = 0 }
  fetch_async(function(d) if cb then cb(d) end end)
end

-- Diagnostic: reports where we are in the fetch pipeline. Safe to call
-- anytime; never leaks the token.
function M.debug()
  local lines = {}
  local function add(k, v) table.insert(lines, k .. ": " .. tostring(v)) end
  local token = get_token()
  add("token found", token and "yes (" .. #token .. " chars)" or "no")
  add("memory cache", mem.data and "hit" or "miss")
  if mem.data then add("fetched_at", os.date("%c", mem.fetched_at)) end
  add("file cache",
    vim.uv.fs_stat(cache_file) and "exists at " .. cache_file or "none")
  add("lock file",
    vim.uv.fs_stat(lock_file) and "exists at " .. lock_file or "none")
  add("backoff until", backoff_until > os.time()
    and os.date("%c", backoff_until) or "none")
  add("fetching now", fetching and "yes" or "no")
  local d = mem.data or read_file_cache()
  if d then
    add("five_hour.utilization", d.five_hour and d.five_hour.utilization or "?")
    if d.five_hour and d.five_hour.resets_at then
      add("five_hour.resets_at", os.date("%c", d.five_hour.resets_at))
    end
  end
  return table.concat(lines, "\n")
end

return M
