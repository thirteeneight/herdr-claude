#!/usr/bin/env bash
# Installs or updates herdr-claude, herdr-layout, the agents-cache sidebar mod and claude-statusline.
# Re-run after `git pull`. Pass --autocompact to also write the autocompact config (kept if it exists).
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
bin="$HOME/.local/bin"
herdr="$HOME/.config/herdr-app"
config="$HOME/.config/herdr-claude/config.json"

mkdir -p "$bin" "$herdr/mods/agents-cache" "$herdr/layouts"
install -m 755 "$repo/bin/herdr-claude" "$repo/bin/herdr-layout" "$bin/"
install -m 755 "$repo/claude/statusline.sh" "$bin/claude-statusline"
install -m 644 "$repo/herdr-app/mods/agents-cache/main.js" "$repo/herdr-app/mods/agents-cache/mod.json" "$herdr/mods/agents-cache/"
install -m 644 "$repo/herdr-app/layouts/main-cache.json" "$herdr/layouts/"
echo "Installed scripts to $bin and the mod and layout to $herdr"
echo "Claude Code settings are untouched; see the README for promptCacheTtl and statusLine"

if [ "${1:-}" = "--autocompact" ]; then
  if [ -e "$config" ]; then
    echo "Kept existing $config"
  else
    mkdir -p "$(dirname "$config")"
    install -m 644 "$repo/config/autocompact.json" "$config"
    echo "Autocompact on: wrote $config"
  fi
fi

if command -v herdr-app >/dev/null; then
  herdr-app check "$herdr/mods/agents-cache"
else
  echo "herdr-app not on PATH; skipped the mod check"
fi
case ":$PATH:" in *":$bin:"*) ;; *) echo "Add $bin to your PATH" ;; esac
