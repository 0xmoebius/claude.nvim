-- AskUserQuestion UI, driven cross-process by bin/claude-nvim-auth.
--
-- Cannot run the picker inline inside `nvim --remote-expr`: that call
-- blocks on the main thread and doesn't pump TUI keyboard input into the
-- picker, so the user can never actually answer (and on some terminals
-- the whole UI freezes). Instead:
--
--   1. The hook script creates a temp answer-file seeded with an
--      "<IN-FLIGHT>" sentinel, then calls
--      questions.start(answer_path, input_json) which returns immediately.
--   2. start() schedules the picker on the event loop, runs the questions
--      in sequence, and writes the final answer string to answer_path.
--   3. The hook script polls answer_path until the sentinel is replaced
--      or the timeout expires, then forwards the text back to the CLI.

local M = {}

local function write_answer(path, text)
  local f = io.open(path, "w")
  if not f then return end
  f:write(text)
  f:close()
end

local float_picker = require("claude.float_picker")

local function format_picks(picks, multi)
  if #picks == 0 then
    return "(user dismissed; proceed with your best judgement)"
  end
  local parts = {}
  for _, p in ipairs(picks) do
    local s = p.label or "?"
    if p.description and p.description ~= "" then
      s = s .. " — " .. p.description
    end
    table.insert(parts, s)
  end
  return table.concat(parts, multi and " | " or "; ")
end

-- Run questions sequentially; write combined answer text to answer_path.
local function run_questions(answer_path, questions)
  local answers = {}
  local i = 1

  local function finish()
    local out = {}
    for idx, q in ipairs(questions) do
      table.insert(out, string.format("Q%d (%s): %s\nA%d: %s",
        idx, q.header or "", q.question or "?", idx, answers[idx] or "(no answer)"))
    end
    write_answer(answer_path, table.concat(out, "\n\n"))
  end

  local function ask_next()
    if i > #questions then return finish() end
    local q = questions[i]
    local header = q.header or "Question"
    local qtext = q.question or "?"
    local multi = q.multiSelect and true or false

    float_picker.open(header, qtext, q.options or {}, multi, function(picks)
      answers[i] = format_picks(picks, multi)
      i = i + 1
      -- Re-enter via schedule so the closing window's cleanup completes
      -- before we open the next one.
      vim.schedule(ask_next)
    end)
  end

  ask_next()
end

-- Entry point from the hook script. Returns the empty string immediately;
-- the answer is written to `answer_path` asynchronously by the picker
-- callbacks. The hook script polls the file.
function M.start(answer_path, input_json)
  local ok, input = pcall(vim.json.decode, input_json)
  if not ok or type(input) ~= "table" then
    write_answer(answer_path, "[claude.nvim: could not parse AskUserQuestion payload]")
    return ""
  end
  local questions = input.questions or {}
  if #questions == 0 then
    write_answer(answer_path, "[claude.nvim: no questions in payload]")
    return ""
  end

  vim.schedule(function()
    local ok_run, err = pcall(run_questions, answer_path, questions)
    if not ok_run then
      write_answer(answer_path, "[claude.nvim: picker error] " .. tostring(err))
    end
  end)
  return ""
end

return M
