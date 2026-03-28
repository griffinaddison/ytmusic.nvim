local bridge = require("ytmusic.bridge")
local mpv = require("ytmusic.mpv")

local M = {}

-- State
local nav_stack = {} -- stack of {type, data} for - navigation
local buf_tracks = {} -- tracks in current buffer, indexed by line
local buf_type = nil -- "library", "playlist", "search", "queue"
local buf_meta = {} -- extra info (playlistId, etc.)
local queue = {} -- current play queue
local yank_register = {} -- yanked tracks

local ns = vim.api.nvim_create_namespace("ytmusic")

local function format_track(track)
  local parts = {}
  table.insert(parts, track.title or "Unknown")
  if track.artist and track.artist ~= "" then
    table.insert(parts, "  " .. track.artist)
  end
  if track.duration and track.duration ~= "" then
    table.insert(parts, "  [" .. track.duration .. "]")
  end
  return table.concat(parts)
end

local buf_counter = 0
local function set_buf_options(buf)
  buf_counter = buf_counter + 1
  vim.api.nvim_buf_set_name(buf, "ytmusic://" .. buf_counter)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "ytmusic"
  vim.bo[buf].modifiable = false
end

local function render(buf, lines, highlights)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  if highlights then
    for _, hl in ipairs(highlights) do
      vim.api.nvim_buf_add_highlight(buf, ns, hl.group, hl.line, hl.col_start, hl.col_end)
    end
  end
end

local function get_or_create_buf()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].filetype ~= "ytmusic" then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
  end
  return buf
end

-- Set keymaps for a ytmusic buffer
local function set_keymaps(buf)
  local opts = { buffer = buf, silent = true, nowait = true }

  -- Enter: open item or play track
  vim.keymap.set("n", "<CR>", function() M.action_enter() end, opts)

  -- -: go back
  vim.keymap.set("n", "-", function() M.action_back() end, opts)

  -- dd: remove track
  vim.keymap.set("n", "dd", function() M.action_delete() end, opts)

  -- yy: yank track
  vim.keymap.set("n", "yy", function() M.action_yank() end, opts)

  -- p: paste/add yanked track
  vim.keymap.set("n", "p", function() M.action_paste() end, opts)

  -- a: add track to queue (without replacing)
  vim.keymap.set("n", "a", function() M.action_add_to_queue() end, opts)

  -- :w override for syncing
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      M.action_sync()
    end,
  })
end

-- Render the library root
function M.open_library()
  local buf = get_or_create_buf()
  set_buf_options(buf)
  set_keymaps(buf)

  buf_type = "library"
  buf_tracks = {}
  buf_meta = {
    items = {
      [2] = { type = "liked_songs" },
      [3] = { type = "queue" },
    },
  }
  nav_stack = {}

  -- Start with static items, then load playlists
  local lines = {
    "  YouTube Music",
    "",
    "  Liked Songs",
    "  Queue",
    "",
    "  Playlists",
    "  ─────────────────────",
    "",
    "  Loading playlists...",
  }
  render(buf, lines)

  bridge.request("get_library_playlists", {}, function(playlists)
    local new_lines = {
      "  YouTube Music",
      "",
      "  Liked Songs",
      "  Queue",
      "",
      "  Playlists",
      "  ─────────────────────",
    }

    buf_meta.items = {}
    -- Line indices (0-indexed): 2=Liked, 3=Queue
    buf_meta.items[2] = { type = "liked_songs" }
    buf_meta.items[3] = { type = "queue" }

    if playlists and #playlists > 0 then
      for _, p in ipairs(playlists) do
        local line = string.format("  %s  (%d)", p.title, p.count)
        table.insert(new_lines, line)
        buf_meta.items[#new_lines - 1] = {
          type = "playlist",
          playlistId = p.playlistId,
          title = p.title,
        }
      end
    else
      table.insert(new_lines, "  (no playlists found)")
    end

    render(buf, new_lines)
  end)
end

