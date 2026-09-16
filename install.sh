#!/bin/bash
# Install voxhud into the Omarchy shell. Safe to re-run; it is also the dev
# loop (edit here, run this, the shell hot-reloads).
#
# What it changes, and what uninstall.sh puts back:
#   ~/.config/omarchy/plugins/io.github.aashbury.voxhud/   the plugin
#   ~/.config/omarchy/shell.json          voxhud widget added; Omarchy's own
#                                         Dictation indicator hidden
#   ~/.config/voxtype/config.toml         osd.enabled = false (voxtype's overlay)
#   ~/.local/bin/voxhud                   symlink to the CLI
# Nothing under ~/.config/hypr is touched.

set -euo pipefail

REPO=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
PLUGIN_ID="io.github.aashbury.voxhud"
PLUGINS_DIR="$HOME/.config/omarchy/plugins"
TARGET="$PLUGINS_DIR/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
STATE_DIR="$HOME/.local/state/voxhud"
BIN_LINK="$HOME/.local/bin/voxhud"
INDICATORS_ALL='["Dictation","ScreenRecording","Reminder","NightLight","Dnd","StayAwake"]'

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

shell_ipc() {
  if command -v omarchy-shell >/dev/null 2>&1; then omarchy-shell "$@"
  else "${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-shell" "$@"
  fi
}

echo
echo "Installing voxhud"
echo

# ---- preflight ---------------------------------------------------------------
for tool in jq rsync python3; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
command -v voxtype >/dev/null || warn "voxtype not installed - run: omarchy voxtype install (the HUD will wait for it)"
shell_ipc shell ping >/dev/null 2>&1 || die "omarchy-shell is not running"
[[ -f $SHELL_JSON ]] || die "$SHELL_JSON not found"

# ---- validate + copy ---------------------------------------------------------
if command -v omarchy >/dev/null; then
  omarchy plugin validate "$REPO" >/dev/null || die "manifest failed validation (omarchy plugin validate $REPO)"
  ok "manifest valid"
fi

mkdir -p "$PLUGINS_DIR" "$STATE_DIR"
if [[ $REPO == "$TARGET" ]]; then
  # Already the installed copy — `omarchy plugin add` cloned it here, and this
  # script is only doing the parts a plugin install is not allowed to do.
  chmod +x "$TARGET/bin/voxhud" "$TARGET/bin/voxhud-levels" "$TARGET/uninstall.sh"
  ok "running from the installed plugin"
else
  # The shell reloads the plugin on every file event under its folder, so stage
  # the copy in a dot-directory (which the watcher ignores) and swap it in with
  # two renames: one reload instead of one per file.
  STAGE="$PLUGINS_DIR/.$PLUGIN_ID.staging"
  OLD="$PLUGINS_DIR/.$PLUGIN_ID.old"
  rm -rf "$STAGE" "$OLD"
  rsync -a \
    --exclude .git --exclude .gitignore --exclude tests --exclude '*.md' --exclude 'preview.*' \
    "$REPO/" "$STAGE/"
  chmod +x "$STAGE/bin/voxhud" "$STAGE/bin/voxhud-levels" "$STAGE/install.sh" "$STAGE/uninstall.sh"
  [[ -d $TARGET ]] && mv "$TARGET" "$OLD"
  mv "$STAGE" "$TARGET"
  rm -rf "$OLD"
  ok "plugin copied to ${TARGET/#$HOME/\~}"
fi

shell_ipc shell rescanPlugins >/dev/null 2>&1 || true
for _ in $(seq 1 25); do
  if shell_ipc shell listPlugins 2>/dev/null | jq -e --arg id "$PLUGIN_ID" '.[] | select(.id==$id)' >/dev/null 2>&1; then break; fi
  sleep 0.2
done
shell_ipc shell listPlugins 2>/dev/null | jq -e --arg id "$PLUGIN_ID" '.[] | select(.id==$id)' >/dev/null 2>&1 \
  || die "the shell did not pick the plugin up (journalctl --user -t omarchy-shell -n 50)"
ok "shell registered the plugin"

# ---- bar widget (this one entry enables service + HUD + widget) --------------
if jq -e --arg id "$PLUGIN_ID" '[.bar.layout[]?[]? | select((type=="object" and .id==$id) or .==$id)] | length > 0' "$SHELL_JSON" >/dev/null; then
  ok "widget already in the bar"
else
  omarchy bar put "$PLUGIN_ID" --section center --index 0 >/dev/null
  ok "widget placed in the bar (center, first)"
fi

# ---- hide Omarchy's own Dictation indicator ---------------------------------
# It goes invisible while Voxtype transcribes; voxhud's icon replaces it.
current_items=$(jq -c '[.bar.layout[]?[]? | select(type=="object" and .id=="omarchy.indicators")][0].items // null' "$SHELL_JSON")
if [[ ! -f "$STATE_DIR/indicators-items.json" ]]; then
  printf '%s\n' "$current_items" > "$STATE_DIR/indicators-items.json"
fi
if [[ $current_items == "null" ]]; then base_items=$INDICATORS_ALL; else base_items=$current_items; fi
if printf '%s' "$base_items" | jq -e 'index("Dictation") != null' >/dev/null; then
  new_items=$(printf '%s' "$base_items" | jq -c 'map(select(. != "Dictation"))')
  # `omarchy bar set --json` can't carry an array through the IPC, so edit the
  # entry in place; the shell hot-reloads shell.json.
  tmp=$(mktemp)
  jq --argjson items "$new_items" \
    '.bar.layout |= with_entries(.value |= (if type=="array" then map(if type=="object" and .id=="omarchy.indicators" then . + {items: $items} else . end) else . end))' \
    "$SHELL_JSON" > "$tmp" && mv "$tmp" "$SHELL_JSON" || { rm -f "$tmp"; die "could not edit $SHELL_JSON"; }
  ok "Omarchy's Dictation indicator hidden"
else
  ok "Omarchy's Dictation indicator already hidden"
fi

# ---- voxtype's own overlay off -----------------------------------------------
if command -v voxtype >/dev/null; then
  osd_now=$(voxtype config get osd.enabled 2>/dev/null | grep -oiE 'true|false' | tail -1 || echo true)
  [[ -f "$STATE_DIR/osd-enabled" ]] || printf '%s\n' "${osd_now:-true}" > "$STATE_DIR/osd-enabled"
  if [[ ${osd_now:-true} != "false" ]]; then
    voxtype config set osd.enabled false >/dev/null
    if systemctl --user is-active --quiet voxtype.service; then
      systemctl --user restart voxtype.service
      ok "voxtype's overlay turned off (daemon restarted)"
    else
      ok "voxtype's overlay turned off"
    fi
  else
    ok "voxtype's overlay already off"
  fi
fi

# ---- CLI on PATH -------------------------------------------------------------
mkdir -p "$(dirname "$BIN_LINK")"
if [[ -e $BIN_LINK && ! -L $BIN_LINK ]]; then
  warn "${BIN_LINK/#$HOME/\~} exists and is not a symlink - left alone"
else
  ln -sfn "$TARGET/bin/voxhud" "$BIN_LINK"
  ok "voxhud linked into ${BIN_LINK/#$HOME/\~}"
fi
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) warn "~/.local/bin is not on your PATH; use $TARGET/bin/voxhud" ;;
esac

echo
"$TARGET/bin/voxhud" doctor || true
echo
echo "  Preview it:   voxhud demo tour"
echo "  Dictionary:   click the mic in the bar"
echo
