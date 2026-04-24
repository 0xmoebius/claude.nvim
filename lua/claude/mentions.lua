-- `@`-mention file completion for the prompt buffer. Wired via
-- `completefunc` + an insert-mode `@` mapping in prompt.setup_keymaps,
-- so typing `@` in the prompt pops the native completion menu with file
-- paths from the session's cwd. The resulting word in the buffer is
-- `@<path>`, which the Claude CLI treats as a file reference.
--
-- Candidate source:
--   1. `git ls-files` (tracked + untracked, honouring gitignore) when
--      the cwd is a git repo.
--   2. Fallback: a bounded `vim.fs.dir` walk (depth 4, cap 2000 entries)
--      so non-git directories still work.
--
-- Results are cached per-cwd for 5s — a single keystroke may re-enter
-- the completion function several times as the user filters, and we
-- don't want to shell out each time.

local M = {}

local CACHE_TTL_MS = 5000
local MAX_FS_WALK = 2000
local cache = {} -- cwd → { ts, files }

local function git_ls_files(cwd)
  local out = vim.fn.systemlist({
    "git", "-C", cwd, "ls-files",
    "--cached", "--others", "--exclude-standard",
  })
  if vim.v.shell_error ~= 0 then return nil end
  return out
end

local function fs_walk(cwd)
  local files = {}
  local ok, iter = pcall(vim.fs.dir, cwd, { depth = 4 })
  if not ok then return files end
  for name, ty in iter do
    if ty == "file" then
      files[#files + 1] = name
      if #files >= MAX_FS_WALK then break end
    end
  end
  return files
end

local function list_files(cwd)
  local entry = cache[cwd]
  local now = vim.uv.now()
  if entry and (now - entry.ts) < CACHE_TTL_MS then
    return entry.files
  end
  local files = git_ls_files(cwd) or fs_walk(cwd)
  cache[cwd] = { ts = now, files = files }
  return files
end

-- `completefunc` contract: called twice per completion.
--   findstart == 1 → return the byte-column (0-indexed) where the
--                     matched text begins, or -2 to abort quietly.
--   findstart == 0 → return the candidate list matching `base`.
function M.complete(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col(".") - 1 -- 0-indexed cursor byte position
    -- Walk backwards to find the most recent `@`. Stop if we hit
    -- whitespace first (the `@` must be the start of the token).
    local i = col
    while i > 0 do
      local ch = line:sub(i, i)
      if ch == "@" then
        -- Require `@` to be at BOL or preceded by whitespace, so we
        -- don't hijack completion in mid-word contexts like email
        -- addresses.
        if i == 1 or line:sub(i - 1, i - 1):match("%s") then
          return i - 1
        end
        return -2
      end
      if ch:match("%s") then return -2 end
      i = i - 1
    end
    return -2
  end

  -- `base` starts with the `@` since we returned its column above.
  local prefix = (base or ""):sub(2):lower()
  local cwd = vim.fn.getcwd()
  local files = list_files(cwd)
  local items = {}
  for _, f in ipairs(files) do
    if prefix == "" or f:lower():find(prefix, 1, true) then
      items[#items + 1] = {
        word = "@" .. f,
        abbr = f,
        kind = "f",
        icase = 1,
      }
      if #items >= 200 then break end
    end
  end
  return items
end

return M