-- Render a playlist's tracks
function M.open_playlist(playlist_id, title)
  local buf = get_or_create_buf()
  set_buf_options(buf)
  set_keymaps(buf)

  table.insert(nav_stack, { type = buf_type, meta = vim.deepcopy(buf_meta) })
  buf_type = "playlist"
  buf_tracks = {}
  buf_meta = { playlistId = playlist_id, title = title }

  render(buf, { "  Loading " .. (title or "playlist") .. "..." })

  bridge.request("get_playlist", { playlistId = playlist_id }, function(result)
    if not result then return end
    local lines = {
      "  " .. (result.title or title or "Playlist"),
      "  ─────────────────────",
    }
    buf_tracks = {}
    for _, track in ipairs(result.tracks or {}) do
      table.insert(lines, "  " .. format_track(track))
      buf_tracks[#lines - 1] = track
    end
    if #result.tracks == 0 then
      table.insert(lines, "  (empty)")
    end
    render(buf, lines)
  end)
end

-- Render liked songs
function M.open_liked_songs()
  local buf = get_or_create_buf()
  set_buf_options(buf)
  set_keymaps(buf)

  table.insert(nav_stack, { type = buf_type, meta = vim.deepcopy(buf_meta) })
  buf_type = "liked"
  buf_tracks = {}
  buf_meta = {}

  render(buf, { "  Loading Liked Songs..." })

  bridge.request("get_liked_songs", { limit = 100 }, function(tracks)
    if not tracks then return end
    local lines = {
      "  Liked Songs",
      "  ─────────────────────",
    }
    buf_tracks = {}
    for _, track in ipairs(tracks) do
      table.insert(lines, "  " .. format_track(track))
      buf_tracks[#lines - 1] = track
    end
    render(buf, lines)
  end)
end

-- Render queue
function M.open_queue()
  local buf = get_or_create_buf()
  set_buf_options(buf)
  set_keymaps(buf)

  table.insert(nav_stack, { type = buf_type, meta = vim.deepcopy(buf_meta) })
  buf_type = "queue"
  buf_tracks = {}
  buf_meta = {}

  local lines = {
    "  Queue",
    "  ─────────────────────",
  }
  for _, track in ipairs(queue) do
    table.insert(lines, "  " .. format_track(track))
    buf_tracks[#lines - 1] = track
  end
  if #queue == 0 then
    table.insert(lines, "  (empty — play or add tracks)")
  end
  render(buf, lines)
end

-- Render search results
function M.open_search(query)
  local buf = get_or_create_buf()
  set_buf_options(buf)
  set_keymaps(buf)

  if buf_type then
    table.insert(nav_stack, { type = buf_type, meta = vim.deepcopy(buf_meta) })
  end
  buf_type = "search"
  buf_tracks = {}
  buf_meta = { query = query }

  render(buf, { "  Searching: " .. query .. "..." })

  bridge.request("search", { query = query, filter = "songs" }, function(tracks)
    if not tracks then return end
    local lines = {
      "  Search: " .. query,
      "  ─────────────────────",
    }
    buf_tracks = {}
    for _, track in ipairs(tracks) do
      table.insert(lines, "  " .. format_track(track))
      buf_tracks[#lines - 1] = track
    end
    if #tracks == 0 then
      table.insert(lines, "  No results")
    end
    render(buf, lines)
  end)
end

-- Actions

function M.action_enter()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed

  if buf_type == "library" then
    local item = buf_meta.items and buf_meta.items[line]
    if not item then return end
    if item.type == "liked_songs" then
      M.open_liked_songs()
    elseif item.type == "queue" then
      M.open_queue()
    elseif item.type == "playlist" then
      M.open_playlist(item.playlistId, item.title)
    end
  else
    -- Play track
    local track = buf_tracks[line]
    if track and track.videoId and track.videoId ~= "" then
      mpv.play(track.videoId)
      -- Set this track as current and queue remaining tracks
      queue = {}
      table.insert(queue, track)
      -- Add subsequent tracks to queue
      for i = line + 1, vim.api.nvim_buf_line_count(0) - 1 do
        if buf_tracks[i] then
          table.insert(queue, buf_tracks[i])
          mpv.queue_track(buf_tracks[i].videoId)
        end
      end
      vim.notify("Playing: " .. (track.title or ""), vim.log.levels.INFO)
    end
  end
end

function M.action_back()
  if #nav_stack == 0 then return end
  local prev = table.remove(nav_stack)

  -- Restore previous view
  if prev.type == "library" or prev.type == nil then
    nav_stack = {} -- reset stack since we're going to library
    M.open_library()
  end
  -- For other types we'd need to store more state — for MVP just go to library
  if prev.type ~= "library" then
    nav_stack = {}
    M.open_library()
  end
end

function M.action_delete()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local track = buf_tracks[line]
  if not track then return end

  if buf_type == "queue" then
    -- Remove from queue
    for i, t in ipairs(queue) do
      if t.videoId == track.videoId then
        table.remove(queue, i)
        break
      end
    end
    -- Re-render
    M.open_queue()
    nav_stack[#nav_stack] = nil -- don't double-push
  end
  -- For playlists, mark as pending delete (applied on :w)
  if buf_type == "playlist" then
    buf_meta.pending_deletes = buf_meta.pending_deletes or {}
    table.insert(buf_meta.pending_deletes, track)
    -- Re-index: shift all tracks above the deleted line down by one
    local new_tracks = {}
    for idx, t in pairs(buf_tracks) do
      if idx < line then
        new_tracks[idx] = t
      elseif idx > line then
        new_tracks[idx - 1] = t
      end
    end
    buf_tracks = new_tracks
    -- Remove line visually
    vim.bo[vim.api.nvim_get_current_buf()].modifiable = true
    vim.api.nvim_buf_set_lines(0, line, line + 1, false, {})
    vim.bo[vim.api.nvim_get_current_buf()].modifiable = false
    vim.notify("Marked for removal (save with :w)", vim.log.levels.INFO)
  end
end

function M.action_yank()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local track = buf_tracks[line]
  if track then
    yank_register = { track }
    vim.notify("Yanked: " .. (track.title or ""), vim.log.levels.INFO)
  end
end

function M.action_paste()
  if #yank_register == 0 then
    vim.notify("Nothing yanked", vim.log.levels.WARN)
    return
  end

  local track = yank_register[1]

  if buf_type == "queue" then
    table.insert(queue, track)
    mpv.queue_track(track.videoId)
    M.open_queue()
    nav_stack[#nav_stack] = nil
    vim.notify("Added to queue: " .. (track.title or ""), vim.log.levels.INFO)
  elseif buf_type == "playlist" and buf_meta.playlistId then
    buf_meta.pending_adds = buf_meta.pending_adds or {}
    table.insert(buf_meta.pending_adds, track)
    -- Show it in the buffer
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "  " .. format_track(track) .. "  [+new]" })
    vim.bo[buf].modifiable = false
    vim.notify("Marked for adding (save with :w)", vim.log.levels.INFO)
  end
end

function M.action_add_to_queue()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local track = buf_tracks[line]
  if track and track.videoId then
    table.insert(queue, track)
    mpv.queue_track(track.videoId)
    vim.notify("Queued: " .. (track.title or ""), vim.log.levels.INFO)
  end
end

function M.action_sync()
  if buf_type ~= "playlist" or not buf_meta.playlistId then
    vim.notify("Nothing to sync", vim.log.levels.INFO)
    return
  end

  local synced = false

  -- Process deletes
  if buf_meta.pending_deletes then
    for _, track in ipairs(buf_meta.pending_deletes) do
      if track.setVideoId then
        bridge.request("remove_playlist_items", {
          playlistId = buf_meta.playlistId,
          videoId = track.videoId,
          setVideoId = track.setVideoId,
        }, function(result)
          vim.notify("Removed: " .. (track.title or ""), vim.log.levels.INFO)
        end)
        synced = true
      end
    end
    buf_meta.pending_deletes = nil
  end

  -- Process adds
  if buf_meta.pending_adds then
    for _, track in ipairs(buf_meta.pending_adds) do
      bridge.request("add_playlist_items", {
        playlistId = buf_meta.playlistId,
        videoId = track.videoId,
      }, function(result)
        if result and type(result) == "table" and result.status == "STATUS_SUCCEEDED" then
          vim.notify("Added: " .. (track.title or ""), vim.log.levels.INFO)
        else
          vim.notify("Failed to add: " .. (track.title or ""), vim.log.levels.ERROR)
        end
      end)
      synced = true
    end
    buf_meta.pending_adds = nil
  end

  vim.bo[vim.api.nvim_get_current_buf()].modified = false
  if synced then
    vim.notify("Syncing to YouTube Music...", vim.log.levels.INFO)
  end
end

function M.get_queue()
  return queue
end

return M
