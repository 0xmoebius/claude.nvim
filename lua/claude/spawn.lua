-- Spawn `claude -p` per turn. Uses vim.system (nvim 0.10+).

local config = require("claude.config")
local stream = require("claude.stream")

local M = {}

-- Return the absolute path to the claude.nvim plugin root.
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return src:match("(.*)/lua/claude/") or vim.fn.fnamemodify(src, ":p:h:h:h")
end

-- Build a PreToolUse hook settings JSON that points at our auth script.
-- `include_permissions` adds matchers for each permission_tools entry;
-- without it, only AskUserQuestion is intercepted (for the in-nvim picker).
local function build_hook_settings(include_permissions)
  local auth_script = plugin_root() .. "/bin/claude-nvim-auth"
  local hooks_entries = {}
  local seen = {}
  local function add(tool)
    if seen[tool] then return end
    seen[tool] = true
    table.insert(hooks_entries, {
      matcher = tool,
      hooks = { { type = "command", command = auth_script } },
    })
  end
  -- Always intercept AskUserQuestion so skills that prompt the user work.
  add("AskUserQuestion")
  if include_permissions then
    for _, tool in ipairs(config.opts.permission_tools or {}) do
      add(tool)
    end
  end
  return { hooks = { PreToolUse = hooks_entries } }
end

-- Ensure nvim is listening on a socket so the auth hook can reach back in.
local function ensure_server_socket()
  local name = vim.v.servername
  if name and name ~= "" then return name end
  local ok, created = pcall(vim.fn.serverstart)
  if ok and created and created ~= "" then return created end
  return nil
end

local function build_args(opts)
  local argv = { config.opts.claude_bin, "-p",
    "--output-format", "stream-json",
    "--verbose",
    "--include-partial-messages",
  }
  if config.opts.ask_permissions then
    -- With the PreToolUse hook supplying allow/deny, set default mode so
    -- the hook's decision is what actually gates tool use.
    table.insert(argv, "--permission-mode")
    table.insert(argv, "default")
  elseif config.opts.dangerously_skip_permissions then
    table.insert(argv, "--dangerously-skip-permissions")
  else
    table.insert(argv, "--permission-mode")
    table.insert(argv, opts.permission_mode or config.opts.permission_mode)
  end
  -- Always wire the AskUserQuestion hook so skills that prompt the user
  -- work in -p mode (where the CLI would otherwise short-circuit with an
  -- error). When ask_permissions is on, the same --settings blob also
  -- carries per-tool permission matchers.
  local settings = build_hook_settings(config.opts.ask_permissions)
  table.insert(argv, "--settings")
  table.insert(argv, vim.json.encode(settings))
  if opts.session_id then
    table.insert(argv, "--resume")
    table.insert(argv, opts.session_id)
  end
  local model = opts.model or config.opts.model
  if model and model ~= "" then
    table.insert(argv, "--model")
    table.insert(argv, model)
  end
  return argv
end

-- Send one turn.
function M.send(message, opts, handlers)
  opts = opts or {}
  local argv = build_args(opts)
  local parser = stream.new(handlers)

  -- The hook script needs a socket to reach back into this nvim (for
  -- both permission prompts and AskUserQuestion). Always wire it.
  local env
  local sock = ensure_server_socket()
  if not sock then
    vim.notify("claude.nvim: no nvim server socket; hooks cannot prompt user",
      vim.log.levels.WARN)
  else
    env = vim.tbl_extend("force", vim.fn.environ(), {
      CLAUDE_NVIM_SOCKET = sock,
    })
  end

  local handle
  handle = vim.system(argv, {
    stdin = message,
    text = true,
    cwd = opts.cwd,
    env = env,
    stdout = function(err, data)
      if err then
        vim.schedule(function()
          if handlers.error then handlers.error({ text = "stdout error: " .. tostring(err) }) end
        end)
        return
      end
      if data then
        vim.schedule(function() parser.feed(data) end)
      end
    end,
    stderr = function(err, data)
      if data and data ~= "" then
        vim.schedule(function()
          if handlers.stderr then handlers.stderr({ text = data }) end
        end)
      end
    end,
  }, function(result)
    vim.schedule(function()
      parser.flush()
      if handlers.exit then
        handlers.exit({ code = result.code, signal = result.signal })
      end
    end)
  end)
  return handle
end

return M
