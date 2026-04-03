# ytmusic.nvim

An [oil.nvim](https://github.com/stevearc/oil.nvim)-style YouTube Music player for Neovim. Browse your library, search, and play music — all in normal Neovim buffers with vim motions.

## Install

### Standalone (recommended for new users)

One command. Installs a self-contained neovim config — does not touch your existing setup.

```bash
curl -sSL https://raw.githubusercontent.com/griffinaddison/ytmusic.nvim/main/install.sh | sh
```

This will:
- Install dependencies (`mpv`, `yt-dlp`, `socat`) via your package manager
- Set up a Python venv with `ytmusicapi`
- Create an isolated neovim config at `~/.config/ytmusic-nvim/`
- Install a `ytmusic` launcher to `~/.local/bin/`
- Walk you through YouTube Music auth

Then just run:

```bash
ytmusic
```

> Make sure `~/.local/bin` is in your `PATH`. The standalone config is completely isolated via `NVIM_APPNAME` — your existing `~/.config/nvim/` is untouched.

### Add to existing Neovim config

#### Dependencies

- [mpv](https://mpv.io/) + [yt-dlp](https://github.com/yt-dlp/yt-dlp) (audio playback)
- [socat](http://www.dest-unreach.org/socat/) (mpv IPC)
- Python 3.10+ with [ytmusicapi](https://github.com/sigma67/ytmusicapi)

```bash
brew install mpv yt-dlp socat
python3 -m venv ~/.local/share/ytmusic-nvim-venv
~/.local/share/ytmusic-nvim-venv/bin/pip install ytmusicapi
```

#### Plugin

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "griffinaddison/ytmusic.nvim",
  config = function()
    require("ytmusic").setup()
  end,
  cmd = { "YTMusic", "YTSearch" },
  keys = {
    { "<leader>mm", "<cmd>YTMusic<cr>", desc = "Open YouTube Music" },
    { "<leader>ms", ":YTSearch ", desc = "Search YouTube Music" },
  },
}
```

#### Auth Setup

1. Open `music.youtube.com` in Chrome (make sure you're logged in)
2. Open DevTools (`Cmd+Option+I`) > **Network** tab
3. Check **Disable cache**
4. Hard refresh (`Cmd+Shift+R`)
5. Click the first `music.youtube.com` request
6. Scroll to **Request Headers** > copy the **Cookie** value
7. Save it:
   ```bash
   pbpaste > ~/.config/ytmusic.nvim/cookie.txt
   ```
8. Run setup:
   ```bash
   ~/.local/share/ytmusic-nvim-venv/bin/python3 setup_auth.py
   ```

## Usage

| Command | Action |
|---|---|
| `:YTMusic` | Open library browser |
| `:YTSearch <query>` | Search for songs |

### Buffer Navigation (oil.nvim-style)

The buffer IS the UI. Standard vim motions work.

| Key | Action |
|---|---|
| `j` / `k` | Navigate |
| `Enter` | Open playlist / play track |
| `-` | Go back |
| `dd` | Remove from queue or playlist |
| `yy` | Yank a track |
| `p` | Paste track into current buffer |
| `a` | Add track to queue |
| `:w` | Sync playlist changes to YouTube Music |
| `/` | Search within buffer (native vim) |

### Playback

| Key | Action |
|---|---|
| `<leader>mp` | Play / pause |
| `<leader>mn` | Next track |
| `<leader>mN` | Previous track |
| `<leader>mq` | Stop playback |

### Statusline

Add to your statusline (e.g. lualine):

```lua
require("ytmusic.statusline").now_playing()
```

## Disclaimer

This project is for personal and educational use. It is not affiliated with, endorsed by, or sponsored by Google or YouTube. Use at your own discretion. A YouTube Music Premium subscription is recommended.

## License

[MIT](LICENSE)
