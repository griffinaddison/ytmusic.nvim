#!/usr/bin/env bash
set -euo pipefail

# ytmusic.nvim standalone installer
# Usage: curl -sSL https://raw.githubusercontent.com/griffinaddison/ytmusic.nvim/main/install.sh | sh

REPO="https://github.com/griffinaddison/ytmusic.nvim.git"
APPNAME="ytmusic-nvim"
CONFIG_DIR="$HOME/.config/$APPNAME"
DATA_DIR="$HOME/.local/share/$APPNAME"
VENV_DIR="$HOME/.local/share/ytmusic-nvim-venv"
BIN_DIR="$HOME/.local/bin"

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Check for brew (macOS) or apt (Linux) ---
install_deps() {
    info "Installing dependencies..."
    if command -v brew &>/dev/null; then
        brew install mpv yt-dlp socat
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y mpv yt-dlp socat
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --needed mpv yt-dlp socat
    else
        err "Could not detect package manager. Install manually: mpv, yt-dlp, socat"
    fi
}

# --- Check prerequisites ---
for cmd in git nvim python3; do
    command -v "$cmd" &>/dev/null || err "'$cmd' not found. Please install it first."
done

# --- Install system deps if missing ---
missing=false
for cmd in mpv yt-dlp socat; do
    command -v "$cmd" &>/dev/null || missing=true
done
if [ "$missing" = true ]; then
    install_deps
fi

# --- Python venv + ytmusicapi ---
if [ ! -d "$VENV_DIR" ]; then
    info "Creating Python venv..."
    python3 -m venv "$VENV_DIR"
fi
info "Installing ytmusicapi..."
"$VENV_DIR/bin/pip" install -q --upgrade ytmusicapi

# --- Clone plugin ---
PLUGIN_DIR="$DATA_DIR/lazy/ytmusic.nvim"
if [ -d "$PLUGIN_DIR" ]; then
    info "Updating ytmusic.nvim..."
    git -C "$PLUGIN_DIR" pull --quiet
else
    info "Cloning ytmusic.nvim..."
    mkdir -p "$DATA_DIR/lazy"
    git clone --quiet "$REPO" "$PLUGIN_DIR"
fi

# --- Clone lazy.nvim ---
LAZY_DIR="$DATA_DIR/lazy/lazy.nvim"
if [ ! -d "$LAZY_DIR" ]; then
    info "Cloning lazy.nvim..."
    git clone --quiet --filter=blob:none https://github.com/folke/lazy.nvim.git --branch=stable "$LAZY_DIR"
fi

# --- Write minimal nvim config ---
info "Writing config to $CONFIG_DIR..."
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/init.lua" << 'EOF'
-- ytmusic.nvim standalone config
local data = vim.fn.stdpath("data")
vim.opt.rtp:prepend(data .. "/lazy/lazy.nvim")

require("lazy").setup({
  {
    dir = data .. "/lazy/ytmusic.nvim",
    config = function()
      require("ytmusic").setup()
    end,
    cmd = { "YTMusic", "YTSearch" },
    keys = {
      { "<leader>mm", "<cmd>YTMusic<cr>", desc = "Open YouTube Music" },
      { "<leader>ms", ":YTSearch ", desc = "Search YouTube Music" },
    },
  },
}, {
  performance = { rtp = { reset = false } },
})
EOF

# --- Create launcher script ---
info "Creating 'ytm' launcher in $BIN_DIR..."
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/ytm" << 'EOF'
#!/usr/bin/env bash
NVIM_APPNAME=ytmusic-nvim exec nvim "$@"
EOF
chmod +x "$BIN_DIR/ytm"

# --- Auth setup ---
AUTH_DIR="$HOME/.config/ytmusic.nvim"
if [ ! -f "$AUTH_DIR/browser.json" ]; then
    info "Running auth setup..."
    mkdir -p "$AUTH_DIR"
    "$VENV_DIR/bin/python3" "$PLUGIN_DIR/setup_auth.py"
else
    info "Auth already configured ($AUTH_DIR/browser.json)"
fi

echo
info "Done! Run 'ytm' to start."
info "Make sure $BIN_DIR is in your PATH."
