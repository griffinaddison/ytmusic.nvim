#!/usr/bin/env python3
"""Setup YouTube Music auth for ytmusic.nvim."""

import sys
import os
import json
import hashlib
import time

venv_site = os.path.expanduser("~/.local/share/ytmusic-nvim-venv/lib")
for d in os.listdir(venv_site):
    sp = os.path.join(venv_site, d, "site-packages")
    if os.path.isdir(sp):
        sys.path.insert(0, sp)

config_dir = os.path.expanduser("~/.config/ytmusic.nvim")
os.makedirs(config_dir, exist_ok=True)
filepath = os.path.join(config_dir, "browser.json")

cookie_file = os.path.join(config_dir, "cookie.txt")

print("How to get your cookie:")
print("  1. Open an INCOGNITO window (Cmd+Shift+N) — this prevents cookie rotation")
print("  2. Go to music.youtube.com and sign in")
print("  3. Open DevTools (Cmd+Option+I) > Network tab")
print("  4. Check 'Disable cache'")
print("  5. Hard refresh (Cmd+Shift+R)")
print("  6. Click the first 'music.youtube.com' request")
print("  7. Scroll to Request Headers > copy the Cookie value")
print(f"  8. Paste it into: {cookie_file}")
print()
print(f"Waiting for {cookie_file} ...")

if not os.path.exists(cookie_file):
    with open(cookie_file, "w") as f:
        f.write("")
    print(f"Created {cookie_file} — paste your cookie in there, save, then press Enter.")
    input()

cookie = open(cookie_file).read().strip()
if not cookie:
    print("Error: cookie.txt is empty. Paste your cookie in there and run again.")
    sys.exit(1)

# Extract SAPISID for authorization header
sapisid = None
for part in cookie.split(";"):
    part = part.strip()
    if part.startswith("SAPISID="):
        sapisid = part.split("=", 1)[1]
    elif part.startswith("__Secure-3PAPISID=") and not sapisid:
        sapisid = part.split("=", 1)[1]

if not sapisid:
    print("\nError: Could not find SAPISID in cookie. Make sure you're logged in.")
    sys.exit(1)

# Generate SAPISIDHASH authorization
origin = "https://music.youtube.com"
timestamp = str(int(time.time()))
hash_input = f"{timestamp} {sapisid} {origin}"
sapisid_hash = hashlib.sha1(hash_input.encode()).hexdigest()
authorization = f"SAPISIDHASH {timestamp}_{sapisid_hash}"

headers = {
    "accept": "*/*",
    "accept-language": "en-US,en;q=0.9",
    "content-type": "application/json",
    "cookie": cookie,
    "authorization": authorization,
    "origin": origin,
    "referer": "https://music.youtube.com/",
    "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36",
    "x-goog-authuser": "0",
    "x-origin": origin,
}

with open(filepath, "w") as f:
    json.dump(headers, f, indent=2)

# Test auth by checking liked songs (requires valid session)
from ytmusicapi import YTMusic
try:
    yt = YTMusic(filepath)
    liked = yt.get_liked_songs(limit=1)
    tracks = liked.get("tracks", [])
    if tracks:
        print(f"\nSuccess! Found liked song: {tracks[0]['title']}")
    else:
        print("\nSuccess! Auth works (no liked songs found).")
    print(f"Auth saved to {filepath}")
    print("You can now use :YTMusic in Neovim!")
except Exception:
    os.remove(filepath)
    print("\nAuth failed — cookies are stale or not fully logged in.")
    print("Make sure you grab cookies from an INCOGNITO window after signing in.")
    sys.exit(1)
    print(f"File saved to {filepath} — you may need to re-copy cookies.")
