local M = {}

local socket_path = "/tmp/ytmusic-mpv.sock"
local mpv_pid = nil
local queue = {}
local current_index = 0
local poll_timer = nil
local current_track = nil -- {title, artist, videoId}

local function send_command(...)
  local args = { ... }
  local cmd = vim.json.encode({ command = args })
  -- Use socat to send to mpv's IPC socket
  vim.fn.system(string.format('echo \'%s\' | socat - UNIX-CONNECT:%s 2>/dev/null', cmd, socket_path))
end

local function send_command_async(args, callback)
  local cmd = vim.json.encode({ command = args })
  local escaped = cmd:gsub("'", "'\\''")
  vim.fn.jobstart(
    string.format("echo '%s' | socat - UNIX-CONNECT:%s 2>/dev/null", escaped, socket_path),
    {
      on_stdout = function(_, data)
        if callback then
          local line = table.concat(data, "")
          if line ~= "" then
            local ok, result = pcall(vim.json.decode, line)
            if ok then
              callback(result)
            end
          end
        end
      end,
    }
  )
end

local function ensure_mpv()
  -- Check if mpv is already running with our socket
  local check = vim.fn.system("test -S " .. socket_path .. " && echo yes || echo no")
  if check:match("yes") then
    return true
  end

  -- Kill any stale mpv
  if mpv_pid then
    vim.fn.system("kill " .. mpv_pid .. " 2>/dev/null")
  end

  -- Start mpv in idle mode
  vim.fn.jobstart({
    "mpv", "--idle", "--no-video",
    "--input-ipc-server=" .. socket_path,
    "--msg-level=all=warn",
  }, {
    detach = true,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.schedule(function()
            vim.notify("ytmusic.nvim [mpv]: " .. line, vim.log.levels.WARN)
          end)
        end
      end
    end,
  })

  -- Wait briefly for socket
  vim.wait(500, function()
    return vim.fn.system("test -S " .. socket_path .. " && echo yes || echo no"):match("yes") ~= nil
  end, 50)

  return vim.fn.system("test -S " .. socket_path .. " && echo yes || echo no"):match("yes") ~= nil
end

function M.play(video_id, track_info)
  if not ensure_mpv() then
    vim.notify("ytmusic.nvim: Failed to start mpv", vim.log.levels.ERROR)
    return
  end
  current_track = track_info
  local url = "https://music.youtube.com/watch?v=" .. video_id
  send_command("loadfile", url, "replace")
  send_command("set_property", "pause", false)
  M.start_polling()

  -- Check if stream actually loaded after a delay
  vim.defer_fn(function()
    send_command_async({ "get_property", "time-pos" }, function(result)
      if result and result.error and result.error ~= "success" then
        vim.schedule(function()
          vim.notify("ytmusic.nvim: Stream failed to load — yt-dlp may be broken (try: yt-dlp --no-download '" .. url .. "')", vim.log.levels.ERROR)
        end)
      end
    end)
  end, 5000)
end

function M.queue_track(video_id)
  if not ensure_mpv() then return end
  local url = "https://music.youtube.com/watch?v=" .. video_id
  send_command("loadfile", url, "append-play")
end

function M.play_pause()
  if not ensure_mpv() then return end
  send_command("cycle", "pause")
end

function M.next_track()
  if not ensure_mpv() then return end
  send_command("playlist-next")
end

function M.prev_track()
  if not ensure_mpv() then return end
  send_command("playlist-prev")
end

function M.stop()
  send_command("quit")
  if mpv_pid then
    vim.fn.system("kill " .. mpv_pid .. " 2>/dev/null")
    mpv_pid = nil
  end
  vim.fn.system("rm -f " .. socket_path)
  M.stop_polling()
end

function M.get_now_playing(callback)
  send_command_async({ "get_property", "media-title" }, function(title_result)
    send_command_async({ "get_property", "time-pos" }, function(pos_result)
      send_command_async({ "get_property", "duration" }, function(dur_result)
        send_command_async({ "get_property", "pause" }, function(pause_result)
          local title = current_track and current_track.title or (title_result and title_result.data or "")
          local artist = current_track and current_track.artist or ""
          callback({
            title = title,
            artist = artist,
            position = pos_result and pos_result.data or 0,
            duration = dur_result and dur_result.data or 0,
            paused = pause_result and pause_result.data or false,
          })
        end)
      end)
    end)
  end)
end

function M.start_polling()
  M.stop_polling()
  poll_timer = vim.uv.new_timer()
  poll_timer:start(1000, 1000, vim.schedule_wrap(function()
    M.get_now_playing(function(info)
      vim.g.ytmusic_now_playing = info
      vim.cmd("redrawstatus")
    end)
  end))
end

function M.stop_polling()
  if poll_timer then
    poll_timer:stop()
    poll_timer:close()
    poll_timer = nil
  end
end

function M.reconnect()
  local check = vim.fn.system("test -S " .. socket_path .. " && echo yes || echo no")
  if check:match("yes") then
    M.start_polling()
  end
end

return M
