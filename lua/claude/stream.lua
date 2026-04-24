-- Parse `claude -p --output-format stream-json` NDJSON events into higher-level
-- events suitable for the renderer. Buffers partial lines across chunks and
-- assembles tool_use input_json_delta chunks per block index.

local M = {}

function M.new(handlers)
  local buf = ""
  local blocks = {} -- index → { type, name, id, json_str }

  local function emit(kind, data)
    local h = handlers[kind]
    if h then h(data) end
  end

  local function handle_obj(o)
    local t = o.type
    if t == "system" and o.subtype == "init" then
      emit("init", { session_id = o.session_id, cwd = o.cwd, model = o.model })
      return
    end

    -- Skip events emitted by Task subagents; their internal chatter shouldn't
    -- pollute the main transcript. The eventual subagent result still reaches
    -- us via tool_result on the parent.
    if o.parent_tool_use_id and o.parent_tool_use_id ~= vim.NIL then
      return
    end

    if t == "stream_event" and o.event then
      local ev = o.event
      local idx = ev.index
      if ev.type == "message_start" then
        emit("message_start", {
          usage = (ev.message or {}).usage,
          model = (ev.message or {}).model,
        })
      elseif ev.type == "content_block_start" then
        local cb = ev.content_block or {}
        blocks[idx] = { type = cb.type, name = cb.name, id = cb.id, json_str = "" }
        -- Nothing to emit yet; wait for deltas / stop.
      elseif ev.type == "content_block_delta" then
        local b = blocks[idx]
        local d = ev.delta or {}
        if not b then return end
        if b.type == "text" and d.type == "text_delta" then
          emit("text_delta", { text = d.text or "" })
        elseif b.type == "tool_use" and d.type == "input_json_delta" then
          b.json_str = b.json_str .. (d.partial_json or "")
        elseif b.type == "thinking" and d.type == "thinking_delta" then
          emit("thinking_delta", { text = d.thinking or "" })
        end
        -- signature_delta on thinking blocks is metadata (opaque); skip.
      elseif ev.type == "content_block_stop" then
        local b = blocks[idx]
        if b and b.type == "tool_use" then
          local ok, input = pcall(vim.json.decode, b.json_str)
          emit("tool_call", {
            name = b.name,
            id = b.id,
            input = ok and input or nil,
            raw_input = b.json_str,
          })
        end
        blocks[idx] = nil
      end
    elseif t == "user" and o.message then
      -- Tool results arrive as a user message containing tool_result blocks.
      local content = o.message.content
      if type(content) == "table" then
        for _, c in ipairs(content) do
          if type(c) == "table" and c.type == "tool_result" then
            local text = c.content
            if type(text) == "table" then
              local parts = {}
              for _, p in ipairs(text) do
                if type(p) == "table" and p.type == "text" and p.text then
                  table.insert(parts, p.text)
                end
              end
              text = table.concat(parts, "\n")
            end
            emit("tool_result", {
              tool_use_id = c.tool_use_id,
              text = text,
              is_error = c.is_error and true or false,
            })
          end
        end
      end
    elseif t == "assistant" then
      -- cumulative snapshot; we rely on deltas instead
    elseif t == "result" then
      emit("result", {
        is_error = o.is_error,
        cost_usd = o.total_cost_usd,
        duration_ms = o.duration_ms,
        errors = o.errors,
        stop_reason = o.stop_reason,
        model_usage = o.modelUsage,
        usage = o.usage,
        permission_denials = o.permission_denials,
      })
    elseif t == "system" and o.subtype == "error" then
      emit("error", { text = o.message or o.error or vim.inspect(o) })
    end
  end

  local function feed(chunk)
    buf = buf .. chunk
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then break end
      local line = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      if line ~= "" then
        local ok, obj = pcall(vim.json.decode, line)
        if ok and type(obj) == "table" then handle_obj(obj) end
      end
    end
  end

  local function flush()
    if buf ~= "" then
      local ok, obj = pcall(vim.json.decode, buf)
      if ok and type(obj) == "table" then handle_obj(obj) end
      buf = ""
    end
  end

  return { feed = feed, flush = flush }
end

return M
