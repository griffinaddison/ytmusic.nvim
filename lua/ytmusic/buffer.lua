local bridge = require("ytmusic.bridge")
local mpv = require("ytmusic.mpv")

local M = {}

-- State
local nav_stack = {} -- stack of {type, data} for - navigation
local buf_tracks = {} -- tracks in current buffer, indexed by line
local buf_type = nil -- "library", "playlist", "search", "queue"
local buf_meta = {} -- extra info (playlistId, etc.)
local queue = {} -- current play queue
local cached_account_name = ""
local yank_register = {} -- yanked tracks

local ns = vim.api.nvim_create_namespace("ytmusic")

local function format_track(track)
  local parts = {}
  table.insert(parts, track.title or "Unknown")
  if track.artist and track.artist ~= "" then
    table.insert(parts, " - " .. track.artist)
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
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
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

  -- gd: go to artist
  vim.keymap.set("n", "gd", function() M.action_go_to_artist() end, opts)

  -- g?: toggle help
  vim.keymap.set("n", "g?", function() M.toggle_help() end, opts)

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
  buf_meta = { items = {} }
  nav_stack = {}

  local function build_library()
    local new_lines = { "ytmusic.nvim" }
    if cached_account_name ~= "" then
      table.insert(new_lines, cached_account_name)
    end
    table.insert(new_lines, "")

    buf_meta.items = {}
    local sections = {
      { name = "queue", type = "queue" },
      { name = "liked songs", type = "liked_songs" },
      { name = "playlists", type = "playlists" },
      { name = "listen again", type = "listen_again" },
      { name = "mixed for you", type = "mixed_for_you" },
    }
    for _, s in ipairs(sections) do
      table.insert(new_lines, s.name)
      buf_meta.items[#new_lines - 1] = { type = s.type }
    end
    return new_lines
  end

  render(buf, build_library())

  if cached_account_name == "" then
    bridge.request("get_account_name", {}, function(name)
      if name and name ~= "" then
        cached_account_name = name
        local buf2 = vim.api.nvim_get_current_buf()
        if vim.bo[buf2].filetype == "ytmusic" then
          render(buf2, build_library())
        end
      end
    end)
  end
end

-- Open a section listing (playlists, listen again, mixed for you)
function M.open_section(section_type, title)
  local buf = get_or_create_buf()
  set_buf_options(buf)
  set_keymaps(buf)

  table.insert(nav_stack, { type = buf_type, meta = vim.deepcopy(buf_meta) })
  buf_type = "section"
  buf_tracks = {}
  buf_meta = { section_type = section_type }

  render(buf, { title, "", "loading..." })
  print("loading...")

  if section_type == "playlists" then
    bridge.request("get_library_playlists", {}, function(playlists)
      local new_lines = { title }
      buf_meta.items = {}
      if playlists then
        for _, p in ipairs(playlists) do
          table.insert(new_lines, p.title)
          buf_meta.items[#new_lines - 1] = {
            type = "playlist",
            playlistId = p.playlistId,
            title = p.title,
          }
        end
      end
      render(buf, new_lines)
      print("")
    end)
  elseif section_type == "liked_songs" then
    bridge.request("get_liked_songs", { limit = 100 }, function(tracks)
      local new_lines = { title }
      if not tracks then
        table.insert(new_lines, "(failed to load — try refreshing cookies)")
        render(buf, new_lines)
        return
      end
      buf_tracks = {}
      for _, track in ipairs(tracks) do
        table.insert(new_lines, format_track(track))
        buf_tracks[#new_lines - 1] = track
      end
      render(buf, new_lines)
      print("")
    end)
  elseif section_type == "listen_again" or section_type == "mixed_for_you" then
    local match_title = section_type == "listen_again" and "listen again" or "mixed for you"
    bridge.request("get_home", {}, function(sections)
      local new_lines = { title }
      buf_meta.items = {}
      if sections then
        for _, s in ipairs(sections) do
          if s.title:lower():match(match_title) then
            for _, item in ipairs(s.items) do
              local display = item.title
              if item.artist and item.artist ~= "" then
                display = display .. " - " .. item.artist
              end
              table.insert(new_lines, display)
              local idx = #new_lines - 1
              if item.type == "artist" and item.channelId and item.channelId ~= "" then
                buf_meta.items[idx] = {
                  type = "related_artist",
                  channelId = item.channelId,
                  name = item.title,
                }
              elseif item.playlistId and item.playlistId ~= "" and item.playlistId ~= vim.NIL then
                buf_meta.items[idx] = {
                  type = "playlist",
                  playlistId = item.playlistId,
                  title = item.title,
                }
              end
            end
            break
          end
        end
      end
      render(buf, new_lines)
      print("")
    end)
  end
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

  render(buf, { "  loading liked songs..." })

  bridge.request("get_liked_songs", { limit = 100 }, function(tracks)
    if not tracks then
      render(buf, { "  liked songs", "  (failed to load — try refreshing cookies)" })
      return
    end
    local lines = {
      "  liked songs",
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
    "  queue",
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
    if item then
      if item.type == "queue" then
        M.open_queue()
      elseif item.type == "playlists" then
        M.open_section("playlists", "playlists")
      elseif item.type == "liked_songs" then
        M.open_section("liked_songs", "liked songs")
      elseif item.type == "listen_again" then
        M.open_section("listen_again", "listen again")
      elseif item.type == "mixed_for_you" then
        M.open_section("mixed_for_you", "mixed for you")
      end
    end
    return
  elseif buf_type == "section" then
    local item = buf_meta.items and buf_meta.items[line]
    if item then
      if item.type == "playlist" then
        M.open_playlist(item.playlistId, item.title)
      elseif item.type == "related_artist" then
        M.open_artist(item.channelId, item.name)
      end
      return
    end
    -- Fall through to play track
  elseif buf_type == "artist" then
    local item = buf_meta.items and buf_meta.items[line]
    if item then
      if item.type == "playlist" then
        M.open_playlist(item.playlistId, item.title)
      elseif item.type == "related_artist" then
        M.open_artist(item.channelId, item.name)
      end
      return
    end
    -- Fall through to play track below
  end

  -- Play track (works for playlist, search, artist, queue views)
  do
    local track = buf_tracks[line]
    if track and track.videoId and track.videoId ~= "" then
      mpv.play(track.videoId, track)
      print("▶ " .. (track.title or ""))
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
    print("removed (save with :w)")
  end
end

function M.action_yank()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local track = buf_tracks[line]
  if track then
    yank_register = { track }
    print("yanked: " .. (track.title or ""))
  end
end

function M.action_paste()
  if #yank_register == 0 then
    print("nothing yanked")
    return
  end

  local track = yank_register[1]

  if buf_type == "queue" then
    table.insert(queue, track)
    mpv.queue_track(track.videoId)
    M.open_queue()
    nav_stack[#nav_stack] = nil
    print("queued: " .. (track.title or ""))
  elseif buf_type == "playlist" and buf_meta.playlistId then
    buf_meta.pending_adds = buf_meta.pending_adds or {}
    table.insert(buf_meta.pending_adds, track)
    -- Show it in the buffer
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "  " .. format_track(track) .. "  [+new]" })
    vim.bo[buf].modifiable = false
    print("added (save with :w)")
  end
end

function M.action_add_to_queue()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local track = buf_tracks[line]
  if track and track.videoId then
    table.insert(queue, track)
    mpv.queue_track(track.videoId)
    print("queued: " .. (track.title or ""))
  end
end

function M.action_go_to_artist()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local track = buf_tracks[line]
  if track and track.artistId and track.artistId ~= "" then
    M.open_artist(track.artistId, track.artist)
    return
  end
  -- Check if on a related artist line
  local item = buf_meta.items and buf_meta.items[line]
  if item and item.type == "related_artist" and item.channelId then
    M.open_artist(item.channelId, item.name)
    return
  end
  print("no artist on this line")
end

function M.open_artist(channel_id, name)
  local buf = get_or_create_buf()
  set_buf_options(buf)
  set_keymaps(buf)

  table.insert(nav_stack, { type = buf_type, meta = vim.deepcopy(buf_meta) })
  buf_type = "artist"
  buf_tracks = {}
  buf_meta = { channelId = channel_id, name = name }

  render(buf, { "loading " .. (name or "artist") .. "..." })
  print("loading " .. (name or "artist") .. "...")

  bridge.request("get_artist", { channelId = channel_id }, function(data)
    if not data then
      render(buf, { name or "artist", "  (failed to load)" })
      return
    end

    local new_lines = {}
    -- Header
    table.insert(new_lines, data.name or name or "")
    if data.subscribers and data.subscribers ~= "" then
      table.insert(new_lines, data.subscribers)
    end
    table.insert(new_lines, "")

    buf_meta.items = {}

    -- Top songs
    if data.topSongs and #data.topSongs > 0 then
      table.insert(new_lines, "top songs")
      for _, s in ipairs(data.topSongs) do
        local display = "  " .. s.title
        if s.artist and s.artist ~= "" then
          display = display .. " - " .. s.artist
        end
        table.insert(new_lines, display)
        buf_tracks[#new_lines - 1] = s
      end
      table.insert(new_lines, "")
    end

    -- Albums
    if data.albums and #data.albums > 0 then
      table.insert(new_lines, "albums")
      for _, a in ipairs(data.albums) do
        local display = "  " .. a.title
        if a.year and a.year ~= "" then
          display = display .. " (" .. a.year .. ")"
        end
        table.insert(new_lines, display)
        if a.playlistId and a.playlistId ~= "" then
          buf_meta.items[#new_lines - 1] = {
            type = "playlist",
            playlistId = a.playlistId,
            title = a.title,
          }
        end
      end
      table.insert(new_lines, "")
    end

    -- Singles
    if data.singles and #data.singles > 0 then
      table.insert(new_lines, "singles")
      for _, s in ipairs(data.singles) do
        local display = "  " .. s.title
        if s.year and s.year ~= "" then
          display = display .. " (" .. s.year .. ")"
        end
        table.insert(new_lines, display)
        if s.playlistId and s.playlistId ~= "" then
          buf_meta.items[#new_lines - 1] = {
            type = "playlist",
            playlistId = s.playlistId,
            title = s.title,
          }
        end
      end
      table.insert(new_lines, "")
    end

    -- Related artists
    if data.related and #data.related > 0 then
      table.insert(new_lines, "related artists")
      for _, r in ipairs(data.related) do
        local display = "  " .. r.name
        if r.subscribers and r.subscribers ~= "" then
          display = display .. " (" .. r.subscribers .. ")"
        end
        table.insert(new_lines, display)
        if r.channelId and r.channelId ~= "" then
          buf_meta.items[#new_lines - 1] = {
            type = "related_artist",
            channelId = r.channelId,
            name = r.name,
          }
        end
      end
    end

    render(buf, new_lines)
    vim.wo[0].foldlevel = 99
    print("")
  end)
end

function M.action_sync()
  if buf_type ~= "playlist" or not buf_meta.playlistId then
    print("no pending changes")
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
          print("removed: " .. (track.title or ""))
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
          print("added: " .. (track.title or ""))
        else
          print("failed to add: " .. (track.title or ""))
        end
      end)
      synced = true
    end
    buf_meta.pending_adds = nil
  end

  vim.bo[vim.api.nvim_get_current_buf()].modified = false
  if synced then
    print("syncing...")
  end
end

function M.get_queue()
  return queue
end

local help_win = nil
function M.toggle_help()
  if help_win and vim.api.nvim_win_is_valid(help_win) then
    vim.api.nvim_win_close(help_win, true)
    help_win = nil
    return
  end

  local lines = {
    " ytmusic.nvim",
    "",
    " Navigation",
    "   Enter   open playlist / play track",
    "   -       go back",
    "   gd      go to artist",
    "   g?      toggle this help",
    "",
    " Tracks",
    "   a       add to queue",
    "   dd      remove from queue/playlist",
    "   yy      yank track",
    "   p       paste yanked track",
    "   :w      sync changes to YouTube Music",
    "",
    " Playback",
    "   <leader>mp   play/pause",
    "   <leader>mn   next track",
    "   <leader>mN   previous track",
    "   <leader>mq   stop",
    "",
    " Commands",
    "   :YTMusic     open library",
    "   :YTSearch    search",
  }

  local width = 40
  local height = #lines
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  help_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    col = vim.o.columns - width - 2,
    row = 1,
    style = "minimal",
    border = "rounded",
  })
end

return M
