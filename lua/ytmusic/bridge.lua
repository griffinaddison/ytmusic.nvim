local M = {}

local job_id = nil
local request_id = 0
local callbacks = {}
local buffer = ""

local function get_python()
  return vim.fn.expand("~/.local/share/ytmusic-nvim-venv/bin/python3")
end

local function get_bridge_script()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_dir = vim.fn.fnamemodify(source, ":h:h:h")
  return plugin_dir .. "/python/ytmusic_bridge.py"
end

function M.start()
  if job_id then
    return
  end

  local python = get_python()
  local script = get_bridge_script()

  if vim.fn.executable(python) ~= 1 then
    vim.notify("ytmusic.nvim: Python venv not found at " .. python, vim.log.levels.ERROR)
    return
  end

  job_id = vim.fn.jobstart({ python, script }, {
    stdout_buffered = false,
    on_stdout = function(_, data, _)
      -- Neovim splits on newlines: data is a list of line fragments.
      -- Adjacent newlines produce "" entries. The last element is always
      -- the partial fragment after the final newline (often "").
      for i, chunk in ipairs(data) do
        if i < #data then
          -- Every element except the last ends with a newline
          buffer = buffer .. chunk
          if buffer ~= "" then
            local ok, msg = pcall(vim.json.decode, buffer)
            if ok and msg then
              -- Startup auth check (id=0)
              if msg.id == 0 then
                if msg.error then
                  vim.schedule(function()
                    vim.notify("ytmusic.nvim: " .. tostring(msg.error), vim.log.levels.ERROR)
                  end)
                end
              else
                local cb = callbacks[msg.id]
                if cb then
                  callbacks[msg.id] = nil
                  if msg.error then
                    vim.schedule(function()
                      cb(nil)
                    end)
                  else
                    vim.schedule(function() cb(msg.result) end)
                  end
                end
              end
            end
          end
          buffer = ""
        else
          -- Last element: partial line, accumulate
          buffer = buffer .. chunk
        end
      end
    end,
    on_stderr = function(_, data, _)
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.schedule(function()
            vim.notify("ytmusic.nvim bridge: " .. line, vim.log.levels.WARN)
          end)
        end
      end
    end,
    on_exit = function()
      job_id = nil
    end,
  })
end

function M.request(method, params, callback)
  if not job_id then
    M.start()
  end
  if not job_id then
    vim.notify("ytmusic.nvim: Bridge not running", vim.log.levels.ERROR)
    return
  end

  request_id = request_id + 1
  local id = request_id
  callbacks[id] = callback

  local msg = vim.json.encode({ id = id, method = method, params = params or {} })
  vim.fn.chansend(job_id, msg .. "\n")
end

function M.stop()
  if job_id then
    vim.fn.jobstop(job_id)
    job_id = nil
  end
end

return M
