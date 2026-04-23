local M = {}

local cache = {}
local TTL = 5 -- seconds

function M.branch(cwd)
  if not cwd or cwd == "" then return nil end
  local now = os.time()
  local hit = cache[cwd]
  if hit and (now - hit.at) < TTL then return hit.branch end

  local ok, result = pcall(function()
    return vim.system({ "git", "-C", cwd, "branch", "--show-current" },
      { text = true, timeout = 500 }):wait()
  end)
  local branch
  if ok and result and result.code == 0 then
    branch = (result.stdout or ""):gsub("%s+$", "")
    if branch == "" then branch = nil end
  end
  cache[cwd] = { branch = branch, at = now }
  return branch
end

return M
