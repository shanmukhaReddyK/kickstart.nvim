#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bootstrap.sh — set up everything this Neovim config needs, on any Linux box.
#
# Installs / ensures:
#   - Neovim nightly (config uses vim.pack / PackChanged -> needs >= 0.12)
#   - tree-sitter CLI (nvim-treesitter `main` builds parsers with it)
#   - ripgrep + fd        (Telescope live_grep / find_files)
#   - clangd, gcc, make   (C / kernel LSP + building)
#   - unzip               (Mason extracts zip-packaged tools)
#   - git, python3, tmux, curl, tar, gzip (general workflow)
#
# Safe to re-run: every step is idempotent.
# Usage:  bash ~/.config/nvim/bootstrap.sh
# ---------------------------------------------------------------------------
set -euo pipefail

# --- config ---------------------------------------------------------------
NVIM_DIR="$HOME/nvim-nightly"       # nightly install location
LOCAL_BIN="$HOME/.local/bin"        # user binaries (tree-sitter, fd symlink)
NVIM_CHANNEL="nightly"              # nightly | stable

# --- pretty output --------------------------------------------------------
info()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }

have()  { command -v "$1" >/dev/null 2>&1; }

# --- detect arch ----------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)   NVIM_ARCH="x86_64"; TS_ARCH="x64" ;;
  aarch64|arm64)  NVIM_ARCH="arm64";  TS_ARCH="arm64" ;;
  *) err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

mkdir -p "$LOCAL_BIN"

# --- sudo helper (works with or without sudo) -----------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if have sudo && sudo -n true 2>/dev/null; then
    SUDO="sudo"
  elif have sudo; then
    SUDO="sudo"   # may prompt for a password
  fi
fi

# ---------------------------------------------------------------------------
# 1. System packages (best-effort, per package manager)
# ---------------------------------------------------------------------------
install_system_packages() {
  info "Installing system packages..."
  if have apt-get; then
    $SUDO apt-get update -y || warn "apt update failed (continuing)"
    $SUDO apt-get install -y \
      ripgrep fd-find clangd unzip git make gcc g++ python3 tmux curl tar gzip \
      universal-ctags cscope bear || warn "some apt packages failed"
  elif have dnf; then
    $SUDO dnf install -y \
      ripgrep fd-find clang-tools-extra unzip git make gcc gcc-c++ python3 tmux \
      curl tar gzip ctags cscope bear || warn "some dnf packages failed"
  elif have pacman; then
    $SUDO pacman -Sy --needed --noconfirm \
      ripgrep fd clang unzip git make gcc python tmux curl tar gzip \
      ctags cscope bear || warn "some pacman packages failed"
  elif have zypper; then
    $SUDO zypper install -y \
      ripgrep fd clang-tools unzip git make gcc-c++ python3 tmux curl tar gzip \
      ctags cscope bear || warn "some zypper packages failed"
  else
    warn "No known package manager found; install ripgrep/fd/clangd/unzip/gcc manually."
  fi
}

# ---------------------------------------------------------------------------
# 2. fd symlink (Debian/Ubuntu ship the binary as 'fdfind')
# ---------------------------------------------------------------------------
setup_fd() {
  if have fd; then
    ok "fd present"
  elif have fdfind; then
    ln -sf "$(command -v fdfind)" "$LOCAL_BIN/fd"
    ok "linked fdfind -> $LOCAL_BIN/fd"
  else
    warn "fd not found (Telescope find_files will fall back)"
  fi
}

