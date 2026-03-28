#!/usr/bin/env python3
"""Thin bridge between Neovim (Lua) and ytmusicapi. Communicates via JSON over stdin/stdout."""

import json
import sys
import os
import time

# Simple response cache: {cache_key: (timestamp, result)}
_cache = {}
CACHE_TTL = 5  # seconds

def cache_get(key):
    if key in _cache:
        ts, result = _cache[key]
        if time.time() - ts < CACHE_TTL:
            return result
        del _cache[key]
    return None

def cache_set(key, result):
    _cache[key] = (time.time(), result)

def respond(req_id, data):
    msg = json.dumps({"id": req_id, "result": data})
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()

def respond_error(req_id, error):
    msg = json.dumps({"id": req_id, "error": str(error)})
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()

def main():
    from ytmusicapi import YTMusic

    config_dir = os.path.expanduser("~/.config/ytmusic.nvim")
    browser_path = os.path.join(config_dir, "browser.json")

    if os.path.exists(browser_path):
        yt = YTMusic(browser_path)
    else:
        yt = YTMusic()

    # Signal ready immediately, check auth lazily on first library request
    respond(0, "AUTH_OK")

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue

        req_id = req.get("id", 0)
        method = req.get("method", "")
        params = req.get("params", {})

        # Check cache for read-only methods
        cache_key = json.dumps({"method": method, "params": params}, sort_keys=True)
        if method not in ("add_playlist_items", "remove_playlist_items", "ping"):
            cached = cache_get(cache_key)
            if cached is not None:
                respond(req_id, cached)
                continue

        try:
            if method == "search":
                results = yt.search(params.get("query", ""), filter=params.get("filter", "songs"))
                tracks = []
                for r in results:
                    if r.get("resultType") == "song":
                        artists = ", ".join(a["name"] for a in r.get("artists", []) if "name" in a)
                        tracks.append({
                            "videoId": r.get("videoId", ""),
                            "title": r.get("title", ""),
                            "artist": artists,
                            "album": (r.get("album") or {}).get("name", ""),
                            "duration": r.get("duration", ""),
                        })
                cache_set(cache_key, tracks)
                respond(req_id, tracks)

            elif method == "get_home":
                home = yt.get_home(limit=6)
                sections = []
                for section in home:
                    title = section.get("title", "")
                    items = []
                    for item in section.get("contents", []):
                        entry = {
                            "title": item.get("title") or "",
                            "playlistId": item.get("playlistId") or "",
                            "videoId": item.get("videoId") or "",
                            "description": item.get("description") or "",
                        }
                        artists = item.get("artists", [])
                        if artists:
                            entry["artist"] = ", ".join(a.get("name", "") for a in artists if "name" in a)
                        items.append(entry)
                    sections.append({"title": title, "items": items})
                cache_set(cache_key, sections)
                respond(req_id, sections)

            elif method == "get_library_playlists":
                playlists = yt.get_library_playlists(limit=50)
                result = []
                for p in playlists:
                    result.append({
                        "playlistId": p.get("playlistId", ""),
                        "title": p.get("title", ""),
                        "count": p.get("count") or 0,
                    })
                cache_set(cache_key, result)
                respond(req_id, result)

            elif method == "get_liked_songs":
                liked = yt.get_liked_songs(limit=params.get("limit", 100))
                tracks = []
                for t in liked.get("tracks", []):
                    artists = ", ".join(a["name"] for a in t.get("artists", []) if "name" in a)
                    tracks.append({
                        "videoId": t.get("videoId", ""),
                        "title": t.get("title", ""),
                        "artist": artists,
                        "album": (t.get("album") or {}).get("name", ""),
                        "duration": t.get("duration", ""),
                        "setVideoId": t.get("setVideoId", ""),
                    })
                cache_set(cache_key, tracks)
                respond(req_id, tracks)

            elif method == "get_playlist":
                playlist = yt.get_playlist(params["playlistId"], limit=params.get("limit", 200))
                tracks = []
                for t in playlist.get("tracks", []):
                    artists = ", ".join(a["name"] for a in t.get("artists", []) if "name" in a)
                    tracks.append({
                        "videoId": t.get("videoId", ""),
                        "title": t.get("title", ""),
                        "artist": artists,
                        "album": (t.get("album") or {}).get("name", ""),
                        "duration": t.get("duration", ""),
                        "setVideoId": t.get("setVideoId", ""),
                    })
                result = {"title": playlist.get("title", ""), "tracks": tracks}
                cache_set(cache_key, result)
                respond(req_id, result)

            elif method == "get_account_name":
                try:
                    result = yt._send_request("account/account_menu", {})
                    actions = result.get("actions", [])
                    name = ""
                    for a in actions:
                        popup = a.get("openPopupAction", {}).get("popup", {}).get("multiPageMenuRenderer", {})
                        header = popup.get("header", {}).get("activeAccountHeaderRenderer", {})
                        if header:
                            runs = header.get("channelHandle", {}).get("runs", [])
                            if runs:
                                name = runs[0].get("text", "")
                    respond(req_id, name)
                except Exception:
                    respond(req_id, "")

            elif method == "add_playlist_items":
                result = yt.add_playlist_items(
                    params["playlistId"],
                    [params["videoId"]],
                )
                respond(req_id, result)

            elif method == "remove_playlist_items":
                result = yt.remove_playlist_items(
                    params["playlistId"],
                    [{"videoId": params["videoId"], "setVideoId": params["setVideoId"]}],
                )
                respond(req_id, result)

            elif method == "ping":
                respond(req_id, "pong")

            else:
                respond_error(req_id, f"Unknown method: {method}")

        except Exception as e:
            respond_error(req_id, e)


if __name__ == "__main__":
    main()
