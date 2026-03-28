local M = {}

function M.setup(opts)
  opts = opts or {}

  -- Global playback keymaps
  local leader = opts.leader or "<leader>"

  vim.keymap.set("n", leader .. "mp", function()
    require("ytmusic.mpv").play_pause()
  end, { desc = "YTMusic: Play/Pause" })

  vim.keymap.set("n", leader .. "mn", function()
    require("ytmusic.mpv").next_track()
  end, { desc = "YTMusic: Next track" })

  vim.keymap.set("n", leader .. "mN", function()
    require("ytmusic.mpv").prev_track()
  end, { desc = "YTMusic: Previous track" })

  vim.keymap.set("n", leader .. "mq", function()
    require("ytmusic.mpv").stop()
  end, { desc = "YTMusic: Stop playback" })

  -- Start the bridge
  require("ytmusic.bridge").start()

  -- Reconnect to existing mpv session if running
  require("ytmusic.mpv").reconnect()
end

function M.open()
  require("ytmusic.buffer").open_library()
end

function M.search(query)
  require("ytmusic.buffer").open_search(query)
end

return M
