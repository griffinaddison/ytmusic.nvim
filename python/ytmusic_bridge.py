#!/usr/bin/env python3
"""Thin bridge between Neovim (Lua) and ytmusicapi. Communicates via JSON over stdin/stdout."""

import json
import sys
import os

def main():
    from ytmusicapi import YTMusic

    auth_type = os.environ.get("YTMUSIC_AUTH", "oauth")
    auth_file = os.environ.get("YTMUSIC_AUTH_FILE", "")

    if auth_type == "browser" and auth_file:
        yt = YTMusic(auth_file)
    elif auth_type == "oauth" and auth_file:
        yt = YTMusic(auth_file)
    else:
        # Try common locations
        config_dir = os.path.expanduser("~/.config/ytmusic.nvim")
        oauth_path = os.path.join(config_dir, "oauth.json")
        browser_path = os.path.join(config_dir, "browser.json")
        if os.path.exists(oauth_path):
            yt = YTMusic(oauth_path)
        elif os.path.exists(browser_path):
            yt = YTMusic(browser_path)
        else:
            # Unauthenticated — search works, library doesn't
            yt = YTMusic()

    def respond(req_id, data):
        msg = json.dumps({"id": req_id, "result": data})
        sys.stdout.write(msg + "\n")
        sys.stdout.flush()

    def respond_error(req_id, error):
        msg = json.dumps({"id": req_id, "error": str(error)})
        sys.stdout.write(msg + "\n")
        sys.stdout.flush()

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
                respond(req_id, tracks)

            elif method == "get_library_playlists":
                playlists = yt.get_library_playlists(limit=50)
                result = []
                for p in playlists:
                    result.append({
                        "playlistId": p.get("playlistId", ""),
                        "title": p.get("title", ""),
                        "count": p.get("count") or 0,
                    })
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
                respond(req_id, {"title": playlist.get("title", ""), "tracks": tracks})

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
