local M = {}

local cache = {}
-- 60-second TTL: the branch name rarely changes during a session, and a
-- keystroke-triggered statusline redraw that races into a cache-expiry
-- window would block on a synchronous `git` call for up to TIMEOUT_MS,
-- which reads as statusline flicker.
local TTL = 60
local TIMEOUT_MS = 1500

local function try(argv)
  local ok, r = pcall(function()
    return vim.system(argv, { text = true, timeout = TIMEOUT_MS }):wait()
  end)
  if ok and r and r.code == 0 and r.stdout then
    local s = r.stdout:gsub("%s+$", "")
    if s ~= "" then return s end
  end
  return nil
end

function M.branch(cwd)
  if not cwd or cwd == "" then return nil end
  local now = os.time()
  local hit = cache[cwd]
  if hit then
    -- Successful lookups cache 60s; misses only 5s so a transient failure
    -- (git not yet on PATH, path not yet tracked) resolves quickly.
    local ttl = hit.branch and TTL or 5
    if (now - hit.at) < ttl then return hit.branch end
  end

  local branch = try({ "git", "-C", cwd, "branch", "--show-current" })
  if not branch then
    branch = try({ "git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD" })
  end
  if branch == "HEAD" then branch = nil end
  cache[cwd] = { branch = branch, at = now }
  return branch
end

return M
