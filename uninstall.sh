#!/bin/bash
# Remove voxhud and put back what install.sh changed.

set -uo pipefail

PLUGIN_ID="voxhud"
TARGET="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
STATE_DIR="$HOME/.local/state/voxhud"
BIN_LINK="$HOME/.local/bin/voxhud"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

shell_ipc() {
  if command -v omarchy-shell >/dev/null 2>&1; then omarchy-shell "$@"
  else "${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-shell" "$@"
  fi
}

echo
echo "Removing voxhud"
echo

# ---- voxtype's overlay back --------------------------------------------------
if command -v voxtype >/dev/null; then
  was=$(cat "$STATE_DIR/osd-enabled" 2>/dev/null || echo true)
  now=$(voxtype config get osd.enabled 2>/dev/null | grep -oiE 'true|false' | tail -1 || echo false)
  if [[ $was != "false" && $now == "false" ]]; then
    voxtype config unset osd.enabled >/dev/null 2>&1 || voxtype config set osd.enabled true >/dev/null 2>&1
    systemctl --user is-active --quiet voxtype.service && systemctl --user restart voxtype.service
    ok "voxtype's overlay restored"
  else
    ok "voxtype's overlay left as it was"
  fi
fi

# ---- Omarchy's Dictation indicator back --------------------------------------
if [[ -f $SHELL_JSON ]]; then
  saved=$(cat "$STATE_DIR/indicators-items.json" 2>/dev/null || echo null)
  if [[ $saved == "null" ]]; then
    tmp=$(mktemp)
    if jq '.bar.layout |= with_entries(.value |= (if type=="array" then map(if type=="object" and .id=="omarchy.indicators" then del(.items) else . end) else . end))' \
        "$SHELL_JSON" > "$tmp" && mv "$tmp" "$SHELL_JSON"; then
      ok "Omarchy's Dictation indicator restored"
    else
      rm -f "$tmp"; warn "could not edit $SHELL_JSON - check omarchy.indicators items by hand"
    fi
  else
    omarchy bar set omarchy.indicators items "$saved" --json >/dev/null 2>&1 && ok "Omarchy's indicator list restored"
  fi
fi

# ---- widget + plugin ---------------------------------------------------------
omarchy plugin disable "$PLUGIN_ID" >/dev/null 2>&1 || true
if [[ -f $SHELL_JSON ]]; then
  tmp=$(mktemp)
  if jq --arg id "$PLUGIN_ID" '.bar.layout |= with_entries(.value |= (if type=="array" then map(select((type=="object" and .id==$id) or .==$id | not)) else . end)) | .plugins |= (if type=="array" then map(select((type=="object" and .id==$id) or .==$id | not)) else . end)' \
      "$SHELL_JSON" > "$tmp" && mv "$tmp" "$SHELL_JSON"; then
    ok "widget removed from the bar"
  else
    rm -f "$tmp"
  fi
fi

[[ -L $BIN_LINK ]] && rm -f "$BIN_LINK" && ok "removed ${BIN_LINK/#$HOME/\~}"
rm -rf "$TARGET" "$STATE_DIR" && ok "plugin files removed"
shell_ipc shell rescanPlugins >/dev/null 2>&1 || true

echo
echo "  Your dictionary is still in ~/.config/voxtype/config.toml."
echo
