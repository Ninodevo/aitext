#!/usr/bin/env python3
"""Build install.sh from the repo's real sources.

install.sh is a generated artifact: it embeds bin/*, prompts/*.md and
hotkeys.conf so a fresh Mac needs exactly one file. Edit the sources, never
install.sh, then run:  ./tools/build-installer.py
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = ("aitext", "aitext-clip", "aitext-config", "aitext-keys", "aitext-log", "aitext-service", "aitext-prompts")


def read(*parts):
    with open(os.path.join(ROOT, *parts)) as f:
        return f.read()


def embed_tool(name):
    body = read("bin", name)
    delim = name.upper().replace("-", "_") + "_EOF"
    if delim in body:
        sys.exit(f"error: heredoc delimiter {delim} appears inside bin/{name}")
    return (
        f'cat > "$BIN_DIR/{name}" <<\'{delim}\'\n{body}{delim}\n'
        f'chmod +x "$BIN_DIR/{name}"\nok "$BIN_DIR/{name}"\n'
    )


def manifest_modes():
    """Modes in hotkeys.conf order, so prompts install in a sensible order."""
    modes = []
    for line in read("hotkeys.conf").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            modes.append(line.split("|")[0])
    return modes


def embed_prompts():
    prompt_dir = os.path.join(ROOT, "prompts")
    on_disk = sorted(f[:-3] for f in os.listdir(prompt_dir) if f.endswith(".md"))
    ordered = [m for m in manifest_modes() if m in on_disk]
    ordered += [m for m in on_disk if m not in ordered]  # prompts with no hotkey

    missing = [m for m in manifest_modes() if m not in on_disk and m != "clip"]
    if missing:
        sys.exit(f"error: hotkeys.conf lists modes with no prompt file: {missing}")

    out = ""
    for mode in ordered:
        body = read("prompts", f"{mode}.md")
        if "PROMPT_EOF" in body:
            sys.exit(f"error: delimiter PROMPT_EOF appears inside prompts/{mode}.md")
        if not body.endswith("\n"):
            body += "\n"
        out += f"write_prompt {mode} <<'PROMPT_EOF'\n{body}PROMPT_EOF\n\n"
    return out, ordered


HEADER = r'''#!/usr/bin/env bash
#
# aitext installer — AI text-transform hotkeys for macOS.
#
#   ./install.sh                 install / update everything
#   ./install.sh --no-shortcuts  install, but don't touch keyboard shortcuts
#   ./install.sh --no-key        skip the API-key step (set it up later)
#   ./install.sh --force         overwrite prompt files you've edited
#   ./install.sh --uninstall     remove everything this script installed
#
# Safe to re-run. Prompt files you've edited are left alone unless --force.
# Your API key is never written to disk by this script — it goes to the login
# Keychain, entered by you in a native secure-input dialog.
#
# The hotkey list lives in ~/.config/aitext/hotkeys.conf, NOT in this script.
# That file is the source of truth: this installer seeds it on a fresh machine
# and reads it thereafter, and `aitext-prompts new/rm` keeps it in sync.
#
# GENERATED FILE — built from bin/, prompts/ and hotkeys.conf by
# tools/build-installer.py. Edit those, not this.

set -uo pipefail

BIN_DIR="$HOME/.local/bin"
CONF_DIR="$HOME/.config/aitext"
PROMPT_DIR="$CONF_DIR/prompts"
MANIFEST="$CONF_DIR/hotkeys.conf"
STATE_DIR="$HOME/.local/state/aitext"
SERVICES_DIR="$HOME/Library/Services"
PBS_PLIST="$HOME/Library/Preferences/pbs.plist"
PB=/usr/libexec/PlistBuddy
ACTION_BUNDLE="/System/Library/Automator/Run Shell Script.action"

DO_SHORTCUTS=1 DO_KEY=1 FORCE=0 UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --no-shortcuts) DO_SHORTCUTS=0 ;;
    --no-key)       DO_KEY=0 ;;
    --force)        FORCE=1 ;;
    --uninstall)    UNINSTALL=1 ;;
    -h|--help)      awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) echo "unknown option: $arg (try --help)"; exit 2 ;;
  esac
done

# __DEFAULT_MANIFEST__

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# Rows come from the config file; fall back to the seed if it's missing.
manifest_rows() {
  if [[ -f "$MANIFEST" ]]; then
    grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$MANIFEST"
  else
    printf '%s\n' "$DEFAULT_MANIFEST" | grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$'
  fi
}

# --------------------------------------------------------------------------
# uninstall
# --------------------------------------------------------------------------
if (( UNINSTALL )); then
  step "Uninstalling aitext"
  while IFS='|' read -r mode name key; do
    [[ -n "$mode" ]] || continue
    rm -rf "$SERVICES_DIR/$name.workflow"
    $PB -c "Delete :NSServicesStatus:'(null) - $name - runWorkflowAsService'" "$PBS_PLIST" >/dev/null 2>&1
  done < <(manifest_rows)
  ok "removed Quick Actions and their shortcuts"
  rm -f "$BIN_DIR/aitext" "$BIN_DIR/aitext-clip" "$BIN_DIR/aitext-config" "$BIN_DIR/aitext-keys" "$BIN_DIR/aitext-log" "$BIN_DIR/aitext-service" "$BIN_DIR/aitext-prompts"
  ok "removed the aitext commands"
  killall -u "$USER" cfprefsd 2>/dev/null
  /System/Library/CoreServices/pbs -flush 2>/dev/null
  echo
  echo "Left in place (delete by hand if you want them gone):"
  echo "  $PROMPT_DIR   — your prompt files"
  echo "  $MANIFEST     — your hotkey list"
  echo "  $CONF_DIR/config  — your settings (sounds etc.)"
  echo "  $STATE_DIR    — last-input backup"
  echo "  Keychain items OPENAI_API_KEY / ANTHROPIC_API_KEY"
  echo "     remove with: security delete-generic-password -s OPENAI_API_KEY"
  exit 0
fi

# --------------------------------------------------------------------------
# preflight
# --------------------------------------------------------------------------
step "Checking prerequisites"
[[ "$(uname -s)" == "Darwin" ]] || { err "macOS only."; exit 1; }
ok "macOS $(sw_vers -productVersion)"

if ! command -v jq >/dev/null 2>&1; then
  err "jq not found."
  echo "     Install it with:  brew install jq"
  exit 1
fi
ok "jq at $(command -v jq)"

[[ -d "$ACTION_BUNDLE" ]] || { err "Missing $ACTION_BUNDLE — can't build Quick Actions."; exit 1; }
ok "Run Shell Script action present"

case ":$PATH:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR is on your PATH" ;;
  *) warn "$BIN_DIR is not on your PATH — the hotkeys still work, but the aitext commands won't be runnable by name."
     echo "     Add this to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------
step "Installing commands"
mkdir -p "$BIN_DIR" "$PROMPT_DIR" "$STATE_DIR"

'''

MIDDLE = r'''
# --------------------------------------------------------------------------
# hotkey list
# --------------------------------------------------------------------------
step "Hotkey list"
if [[ -f "$MANIFEST" ]]; then
  ok "using your $MANIFEST ($(manifest_rows | wc -l | tr -d ' ') modes)"
else
  printf '%s' "$DEFAULT_MANIFEST" > "$MANIFEST"
  ok "seeded $MANIFEST"
fi

# --------------------------------------------------------------------------
# settings
# --------------------------------------------------------------------------
step "Settings"
if [[ -f "$CONF_DIR/config" ]]; then
  ok "using your $CONF_DIR/config (sounds: $("$BIN_DIR/aitext-config" get sounds))"
else
  printf '# aitext settings — see: aitext-config --help\nsounds=on\n' > "$CONF_DIR/config"
  ok "seeded $CONF_DIR/config (sound cues on — turn off with: aitext-config sounds off)"
fi

# --------------------------------------------------------------------------
# prompt pack
# --------------------------------------------------------------------------
step "Installing prompts"
write_prompt() {  # write_prompt <mode>   (file content on stdin)
  local f="$PROMPT_DIR/$1.md" content
  content=$(cat)
  if [[ -f "$f" && $FORCE -eq 0 ]]; then
    printf '  \033[90m·\033[0m %-9s (kept your version)\n' "$1"; return
  fi
  printf '%s\n' "$content" > "$f"
  ok "$1"
}

'''

FOOTER = r'''
# Any mode listed in the manifest but missing a prompt file gets a stub, so the
# Quick Action never fires into a "no prompt named X" alert.
while IFS='|' read -r mode name key; do
  [[ -n "$mode" ]] || continue
  [[ "$mode" == "clip" ]] && continue   # clipboard chooser — has no prompt file
  [[ -f "$PROMPT_DIR/$mode.md" ]] && continue
  printf 'temperature: 0.3\n---\nTODO: write the system prompt for %s here.\n' "$mode" > "$PROMPT_DIR/$mode.md"
  warn "$mode had no prompt file — wrote a stub, edit it with: aitext-prompts edit $mode"
done < <(manifest_rows)

# --------------------------------------------------------------------------
# Quick Actions
# --------------------------------------------------------------------------
step "Building Quick Actions"
mkdir -p "$SERVICES_DIR"
built=0
while IFS='|' read -r mode name key; do
  [[ -n "$mode" ]] || continue
  if [[ "$mode" == "clip" ]]; then
    if "$BIN_DIR/aitext-service" build-clip "$name" 2>/dev/null; then
      ok "$name → aitext-clip (clipboard chooser)"; built=$((built + 1))
    else
      err "$name — could not build"
    fi
  elif "$BIN_DIR/aitext-service" build "$mode" "$name" 2>/dev/null; then
    ok "$name → aitext $mode"; built=$((built + 1))
  else
    err "$name — could not build"
  fi
done < <(manifest_rows)
ok "$built Quick Actions registered"

# --------------------------------------------------------------------------
# shortcuts
# --------------------------------------------------------------------------
if (( DO_SHORTCUTS )); then
  step "Assigning keyboard shortcuts"
  cp "$PBS_PLIST" "$PBS_PLIST.aitext-backup" 2>/dev/null && ok "backed up pbs.plist"

  # Drop our own entries first, so a re-run doesn't see them as conflicts.
  while IFS='|' read -r mode name key; do
    [[ -n "$mode" ]] || continue
    $PB -c "Delete :NSServicesStatus:'(null) - $name - runWorkflowAsService'" "$PBS_PLIST" >/dev/null 2>&1
  done < <(manifest_rows)

  taken=$($PB -c "Print :NSServicesStatus" "$PBS_PLIST" 2>/dev/null \
          | grep -o 'key_equivalent = .*' | awk '{print $3}' || true)

  while IFS='|' read -r mode name key; do
    [[ -n "$mode" ]] || continue
    if [[ -z "$key" ]]; then
      printf '  \033[90m·\033[0m %-26s (no shortcut in %s)\n' "$name" "$(basename "$MANIFEST")"
      continue
    fi
    if ! printf '%s' "$key" | grep -qE '^[@$^~]+[a-z0-9]$'; then
      warn "$name — '$key' is not shortcut notation (@ ^ ~ \$ + one letter/digit), left unassigned"
      continue
    fi
    k=":NSServicesStatus:'(null) - $name - runWorkflowAsService'"
    if [[ -n "$taken" ]] && grep -qxF "$key" <<<"$taken"; then
      warn "$name — $key already bound by another service, left unassigned"
      continue
    fi
    $PB -c "Add $k dict" "$PBS_PLIST" >/dev/null 2>&1
    $PB -c "Add $k:key_equivalent string $key" "$PBS_PLIST" >/dev/null 2>&1
    $PB -c "Add $k:enabled_services_menu bool true" "$PBS_PLIST" >/dev/null 2>&1
    $PB -c "Add $k:enabled_context_menu bool true" "$PBS_PLIST" >/dev/null 2>&1
    printf '  \033[32m✓\033[0m %-26s %s\n' "$name" \
      "$(sed 's/@/⌘/g;s/\$/⇧/g;s/\^/⌃/g;s/~/⌥/g' <<<"$key" | tr 'a-z' 'A-Z')"
  done < <(manifest_rows)

  $PB -c "Set :ServicesShortcutsPresent 1" "$PBS_PLIST" >/dev/null 2>&1 \
    || $PB -c "Add :ServicesShortcutsPresent integer 1" "$PBS_PLIST" >/dev/null 2>&1
  killall -u "$USER" cfprefsd 2>/dev/null
  /System/Library/CoreServices/pbs -flush 2>/dev/null
  ok "shortcuts written"
else
  step "Skipping shortcuts (--no-shortcuts)"
  echo "     Assign them in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services ▸ Text"
  echo "     or with: aitext-keys set <mode> <combo>"
fi

# --------------------------------------------------------------------------
# API key
# --------------------------------------------------------------------------
step "API key"
have_openai=0
security find-generic-password -s OPENAI_API_KEY >/dev/null 2>&1 && have_openai=1

if (( have_openai )); then
  ok "OPENAI_API_KEY already in Keychain"
elif (( DO_KEY )); then
  echo "     Opening a secure dialog — your key is typed by you, hidden, and stored"
  echo "     in the login Keychain. It is never written to disk by this script."
  KEY=$(osascript -e 'try
    set r to display dialog "Paste your OpenAI API key (sk-...):" default answer "" with hidden answer buttons {"Skip","Save"} default button "Save" with title "aitext setup"
    if button returned of r is "Save" then return text returned of r
  end try' 2>/dev/null)
  if [[ -n "$KEY" ]]; then
    security add-generic-password -s OPENAI_API_KEY -a "$USER" -w "$KEY" -U && ok "stored in Keychain"
    unset KEY
    have_openai=1
  else
    warn "skipped — set it later with:"
    echo "       security add-generic-password -s OPENAI_API_KEY -a \"\$USER\" -w 'sk-...' -U"
  fi
else
  warn "skipped (--no-key). Set it later with:"
  echo "       security add-generic-password -s OPENAI_API_KEY -a \"\$USER\" -w 'sk-...' -U"
fi

security find-generic-password -s ANTHROPIC_API_KEY >/dev/null 2>&1 \
  && ok "ANTHROPIC_API_KEY present (the 'explain' hotkey will work)" \
  || echo "     (optional) ANTHROPIC_API_KEY not set — 'explain' will show an alert until you add one"

# --------------------------------------------------------------------------
# verify
# --------------------------------------------------------------------------
step "Verifying"
if (( have_openai )) && [[ -f "$PROMPT_DIR/grammar.md" ]]; then
  out=$(echo "this sentance have to many error in it" | "$BIN_DIR/aitext" grammar 2>/dev/null)
  if [[ -n "$out" && "$out" != "this sentance have to many error in it" ]]; then
    ok "live API call succeeded"
    echo "     in:  this sentance have to many error in it"
    echo "     out: $out"
  else
    err "the API call did not transform the text — an alert dialog should say why."
    echo "     Common causes: bad key, no network, or your account can't reach the"
    echo "     model named in $PROMPT_DIR/grammar.md"
  fi
else
  warn "no key — skipping the live test"
fi

step "Done"
cat <<EOF
  Try it: select sloppy text in any app and press ⇧⌃G, or right-click ▸ Services.
  ⌘Z undoes it as a single edit.

  Prompts:   aitext-prompts                  list every mode
             aitext-prompts doctor           live-test every mode
             aitext-prompts edit grammar     open in \$EDITOR
             aitext-prompts test grammar     run sample text through it
             aitext-prompts new harsh "AI Make Blunt" shift+ctrl+j
             aitext-prompts rm harsh

  Sounds:    aitext-config                   show settings
             aitext-config sounds off        silence the cues
             aitext-config test              hear them

  History:   aitext-log                      recent transforms (undo beyond ⌘Z)
             aitext-config set history off   stop logging them

  Hotkeys:   aitext-keys                     list bindings
             aitext-keys set grammar shift+ctrl+j
             aitext-keys unset explain

  Config:    $MANIFEST   (hotkey list — source of truth)
             $PROMPT_DIR

  Remove everything:  $0 --uninstall

  If a shortcut does nothing, the app has its own binding on that key — check the
  app's Services submenu; if the item is there, it's a key conflict, not a bug.
  If nothing shows up in Services at all, log out and back in.
EOF
'''


def main():
    dest = os.path.join(ROOT, "install.sh")
    manifest = read("hotkeys.conf")
    if "'" in manifest:
        sys.exit("error: hotkeys.conf contains a single quote, which breaks embedding")

    prompts, ordered = embed_prompts()

    seed = ("# Seed content for hotkeys.conf — used ONLY when that file doesn't exist yet.\n"
            f"DEFAULT_MANIFEST='{manifest}'")
    out = HEADER.replace("# __DEFAULT_MANIFEST__", seed)
    assert "DEFAULT_MANIFEST=" in out, "seed injection failed"
    out += "".join(embed_tool(t) + "\n" for t in TOOLS)
    out += MIDDLE
    out += prompts
    out += FOOTER

    with open(dest, "w") as f:
        f.write(out)
    os.chmod(dest, 0o755)
    print(
        f"wrote install.sh — {len(out.splitlines())} lines, "
        f"{len(TOOLS)} tools, {len(ordered)} prompts, "
        f"{len([l for l in manifest.splitlines() if l and not l.startswith('#')])} hotkeys"
    )


if __name__ == "__main__":
    main()
