local M = {}

local function format_time(seconds)
  if not seconds or seconds <= 0 then return "0:00" end
  seconds = math.floor(seconds)
  local m = math.floor(seconds / 60)
  local s = seconds % 60
  return string.format("%d:%02d", m, s)
end

function M.now_playing()
  local info = vim.g.ytmusic_now_playing
  if not info or not info.title or info.title == "" then
    return ""
  end

  local icon = info.paused and "⏸ " or "▶ "
  local time = ""
  if info.duration and info.duration > 0 then
    time = " " .. format_time(info.position) .. "/" .. format_time(info.duration)
  end

  return icon .. info.title .. time
end

return M