# ---------------------------------------------------------------------------
# 3. Neovim nightly (prebuilt tarball, no root needed)
# ---------------------------------------------------------------------------
install_neovim() {
  if [ -x "$NVIM_DIR/bin/nvim" ]; then
    local ver
    ver="$("$NVIM_DIR/bin/nvim" --version | head -1)"
    ok "Neovim already installed: $ver"
    info "  (re-run with FORCE_NVIM=1 to reinstall the latest $NVIM_CHANNEL)"
    [ "${FORCE_NVIM:-0}" = "1" ] || return 0
  fi

  local tarball="nvim-linux-${NVIM_ARCH}.tar.gz"
  local url="https://github.com/neovim/neovim/releases/download/${NVIM_CHANNEL}/${tarball}"
  info "Downloading Neovim ${NVIM_CHANNEL} ($NVIM_ARCH)..."
  local tmp
  tmp="$(mktemp -d)"
  if ! curl -fL -o "$tmp/$tarball" "$url"; then
    # Fallback to the older asset name
    warn "asset $tarball not found, trying legacy name nvim-linux64.tar.gz"
    tarball="nvim-linux64.tar.gz"
    url="https://github.com/neovim/neovim/releases/download/${NVIM_CHANNEL}/${tarball}"
    curl -fL -o "$tmp/$tarball" "$url"
  fi
  tar -xzf "$tmp/$tarball" -C "$tmp"
  local extracted
  extracted="$(find "$tmp" -maxdepth 1 -type d -name 'nvim-*' | head -1)"
  rm -rf "$NVIM_DIR"
  mv "$extracted" "$NVIM_DIR"
  rm -rf "$tmp"
  ok "Neovim installed: $("$NVIM_DIR/bin/nvim" --version | head -1)"
}

# ---------------------------------------------------------------------------
# 4. tree-sitter CLI (prebuilt binary)
# ---------------------------------------------------------------------------
install_tree_sitter() {
  if have tree-sitter; then
    ok "tree-sitter present: $(tree-sitter --version)"
    return 0
  fi
  info "Installing tree-sitter CLI ($TS_ARCH)..."
  local url="https://github.com/tree-sitter/tree-sitter/releases/latest/download/tree-sitter-linux-${TS_ARCH}.gz"
  local tmp
  tmp="$(mktemp -d)"
  curl -fL -o "$tmp/ts.gz" "$url"
  gunzip -f "$tmp/ts.gz"
  chmod +x "$tmp/ts"
  mv "$tmp/ts" "$LOCAL_BIN/tree-sitter"
  rm -rf "$tmp"
  ok "tree-sitter installed: $("$LOCAL_BIN/tree-sitter" --version)"
}

# ---------------------------------------------------------------------------
# 5. PATH wiring in the user's shell rc
# ---------------------------------------------------------------------------
add_path_line() {
  local rc="$1" line="$2"
  [ -f "$rc" ] || return 0
  if ! grep -qF "$line" "$rc"; then
    printf '\n%s\n' "$line" >> "$rc"
    ok "added PATH entry to $rc"
  fi
}

setup_path() {
  local nvim_line='export PATH="$HOME/nvim-nightly/bin:$PATH"'
  local local_line='export PATH="$HOME/.local/bin:$PATH"'
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    add_path_line "$rc" "$nvim_line"
    add_path_line "$rc" "$local_line"
  done
  export PATH="$HOME/nvim-nightly/bin:$HOME/.local/bin:$PATH"
}

# ---------------------------------------------------------------------------
# 6. Summary / verification
# ---------------------------------------------------------------------------
summary() {
  echo
  info "Verification:"
  for c in nvim tree-sitter rg fd clangd gcc make git tmux unzip; do
    if have "$c"; then
      printf '  \033[1;32m✓\033[0m %-12s %s\n' "$c" "$(command -v "$c")"
    else
      printf '  \033[1;31m✗\033[0m %-12s missing\n' "$c"
    fi
  done
  echo
  ok "Done. Open a new shell (or 'source ~/.bashrc'), then run: nvim"
  info "First launch: vim.pack installs plugins; run :checkhealth to verify."
}

# --- run ------------------------------------------------------------------
install_system_packages
setup_fd
install_neovim
install_tree_sitter
setup_path
summary
