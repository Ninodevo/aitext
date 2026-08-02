#!/usr/bin/env bash
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

# Seed content for hotkeys.conf — used ONLY when that file doesn't exist yet.
DEFAULT_MANIFEST='# aitext hotkeys — one line per mode:   mode|Services menu name|shortcut
#
# Shortcut notation:  @ = command   ^ = control   ~ = option   $ = shift
# macOS reserves ⇧⌃ with A B E F N P V for text selection — avoid those.
#
# Edit by hand, or use: aitext-prompts new/rm, aitext-keys set/unset.
# install.sh reads THIS file — it is the source of truth.

grammar|AI Fix Grammar|$^g
clarify|AI Rewrite Clearer|$^r
shorten|AI Shorten|$^k
formal|AI Make Formal|$^o
casual|AI Make Casual|$^c
bullets|AI To Bullets|$^u
expand|AI Expand Notes|$^d
tldr|AI Summarize|$^s
en|AI Translate to English|$^t
hr|AI Translate to Croatian|$^h
reply|AI Draft Reply|$^y
explain|AI Explain This|$^x
commit|AI Commit Message|$^m
ask|AI Ask|$^i
'

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
  rm -f "$BIN_DIR/aitext" "$BIN_DIR/aitext-config" "$BIN_DIR/aitext-keys" "$BIN_DIR/aitext-log" "$BIN_DIR/aitext-service" "$BIN_DIR/aitext-prompts"
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

cat > "$BIN_DIR/aitext" <<'AITEXT_EOF'
#!/usr/bin/env bash
# aitext <mode> — reads selected text on stdin, writes transformed text on stdout.
#
# Environment:
#   AITEXT_BATCH=1        script mode: errors go to stderr (no dialogs), no
#                         sounds, output modes are ignored (result → stdout),
#                         and failures exit non-zero. Used by `aitext-prompts
#                         doctor` and scripts.
#   AITEXT_INSTRUCTION=…  answer an `ask:` prompt without showing the dialog
#   AITEXT_SOUNDS=on|off  override the sound setting
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

MODE="${1:-grammar}"
CONF_DIR="${AITEXT_CONF_DIR:-$HOME/.config/aitext}"
CONF_FILE="$CONF_DIR/config"
PROMPT_DIR="${AITEXT_PROMPTS:-$CONF_DIR/prompts}"
STATE_DIR="${AITEXT_STATE:-$HOME/.local/state/aitext}"
PROMPT_FILE="$PROMPT_DIR/$MODE.md"
BATCH="${AITEXT_BATCH:-}"

TEXT=$(cat)

# ---- settings: config file, overridable per-prompt and by environment -------
conf() {  # conf <key> <default>
  local v=""
  [ -f "$CONF_FILE" ] && v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF_FILE" | tail -1)
  printf '%s' "${v:-$2}"
}
SOUNDS=$(conf sounds on)
SND_START=$(conf sound_start /System/Library/Sounds/Tink.aiff)
SND_DONE=$(conf sound_done /System/Library/Sounds/Pop.aiff)
SND_ERROR=$(conf sound_error /System/Library/Sounds/Basso.aiff)
SND_VOL=$(conf sound_volume 0.35)
HISTORY=$(conf history on)
[ -n "${AITEXT_SOUNDS:-}" ] && SOUNDS="$AITEXT_SOUNDS"
[ -n "$BATCH" ] && SOUNDS=off

play() {  # fire-and-forget; detached so it survives this script exiting
  case "$SOUNDS" in on|1|true|yes) ;; *) return 0 ;; esac
  [ -f "$1" ] || return 0
  ( afplay -v "$SND_VOL" "$1" >/dev/null 2>&1 & ) >/dev/null 2>&1
}

alert() {  # alert <mode> <message>
  if [ -n "$BATCH" ]; then
    printf 'aitext %s: %s\n' "$1" "$2" >&2
    return 0
  fi
  osascript - "aitext: $1" "$2" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  display alert (item 1 of argv) message (item 2 of argv)
end run
APPLESCRIPT
}

# history: one JSON line per event, capped so it never grows unbounded.
# Stores your text in plain text — disable with: aitext-config set history off
hist() {  # hist <status> <output-or-error>
  case "$HISTORY" in on|1|true|yes) ;; *) return 0 ;; esac
  command -v jq >/dev/null 2>&1 || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  local f="$STATE_DIR/history.jsonl" n tmp
  jq -cn --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" --arg mode "$MODE" \
     --arg status "$1" --arg input "$TEXT" --arg output "$2" \
     '{ts:$ts, mode:$mode, status:$status, input:$input, output:$output}' >> "$f" 2>/dev/null
  n=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
  if [ "${n:-0}" -gt 300 ]; then
    tmp=$(mktemp) && tail -n 200 "$f" > "$tmp" && mv "$tmp" "$f"
  fi
}

die() {
  play "$SND_ERROR"
  hist error "$1"
  alert "$MODE" "$1"
  printf '%s' "$TEXT"
  if [ -n "$BATCH" ]; then exit 1; else exit 0; fi
}

command -v jq >/dev/null         || die "jq not found. Run: brew install jq"
[[ -f "$PROMPT_FILE" ]]          || die "No prompt named '$MODE' in $PROMPT_DIR"
[[ -n "${TEXT//[[:space:]]/}" ]] || die "Nothing selected."

HEADER=$(awk '/^---[[:space:]]*$/{exit} {print}' "$PROMPT_FILE")
SYSTEM=$(awk 'f{print} /^---[[:space:]]*$/{f=1}' "$PROMPT_FILE")
field() { printf '%s\n' "$HEADER" | sed -n "s/^$1:[[:space:]]*//p" | head -1; }

PROVIDER=$(field provider); PROVIDER="${PROVIDER:-openai}"
MODEL=$(field model)
TEMP=$(field temperature)   # empty = omit from the request (use the API default)
[ -z "$TEMP" ] || printf '%s' "$TEMP" | grep -qE '^[0-9]+(\.[0-9]+)?$' \
  || die "temperature '$TEMP' in $PROMPT_FILE is not a number"
OUT=$(field output);        OUT="${OUT:-replace}"
BASE_URL=$(field base_url)
ASK=$(field ask)

# per-prompt sound override, then environment wins over everything
PROMPT_SOUNDS=$(field sounds); [ -n "$PROMPT_SOUNDS" ] && SOUNDS="$PROMPT_SOUNDS"
[ -n "${AITEXT_SOUNDS:-}" ] && SOUNDS="$AITEXT_SOUNDS"
[ -n "$BATCH" ] && SOUNDS=off

# Interactive prompt: an `ask:` line means the instruction comes from the user
# at invocation time — via $AITEXT_INSTRUCTION, or a dialog. Cancelling the
# dialog quietly hands the selection back untouched.
if [ -n "$ASK" ]; then
  INSTRUCTION="${AITEXT_INSTRUCTION:-}"
  if [ -z "$INSTRUCTION" ]; then
    [ -n "$BATCH" ] && die "interactive mode — set AITEXT_INSTRUCTION to use '$MODE' in scripts"
    INSTRUCTION=$(osascript - "$ASK" 2>/dev/null <<'APPLESCRIPT'
on run argv
  try
    set r to display dialog (item 1 of argv) default answer "" buttons {"Cancel", "Apply"} default button "Apply" with title "aitext"
    if button returned of r is "Apply" then return text returned of r
  end try
end run
APPLESCRIPT
)
    if [ -z "${INSTRUCTION//[[:space:]]/}" ]; then
      printf '%s' "$TEXT"; exit 0   # cancelled
    fi
  fi
  SYSTEM="Instruction from the user: $INSTRUCTION"$'\n\n'"$SYSTEM"
fi

SYSTEM="$SYSTEM"$'\n\n''Return ONLY the resulting text. No preamble, no explanation, no surrounding quotes, no code fences. Preserve the input language, line breaks, markdown, code blocks, URLs and proper nouns.'

mkdir -p "$STATE_DIR" && printf '%s' "$TEXT" > "$STATE_DIR/last-input.txt"

play "$SND_START"

case "$PROVIDER" in
  openai)
    MODEL="${MODEL:-gpt-5.4-nano}"
    DEFAULT_BASE="https://api.openai.com/v1"
    BASE="${BASE_URL:-$(conf openai_base_url "$DEFAULT_BASE")}"
    BASE="${BASE%/}"
    KEY=$(security find-generic-password -s OPENAI_API_KEY -w 2>/dev/null) || KEY=""
    # A custom endpoint (Ollama, LM Studio, …) may not need a key; the real API does.
    if [ -z "$KEY" ] && [ "$BASE" = "$DEFAULT_BASE" ]; then
      die "OPENAI_API_KEY not found in Keychain."
    fi
    REQ=$(jq -n --arg m "$MODEL" --arg s "$SYSTEM" --arg u "$TEXT" \
      '{model:$m, messages:[{role:"system",content:$s},{role:"user",content:$u}]}')
    # some models (e.g. gpt-5.6-luna) reject non-default temperature — only
    # send the field when the prompt file asks for one
    [ -n "$TEMP" ] && REQ=$(jq --argjson t "$TEMP" '. + {temperature:$t}' <<<"$REQ")
    if [ -n "$KEY" ]; then
      RESP=$(curl -sS --max-time 60 "$BASE/chat/completions" \
        --config <(printf 'header = "Authorization: Bearer %s"\n' "$KEY") \
        -H "Content-Type: application/json" -d "$REQ") \
        || die "Network error talking to $BASE."
    else
      RESP=$(curl -sS --max-time 60 "$BASE/chat/completions" \
        -H "Content-Type: application/json" -d "$REQ") \
        || die "Network error talking to $BASE."
    fi
    ERR=$(jq -r 'if (.error|type)=="object" then .error.message elif (.error|type)=="string" then .error else empty end' <<<"$RESP" 2>/dev/null) \
      || die "Unparseable response from $BASE."
    [[ -z "$ERR" ]] || die "API: $ERR"
    RESULT=$(jq -r '.choices[0].message.content // empty' <<<"$RESP" 2>/dev/null)
    ;;
  anthropic)
    MODEL="${MODEL:-claude-haiku-4-5}"
    KEY=$(security find-generic-password -s ANTHROPIC_API_KEY -w 2>/dev/null) \
      || die "ANTHROPIC_API_KEY not found in Keychain."
    REQ=$(jq -n --arg m "$MODEL" --arg s "$SYSTEM" --arg u "$TEXT" \
      '{model:$m, max_tokens:4096, system:$s, messages:[{role:"user",content:$u}]}')
    RESP=$(curl -sS --max-time 60 https://api.anthropic.com/v1/messages \
      --config <(printf 'header = "x-api-key: %s"\n' "$KEY") \
      -H "anthropic-version: 2023-06-01" \
      -H "Content-Type: application/json" -d "$REQ") \
      || die "Network error talking to Anthropic."
    ERR=$(jq -r '.error.message // empty' <<<"$RESP" 2>/dev/null) \
      || die "Unparseable response from Anthropic."
    [[ -z "$ERR" ]] || die "Anthropic: $ERR"
    RESULT=$(jq -r '[.content[]? | select(.type=="text") | .text] | join("")' <<<"$RESP" 2>/dev/null)
    ;;
  *) die "Unknown provider '$PROVIDER' in $PROMPT_FILE" ;;
esac

[[ -n "${RESULT//[[:space:]]/}" ]] || die "Empty response from $PROVIDER."

# Models sometimes wrap the answer in a fence even when told not to — but if
# the input itself began with a fence, a fenced result is legitimate content.
if [[ "$TEXT" != '```'* && "$RESULT" == '```'* && "$RESULT" == *'```' ]]; then
  RESULT="${RESULT#*$'\n'}"; RESULT="${RESULT%$'\n''```'}"
fi

play "$SND_DONE"
hist ok "$RESULT"

[ -n "$BATCH" ] && OUT=replace

case "$OUT" in
  append)    printf '%s\n\n%s' "$TEXT" "$RESULT" ;;
  clipboard) printf '%s' "$RESULT" | pbcopy; printf '%s' "$TEXT" ;;
  notify)    alert "$MODE" "$RESULT"; printf '%s' "$TEXT" ;;
  *)         printf '%s' "$RESULT" ;;
esac
AITEXT_EOF
chmod +x "$BIN_DIR/aitext"
ok "$BIN_DIR/aitext"

cat > "$BIN_DIR/aitext-config" <<'AITEXT_CONFIG_EOF'
#!/usr/bin/env bash
# shellcheck disable=SC2034  # DEFAULT_* vars are read via eval in default_for()
# aitext-config — global settings for aitext (~/.config/aitext/config).
#
#   aitext-config                  show every setting and where it came from
#   aitext-config sounds off       shorthand for: set sounds off
#   aitext-config get <key>
#   aitext-config set <key> <value>
#   aitext-config test             play the three sounds so you can hear them
#
# Keys:
#   sounds         on | off        audio cue on start, finish and failure
#   sound_start    path to .aiff   played when the API call begins
#   sound_done     path to .aiff   played when the result is ready
#   sound_error    path to .aiff   played when something failed
#   sound_volume   0.0 – 1.0
#   history        on | off        log transforms for aitext-log (plain text!)
#   openai_base_url  URL           OpenAI-compatible endpoint, e.g. a local
#                                  Ollama: http://localhost:11434/v1
#
# Precedence: $AITEXT_SOUNDS  >  a `sounds:` line in the prompt file  >  this file.

set -uo pipefail

CONF_DIR="${AITEXT_CONF_DIR:-$HOME/.config/aitext}"
CONF_FILE="$CONF_DIR/config"

die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }

DEFAULT_sounds=on
DEFAULT_sound_start=/System/Library/Sounds/Tink.aiff
DEFAULT_sound_done=/System/Library/Sounds/Pop.aiff
DEFAULT_sound_error=/System/Library/Sounds/Basso.aiff
DEFAULT_sound_volume=0.35
DEFAULT_history=on
DEFAULT_openai_base_url=https://api.openai.com/v1
KEYS="sounds sound_start sound_done sound_error sound_volume history openai_base_url"

default_for() { eval "printf '%s' \"\${DEFAULT_$1}\""; }

raw_get() {
  [ -f "$CONF_FILE" ] || return 1
  local v; v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF_FILE" | tail -1)
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

get() { raw_get "$1" 2>/dev/null || default_for "$1"; }

valid_key() {
  case " $KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

validate() {  # validate <key> <value>
  case "$1" in
    sounds|history)
      case "$2" in on|off) ;; *) die "$1 must be 'on' or 'off'" ;; esac ;;
    openai_base_url)
      printf '%s' "$2" | grep -qE '^https?://[^[:space:]]+$' || die "openai_base_url must be an http(s):// URL" ;;
    sound_start|sound_done|sound_error)
      [ -f "$2" ] || die "no such file: $2   (try: ls /System/Library/Sounds)" ;;
    sound_volume)
      printf '%s' "$2" | grep -qE '^(0(\.[0-9]+)?|1(\.0+)?)$' || die "sound_volume must be between 0.0 and 1.0" ;;
  esac
}

cmd_set() {
  local key="${1:-}" val="${2:-}"
  [ -n "$key" ] && [ -n "$val" ] || die "usage: aitext-config set <key> <value>"
  valid_key "$key" || die "unknown key '$key' — valid: $KEYS"
  validate "$key" "$val"

  mkdir -p "$CONF_DIR"
  if [ ! -f "$CONF_FILE" ]; then
    printf '# aitext settings — see: aitext-config --help\n' > "$CONF_FILE"
  fi
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$CONF_FILE"; then
    local tmp; tmp=$(mktemp)
    awk -v k="$key" -v v="$val" '
      $0 ~ "^[[:space:]]*"k"[[:space:]]*=" { print k"="v; done=1; next }
      { print }
      END { if (!done) print k"="v }' "$CONF_FILE" > "$tmp" && mv "$tmp" "$CONF_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CONF_FILE"
  fi
  ok "$key = $val"
}

cmd_get() {
  local key="${1:-}"
  [ -n "$key" ] || die "usage: aitext-config get <key>"
  valid_key "$key" || die "unknown key '$key' — valid: $KEYS"
  get "$key"; echo
}

cmd_list() {
  printf '\033[1m%-14s %-38s %s\033[0m\n' KEY VALUE SOURCE
  local k v src
  for k in $KEYS; do
    if v=$(raw_get "$k" 2>/dev/null); then src="config file"; else v=$(default_for "$k"); src="default"; fi
    [ "$k" = "sounds" ] && [ -n "${AITEXT_SOUNDS:-}" ] && { v="$AITEXT_SOUNDS"; src="\$AITEXT_SOUNDS"; }
    printf '%-14s %-38s \033[90m%s\033[0m\n' "$k" "$v" "$src"
  done
  printf '\n\033[90mFile: %s%s\033[0m\n' "$CONF_FILE" \
    "$([ -f "$CONF_FILE" ] || printf ' (not created yet — all defaults)')"
  # shellcheck disable=SC2016  # backticks here are literal markdown, not expansion
  printf '\033[90mPer-prompt override: add a `sounds: off` line to a prompt file.\033[0m\n'
}

cmd_test() {
  local vol; vol=$(get sound_volume)
  local k f
  for k in sound_start sound_done sound_error; do
    f=$(get "$k")
    printf '  %-12s %s\n' "$k" "$f"
    if [ -f "$f" ]; then afplay -v "$vol" "$f" 2>/dev/null; sleep 0.4; else printf '    \033[31mmissing\033[0m\n'; fi
  done
  [ "$(get sounds)" = "on" ] || printf '\n\033[33m!\033[0m sounds are currently OFF — aitext will stay silent.\n'
}

case "${1:-list}" in
  list|ls|"")     cmd_list ;;
  get)            shift; cmd_get "$@" ;;
  set)            shift; cmd_set "$@" ;;
  test)           cmd_test ;;
  sounds)         shift; [ $# -ge 1 ] || die "usage: aitext-config sounds on|off"; cmd_set sounds "$1" ;;
  -h|--help|help) awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0" ;;
  *)              die "unknown command '$1' (try: aitext-config --help)" ;;
esac
AITEXT_CONFIG_EOF
chmod +x "$BIN_DIR/aitext-config"
ok "$BIN_DIR/aitext-config"

cat > "$BIN_DIR/aitext-keys" <<'AITEXT_KEYS_EOF'
#!/usr/bin/env bash
# aitext-keys — inspect and change the hotkeys bound to aitext Quick Actions.
#
#   aitext-keys                 list current bindings
#   aitext-keys set <mode> <combo>
#   aitext-keys unset <mode>    remove the shortcut (Quick Action stays)
#
# <combo> accepts any of:  shift+ctrl+j   ⇧⌃J   ctrl-shift-j   '$^j'
# Modifiers: cmd/command, shift, ctrl/control, opt/option/alt.

set -uo pipefail

PB=/usr/libexec/PlistBuddy
PLIST="$HOME/Library/Preferences/pbs.plist"
SERVICES="$HOME/Library/Services"
RESERVED="a b e f n p v"

die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
keypath() { printf ":NSServicesStatus:'(null) - %s - runWorkflowAsService'" "$1"; }

rows() {
  local w cmd mode name
  for w in "$SERVICES"/*.workflow; do
    [ -d "$w" ] || continue
    cmd=$("$PB" -c "Print :actions:0:action:ActionParameters:COMMAND_STRING" \
          "$w/Contents/document.wflow" 2>/dev/null) || continue
    case "$cmd" in *"/aitext"*) ;; *) continue ;; esac
    mode=${cmd##* }
    name=$(basename "$w" .workflow)
    printf '%s\t%s\n' "$mode" "$name"
  done | sort
}

name_for() {
  local want="$1" mode name
  while IFS=$'\t' read -r mode name; do
    [ "$mode" = "$want" ] && { printf '%s' "$name"; return 0; }
  done < <(rows)
  return 1
}

get_key() { "$PB" -c "Print $(keypath "$1"):key_equivalent" "$PLIST" 2>/dev/null; }

pretty() {
  printf '%s' "$1" \
    | sed 's/@/⌘/g; s/\$/⇧/g; s/\^/⌃/g; s/~/⌥/g' \
    | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
}

parse_combo() {
  local raw="$1"
  case "$raw" in
    [@'$^~']*) if printf '%s' "$raw" | grep -qE '^[@$^~]+[a-z0-9]$'; then printf '%s' "$raw"; return 0; fi ;;
  esac
  local s
  s=$(printf '%s' "$raw" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
  s=${s//⌘/cmd+}; s=${s//⇧/shift+}; s=${s//⌃/ctrl+}; s=${s//⌥/opt+}
  s=${s//-/+}; s=${s//,/+}; s=${s// /+}
  local cmd=0 sh=0 ct=0 op=0 letter="" part
  local IFS='+'
  for part in $s; do
    case "$part" in
      cmd|command|@)      cmd=1 ;;
      shift|'$')          sh=1 ;;
      ctrl|control|ctl|^) ct=1 ;;
      opt|option|alt|'~') op=1 ;;
      "")                 ;;
      ?)                  letter="$part" ;;
      *)                  die "don't understand '$part' in '$raw'" ;;
    esac
  done
  [ -n "$letter" ] || die "no key letter in '$raw'"
  printf '%s' "$letter" | grep -qE '^[a-z0-9]$' || die "key must be a single letter or digit, got '$letter'"
  [ $((cmd + sh + ct + op)) -gt 0 ] || die "need at least one modifier in '$raw'"
  local out=""
  [ $cmd -eq 1 ] && out="$out@"
  [ $sh  -eq 1 ] && out="$out\$"
  [ $ct  -eq 1 ] && out="$out^"
  [ $op  -eq 1 ] && out="$out~"
  printf '%s%s' "$out" "$letter"
}

flush() {
  killall -u "$USER" cfprefsd 2>/dev/null
  /System/Library/CoreServices/pbs -flush 2>/dev/null
}

cmd_list() {
  local mode name key n=0
  printf '\033[1m%-10s %-26s %s\033[0m\n' MODE "SERVICE" "SHORTCUT"
  while IFS=$'\t' read -r mode name; do
    key=$(get_key "$name")
    if [ -n "$key" ]; then
      printf '%-10s %-26s %s\n' "$mode" "$name" "$(pretty "$key")"
    else
      printf '%-10s %-26s \033[90m(none)\033[0m\n' "$mode" "$name"
    fi
    n=$((n + 1))
  done < <(rows)
  [ "$n" -gt 0 ] || echo "  no aitext Quick Actions found in $SERVICES"
  printf '\n\033[90mReserved with ⇧⌃ (macOS text selection): %s\033[0m\n' "$(printf '%s' "$RESERVED" | tr '[:lower:]' '[:upper:]')"
}

cmd_set() {
  local mode="${1:-}" combo="${2:-}"
  [ -n "$mode" ] && [ -n "$combo" ] || die "usage: aitext-keys set <mode> <combo>"
  local name; name=$(name_for "$mode") || die "no Quick Action for mode '$mode' (see: aitext-keys)"
  local key;  key=$(parse_combo "$combo") || exit 1
  local letter=${key#"${key%?}"}
  if [ "${key%?}" = "\$^" ] || [ "${key%?}" = "^\$" ]; then
    case " $RESERVED " in
      *" $letter "*) printf '\033[33m!\033[0m ⇧⌃%s is reserved by macOS for text selection — it will not fire in most apps.\n' \
                       "$(printf '%s' "$letter" | tr '[:lower:]' '[:upper:]')" ;;
    esac
  fi
  local other
  other=$("$PB" -c "Print :NSServicesStatus" "$PLIST" 2>/dev/null \
          | grep -B20 "key_equivalent = $(printf '%s' "$key" | sed 's/[][\.*^$/]/\\&/g')\$" \
          | grep -o "(null) - [^-]* - runWorkflowAsService" | tail -1 | sed 's/(null) - //;s/ - runWorkflowAsService//')
  if [ -n "$other" ] && [ "$other" != "$name" ]; then
    printf '\033[33m!\033[0m %s already uses %s — both will be ambiguous.\n' "$other" "$(pretty "$key")"
  fi
  local k; k=$(keypath "$name")
  "$PB" -c "Delete $k" "$PLIST" >/dev/null 2>&1
  "$PB" -c "Add $k dict" "$PLIST" >/dev/null 2>&1
  "$PB" -c "Add $k:key_equivalent string $key" "$PLIST" >/dev/null 2>&1
  "$PB" -c "Add $k:enabled_services_menu bool true" "$PLIST" >/dev/null 2>&1
  "$PB" -c "Add $k:enabled_context_menu bool true" "$PLIST" >/dev/null 2>&1
  "$PB" -c "Set :ServicesShortcutsPresent 1" "$PLIST" >/dev/null 2>&1 \
    || "$PB" -c "Add :ServicesShortcutsPresent integer 1" "$PLIST" >/dev/null 2>&1
  flush
  printf '\033[32m✓\033[0m %s (%s) → %s\n' "$name" "$mode" "$(pretty "$key")"
  printf '\033[90m  Note: re-running install.sh resets this unless you edit its MANIFEST.\033[0m\n'
}

cmd_unset() {
  local mode="${1:-}"
  [ -n "$mode" ] || die "usage: aitext-keys unset <mode>"
  local name; name=$(name_for "$mode") || die "no Quick Action for mode '$mode'"
  "$PB" -c "Delete $(keypath "$name")" "$PLIST" >/dev/null 2>&1
  flush
  printf '\033[32m✓\033[0m %s (%s) → no shortcut (still in the Services menu)\n' "$name" "$mode"
}

case "${1:-list}" in
  list|ls|"")      cmd_list ;;
  set)             shift; cmd_set "$@" ;;
  unset|rm|delete) shift; cmd_unset "$@" ;;
  -h|--help|help)  awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0" ;;
  *)               die "unknown command '$1' (try: aitext-keys --help)" ;;
esac
AITEXT_KEYS_EOF
chmod +x "$BIN_DIR/aitext-keys"
ok "$BIN_DIR/aitext-keys"

cat > "$BIN_DIR/aitext-log" <<'AITEXT_LOG_EOF'
#!/usr/bin/env bash
# aitext-log — browse the transform history (undo beyond ⌘Z).
#
#   aitext-log              list recent transforms, newest first
#   aitext-log show <n>     full input and output of entry n (1 = newest)
#   aitext-log copy <n>     put entry n's OUTPUT on the clipboard
#   aitext-log restore <n>  put entry n's INPUT on the clipboard (the original)
#   aitext-log clear        delete the history
#
# History is written by aitext on every call (capped at ~200 entries) and
# stores your text in plain text. Turn it off: aitext-config set history off

set -uo pipefail

STATE_DIR="${AITEXT_STATE:-$HOME/.local/state/aitext}"
HIST="$STATE_DIR/history.jsonl"

die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
ok()  { printf '\033[32m✓\033[0m %s\n' "$*"; }

have_history() { [ -s "$HIST" ]; }

entry() {  # entry <n> — print the nth-newest JSON line
  local n="$1"
  printf '%s' "$n" | grep -qE '^[0-9]+$' || die "n must be a number (1 = newest)"
  [ "$n" -ge 1 ] || die "n must be 1 or more"
  local total; total=$(wc -l < "$HIST" | tr -d ' ')
  [ "$n" -le "$total" ] || die "only $total entries (1 = newest)"
  tail -n "$n" "$HIST" | head -1
}

cmd_list() {
  have_history || { echo "No history yet — run a transform first. (File: $HIST)"; exit 0; }
  printf '\033[1m%3s  %-19s %-9s %-4s %-34s %s\033[0m\n' N WHEN MODE OK INPUT OUTPUT
  tail -n 20 "$HIST" | jq -r '[.ts, .mode, .status, .input, .output] | @tsv' \
    | awk -F'\t' '{ lines[NR]=$0 } END { for (i=NR; i>=1; i--) print lines[i] }' \
    | awk -F'\t' '{
        gsub(/\\t/, " ", $4); gsub(/\\n/, " ", $4)
        gsub(/\\t/, " ", $5); gsub(/\\n/, " ", $5)
        inp = length($4) > 32 ? substr($4, 1, 31) "…" : $4
        out = length($5) > 40 ? substr($5, 1, 39) "…" : $5
        okc = ($3 == "ok") ? "✓" : "✗"
        printf "%3d  %-19s %-9s %-4s %-34s %s\n", NR, $1, $2, okc, inp, out
      }'
  local total; total=$(wc -l < "$HIST" | tr -d ' ')
  printf '\n\033[90m%s entries total. aitext-log show <n> for full text; restore <n> puts the original on the clipboard.\033[0m\n' "$total"
}

cmd_show() {
  have_history || die "no history"
  local e; e=$(entry "${1:-1}") || exit 1 || exit 1 || exit 1
  printf '\033[1mwhen:\033[0m   %s\n' "$(jq -r '.ts'     <<<"$e")"
  printf '\033[1mmode:\033[0m   %s\n' "$(jq -r '.mode'   <<<"$e")"
  printf '\033[1mstatus:\033[0m %s\n' "$(jq -r '.status' <<<"$e")"
  printf '\n\033[1m--- input ---\033[0m\n%s\n'  "$(jq -r '.input'  <<<"$e")"
  printf '\n\033[1m--- output ---\033[0m\n%s\n' "$(jq -r '.output' <<<"$e")"
}

cmd_copy() {
  have_history || die "no history"
  local e; e=$(entry "${1:-1}")
  [ "$(jq -r '.status' <<<"$e")" = "ok" ] || die "entry ${1:-1} is an error record — its 'output' is the error message"
  jq -rj '.output' <<<"$e" | pbcopy
  ok "output of entry ${1:-1} is on the clipboard"
}

cmd_restore() {
  have_history || die "no history"
  local e; e=$(entry "${1:-1}")
  jq -rj '.input' <<<"$e" | pbcopy
  ok "ORIGINAL input of entry ${1:-1} is on the clipboard — paste it wherever the text was"
}

cmd_clear() {
  rm -f "$HIST"
  ok "history cleared"
}

case "${1:-list}" in
  list|ls|"")     cmd_list ;;
  show)           shift; cmd_show "$@" ;;
  copy)           shift; cmd_copy "$@" ;;
  restore)        shift; cmd_restore "$@" ;;
  clear)          cmd_clear ;;
  -h|--help|help) awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0" ;;
  *)              die "unknown command '$1' (try: aitext-log --help)" ;;
esac
AITEXT_LOG_EOF
chmod +x "$BIN_DIR/aitext-log"
ok "$BIN_DIR/aitext-log"

cat > "$BIN_DIR/aitext-service" <<'AITEXT_SERVICE_EOF'
#!/usr/bin/env bash
# aitext-service — create or remove a single aitext Quick Action bundle.
#
#   aitext-service build <mode> <Menu Name>
#   aitext-service remove <Menu Name>
#
# Used by install.sh and aitext-prompts so the bundle format lives in one place.

set -uo pipefail

SERVICES="$HOME/Library/Services"
ACTION_BUNDLE="/System/Library/Automator/Run Shell Script.action"

die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

build() {
  local mode="${1:-}" name="${2:-}"
  [ -n "$mode" ] && [ -n "$name" ] || die "usage: aitext-service build <mode> <Menu Name>"
  printf '%s' "$mode" | grep -qE '^[a-z0-9_-]+$' \
    || die "mode must be lowercase letters, digits, - or _ (got '$mode')"
  case "$name" in
    *[\&\<\>\|]*|*"'"*) die "menu name cannot contain & < > | or ' (got '$name')" ;;
  esac
  [ -d "$ACTION_BUNDLE" ] || die "missing $ACTION_BUNDLE"

  local w="$SERVICES/$name.workflow" c
  c="$w/Contents"
  rm -rf "$w"; mkdir -p "$c" || die "cannot write to $SERVICES"

  cat > "$c/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>NSServices</key><array><dict>
    <key>NSMenuItem</key><dict><key>default</key><string>$name</string></dict>
    <key>NSMessage</key><string>runWorkflowAsService</string>
    <key>NSSendTypes</key><array><string>NSStringPboardType</string></array>
    <key>NSReturnTypes</key><array><string>NSStringPboardType</string></array>
  </dict></array>
</dict></plist>
PLIST

  cat > "$c/document.wflow" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>AMApplicationBuild</key><string>528</string>
  <key>AMApplicationVersion</key><string>2.10</string>
  <key>AMDocumentVersion</key><string>2</string>
  <key>actions</key><array><dict>
    <key>action</key><dict>
      <key>AMActionVersion</key><string>2.0.3</string>
      <key>AMParameterProperties</key><dict>
        <key>COMMAND_STRING</key><dict/>
        <key>CheckedForUserDefaultShell</key><dict/>
        <key>inputMethod</key><dict/>
        <key>shell</key><dict/>
        <key>source</key><dict/>
      </dict>
      <key>ActionBundlePath</key><string>$ACTION_BUNDLE</string>
      <key>ActionName</key><string>Run Shell Script</string>
      <key>ActionParameters</key><dict>
        <key>COMMAND_STRING</key><string>exec "\$HOME/.local/bin/aitext" $mode</string>
        <key>CheckedForUserDefaultShell</key><true/>
        <key>inputMethod</key><integer>0</integer>
        <key>shell</key><string>/bin/bash</string>
        <key>source</key><string></string>
      </dict>
      <key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
      <key>CFBundleVersion</key><string>2.0.3</string>
      <key>CanShowSelectedItemsWhenRun</key><false/>
      <key>CanShowWhenRun</key><true/>
      <key>Category</key><array><string>AMCategoryUtilities</string></array>
      <key>Class Name</key><string>RunShellScriptAction</string>
      <key>InputUUID</key><string>$(uuidgen)</string>
      <key>OutputUUID</key><string>$(uuidgen)</string>
      <key>UUID</key><string>$(uuidgen)</string>
      <key>UnlocalizedApplications</key><array><string>Automator</string></array>
      <key>arguments</key><dict/>
      <key>isViewVisible</key><integer>1</integer>
      <key>location</key><string>309.000000:253.000000</string>
    </dict>
    <key>isViewVisible</key><integer>1</integer>
  </dict></array>
  <key>connectors</key><dict/>
  <key>workflowMetaData</key><dict>
    <key>serviceInputTypeIdentifier</key><string>com.apple.Automator.text</string>
    <key>serviceOutputTypeIdentifier</key><string>com.apple.Automator.text</string>
    <key>serviceProcessesInput</key><integer>1</integer>
    <key>serviceApplicationBundleID</key><string></string>
    <key>workflowTypeIdentifier</key><string>com.apple.Automator.servicesMenu</string>
  </dict>
</dict></plist>
PLIST

  if ! plutil -lint "$c/Info.plist" >/dev/null 2>&1 || ! plutil -lint "$c/document.wflow" >/dev/null 2>&1; then
    rm -rf "$w"; die "generated a malformed plist for '$name' — not installed"
  fi
  /System/Library/CoreServices/pbs -flush 2>/dev/null || true
}

remove() {
  local name="${1:-}"
  [ -n "$name" ] || die "usage: aitext-service remove <Menu Name>"
  rm -rf "$SERVICES/$name.workflow"
  /System/Library/CoreServices/pbs -flush 2>/dev/null || true
}

case "${1:-}" in
  build)  shift; build "$@" ;;
  remove) shift; remove "$@" ;;
  *) die "usage: aitext-service build <mode> <Menu Name> | remove <Menu Name>" ;;
esac
AITEXT_SERVICE_EOF
chmod +x "$BIN_DIR/aitext-service"
ok "$BIN_DIR/aitext-service"

cat > "$BIN_DIR/aitext-prompts" <<'AITEXT_PROMPTS_EOF'
#!/usr/bin/env bash
# aitext-prompts — manage the prompt files behind the aitext hotkeys.
#
#   aitext-prompts                     list every mode
#   aitext-prompts show <mode>         print the prompt file
#   aitext-prompts edit <mode>         open it in $EDITOR
#   aitext-prompts test <mode> [text]  run text through it, show before/after
#   aitext-prompts set <mode> <key> <value>
#                                      change a front-matter key
#                                      (model|temperature|output|provider|sounds)
#   aitext-prompts new <mode> [Menu Name] [combo]
#                                      scaffold prompt + Quick Action + hotkey
#   aitext-prompts rm <mode> [--keep-prompt]
#                                      remove hotkey, Quick Action, prompt file
#   aitext-prompts doctor              live-test every mode against its API
#
# The hotkey list lives in ~/.config/aitext/hotkeys.conf — new/rm keep it in
# sync, so re-running install.sh reproduces exactly what you have now.

set -uo pipefail

CONF_DIR="$HOME/.config/aitext"
PROMPT_DIR="$CONF_DIR/prompts"
MANIFEST="$CONF_DIR/hotkeys.conf"

die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }

need_prompt() {
  [ -f "$PROMPT_DIR/$1.md" ] || die "no prompt '$1' — see: aitext-prompts"
}

# mode|name|key rows, comments and blanks stripped
rows() { [ -f "$MANIFEST" ] && grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$MANIFEST"; }

name_for() {
  local want="$1" mode name key
  while IFS='|' read -r mode name key; do
    [ "$mode" = "$want" ] && { printf '%s' "$name"; return 0; }
  done < <(rows)
  return 1
}

field() {  # field <mode> <key>
  sed -n "/^---[[:space:]]*$/q; s/^$2:[[:space:]]*//p" "$PROMPT_DIR/$1.md" 2>/dev/null | head -1
}

body_first_line() {
  awk 'f{print; exit} /^---[[:space:]]*$/{f=1}' "$PROMPT_DIR/$1.md" 2>/dev/null
}

cmd_list() {
  local f mode model out line
  printf '\033[1m%-9s %-16s %-10s %s\033[0m\n' MODE MODEL OUTPUT "PROMPT"
  for f in "$PROMPT_DIR"/*.md; do
    [ -f "$f" ] || continue
    mode=$(basename "$f" .md)
    model=$(field "$mode" model); model=${model:-(default)}
    out=$(field "$mode" output);  out=${out:-replace}
    line=$(body_first_line "$mode")
    [ ${#line} -gt 46 ] && line="${line:0:45}…"
    printf '%-9s %-16s %-10s %s\n' "$mode" "$model" "$out" "$line"
  done
  printf '\n\033[90mFiles: %s\033[0m\n' "$PROMPT_DIR"
}

cmd_show() { need_prompt "$1"; cat "$PROMPT_DIR/$1.md"; }

cmd_edit() {
  need_prompt "$1"
  local ed="${EDITOR:-}"
  [ -n "$ed" ] || ed="open -t"
  $ed "$PROMPT_DIR/$1.md"
}

cmd_test() {
  local mode="${1:-}"; shift 2>/dev/null || true
  [ -n "$mode" ] || die "usage: aitext-prompts test <mode> [text]"
  need_prompt "$mode"
  local text="$*"
  [ -n "$text" ] || text="we was going to the store yesterday and buyed some stuff, it was quite good honestly"
  printf '\033[90min:\033[0m  %s\n' "$text"
  local outmode; outmode=$(field "$mode" output); outmode=${outmode:-replace}
  local sentinel=""
  if [ "$outmode" = "clipboard" ]; then
    sentinel="aitext-test-sentinel-$$"; printf '%s' "$sentinel" | pbcopy
  fi
  local out; out=$(printf '%s' "$text" | "$HOME/.local/bin/aitext" "$mode")
  case "$outmode" in
    clipboard)
      if [ "$(pbpaste)" = "$sentinel" ]; then
        warn "the clipboard was not updated — the call failed; an alert dialog should say why"
      else
        printf '\033[90mout:\033[0m (sent to the clipboard)\n'
        printf '\033[90mclipboard:\033[0m %s\n' "$(pbpaste)"
      fi ;;
    notify)
      printf '\033[90mout:\033[0m (shown in a dialog — check your screen)\n' ;;
    *)
      printf '\033[90mout:\033[0m %s\n' "$out"
      if [ "$out" = "$text" ]; then
        warn "output identical to input — an alert dialog should say why (missing key, bad model, network)"
      fi ;;
  esac
}

cmd_set() {
  local mode="${1:-}" key="${2:-}" val="${3:-}"
  [ -n "$mode" ] && [ -n "$key" ] && [ -n "$val" ] || die "usage: aitext-prompts set <mode> <key> <value>"
  need_prompt "$mode"
  case "$key" in
    model|temperature|output|provider|sounds) ;;
    *) die "key must be one of: model temperature output provider sounds" ;;
  esac
  case "$key" in
    output)   case "$val" in replace|append|clipboard|notify) ;; *) die "output must be replace|append|clipboard|notify" ;; esac ;;
    provider) case "$val" in openai|anthropic) ;; *) die "provider must be openai|anthropic" ;; esac ;;
    sounds)   case "$val" in on|off) ;; *) die "sounds must be on|off" ;; esac ;;
    temperature) printf '%s' "$val" | grep -qE '^([01](\.[0-9]+)?|2(\.0+)?)$' \
                   || die "temperature must be a number from 0 to 2" ;;
  esac

  local f="$PROMPT_DIR/$mode.md" tmp; tmp=$(mktemp)
  if grep -q "^$key:" "$f" && [ "$(awk "/^---[[:space:]]*\$/{exit} /^$key:/{print NR}" "$f")" != "" ]; then
    awk -v k="$key" -v v="$val" '
      !done && /^---[[:space:]]*$/ { done=1 }
      !done && $0 ~ "^"k":" { print k": "v; next }
      { print }' "$f" > "$tmp"
  else
    awk -v k="$key" -v v="$val" '
      !ins && /^---[[:space:]]*$/ { print k": "v; ins=1 }
      { print }' "$f" > "$tmp"
  fi
  mv "$tmp" "$f"
  ok "$mode: $key = $val"
  if [ "$key" = "temperature" ] && [ "$(field "$mode" provider)" = "anthropic" ]; then
    warn "this prompt uses provider: anthropic — temperature is ignored there"
  fi
}

cmd_new() {
  local mode="${1:-}" name="${2:-}" combo="${3:-}"
  [ -n "$mode" ] || die "usage: aitext-prompts new <mode> [Menu Name] [combo]"
  printf '%s' "$mode" | grep -qE '^[a-z0-9_-]+$' || die "mode must be lowercase letters, digits, - or _"
  [ -f "$PROMPT_DIR/$mode.md" ] && die "prompt '$mode' already exists — edit it with: aitext-prompts edit $mode"
  [ -n "$name" ] || name="AI $(printf '%s' "$mode" | tr '_-' '  ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')"
  case "$name" in
    *[\&\<\>\|]*|*"'"*) die "menu name cannot contain & < > | or ' (got '$name')" ;;
  esac
  name_for "$mode" >/dev/null 2>&1 && die "'$mode' is already in $MANIFEST"

  mkdir -p "$PROMPT_DIR"
  cat > "$PROMPT_DIR/$mode.md" <<EOF
temperature: 0.3
---
TODO: write the system prompt for '$mode' here. Describe the transformation to
apply to the selected text. The rule about returning only the resulting text is
appended automatically — you don't need to repeat it.
EOF
  ok "wrote $PROMPT_DIR/$mode.md"

  printf '%s|%s|%s\n' "$mode" "$name" "${combo:-}" >> "$MANIFEST"
  ok "added to $MANIFEST"

  aitext-service build "$mode" "$name" || die "could not build the Quick Action"
  ok "built Quick Action '$name'"

  if [ -n "$combo" ]; then
    if aitext-keys set "$mode" "$combo" >/dev/null 2>&1; then
      ok "bound $combo"
    else
      warn "could not bind '$combo' — set it with: aitext-keys set $mode <combo>"
      # blank the manifest field so install.sh never writes the raw text to pbs
      local tmpb; tmpb=$(mktemp)
      awk -F'|' -v m="$mode" -v n="$name" '$1==m {print m"|"n"|"; next} {print}' "$MANIFEST" > "$tmpb" && mv "$tmpb" "$MANIFEST"
    fi
    # store the normalised form back in the manifest
    local real; real=$(/usr/libexec/PlistBuddy -c \
      "Print :NSServicesStatus:'(null) - $name - runWorkflowAsService':key_equivalent" \
      "$HOME/Library/Preferences/pbs.plist" 2>/dev/null)
    if [ -n "$real" ]; then
      local tmp; tmp=$(mktemp)
      awk -F'|' -v m="$mode" -v n="$name" -v k="$real" \
        '$1==m {print m"|"n"|"k; next} {print}' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
    fi
  else
    warn "no shortcut yet — add one with: aitext-keys set $mode shift+ctrl+<letter>"
  fi

  printf '\nNext: \033[1maitext-prompts edit %s\033[0m, then \033[1maitext-prompts test %s\033[0m\n' "$mode" "$mode"
}

cmd_rm() {
  local mode="" keep=0 a
  for a in "$@"; do
    case "$a" in
      --keep-prompt) keep=1 ;;
      *) if [ -z "$mode" ]; then mode="$a"; else die "unexpected argument '$a'"; fi ;;
    esac
  done
  [ -n "$mode" ] || die "usage: aitext-prompts rm <mode> [--keep-prompt]"

  local name; name=$(name_for "$mode" 2>/dev/null) || name=""
  if [ -n "$name" ]; then
    aitext-keys unset "$mode" >/dev/null 2>&1 && ok "removed shortcut"
    aitext-service remove "$name" && ok "removed Quick Action '$name'"
    local tmp; tmp=$(mktemp)
    awk -F'|' -v m="$mode" '$1!=m' "$MANIFEST" > "$tmp" && mv "$tmp" "$MANIFEST"
    ok "removed from $MANIFEST"
  else
    warn "'$mode' was not in $MANIFEST — nothing to unbind"
  fi

  if [ $keep -eq 1 ]; then
    printf '\033[90m  kept %s/%s.md\033[0m\n' "$PROMPT_DIR" "$mode"
  elif [ -f "$PROMPT_DIR/$mode.md" ]; then
    rm -f "$PROMPT_DIR/$mode.md"; ok "deleted $PROMPT_DIR/$mode.md"
  fi
}


cmd_doctor() {
  # Run every mode against its live API with a tiny input. Catches dead models,
  # rejected parameters, bad keys — the failures that otherwise hide behind the
  # "return the original text" safety net until you press the hotkey.
  local sample="teh answr is 42"
  local f mode provider model ask out err rc pass=0 fail=0 skip=0
  printf '\033[1m%-9s %-10s %-18s %s\033[0m\n' MODE PROVIDER MODEL RESULT
  for f in "$PROMPT_DIR"/*.md; do
    [ -f "$f" ] || continue
    mode=$(basename "$f" .md)
    provider=$(field "$mode" provider); provider=${provider:-openai}
    model=$(field "$mode" model)
    [ -n "$model" ] || { [ "$provider" = "openai" ] && model="gpt-5.4-nano" || model="claude-haiku-4-5"; }
    ask=$(field "$mode" ask)
    if [ -n "$ask" ]; then
      printf '%-9s %-10s %-18s \033[90mskipped (interactive — test by hotkey)\033[0m\n' "$mode" "$provider" "$model"
      skip=$((skip+1)); continue
    fi
    if [ "$provider" = "anthropic" ] && ! security find-generic-password -s ANTHROPIC_API_KEY >/dev/null 2>&1; then
      printf '%-9s %-10s %-18s \033[90mskipped (no ANTHROPIC_API_KEY)\033[0m\n' "$mode" "$provider" "$model"
      skip=$((skip+1)); continue
    fi
    err=$(mktemp)
    out=$(printf '%s' "$sample" | AITEXT_BATCH=1 "$HOME/.local/bin/aitext" "$mode" 2>"$err"); rc=$?
    if [ $rc -eq 0 ] && [ -n "$out" ] && [ "$out" != "$sample" ]; then
      printf '%-9s %-10s %-18s \033[32m✓\033[0m %s\n' "$mode" "$provider" "$model" "$(printf '%s' "$out" | head -1 | cut -c1-40)"
      pass=$((pass+1))
    elif [ $rc -eq 0 ]; then
      printf '%-9s %-10s %-18s \033[33m?\033[0m output identical to input\n' "$mode" "$provider" "$model"
      pass=$((pass+1))
    else
      printf '%-9s %-10s %-18s \033[31m✗\033[0m %s\n' "$mode" "$provider" "$model" "$(head -1 "$err" | sed "s/^aitext $mode: //" | cut -c1-60)"
      fail=$((fail+1))
    fi
    rm -f "$err"
  done
  printf '\n%d ok, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
  [ "$fail" -eq 0 ]
}

case "${1:-list}" in
  list|ls|"")      cmd_list ;;
  show|cat)        shift; [ $# -ge 1 ] || die "usage: aitext-prompts show <mode>"; cmd_show "$1" ;;
  edit)            shift; [ $# -ge 1 ] || die "usage: aitext-prompts edit <mode>"; cmd_edit "$1" ;;
  test|try)        shift; cmd_test "$@" ;;
  set)             shift; cmd_set "$@" ;;
  new|add)         shift; cmd_new "$@" ;;
  rm|remove|del)   shift; cmd_rm "$@" ;;
  doctor|check)    cmd_doctor ;;
  -h|--help|help)  awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0" ;;
  *)               die "unknown command '$1' (try: aitext-prompts --help)" ;;
esac
AITEXT_PROMPTS_EOF
chmod +x "$BIN_DIR/aitext-prompts"
ok "$BIN_DIR/aitext-prompts"


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

write_prompt grammar <<'PROMPT_EOF'
model: gpt-5.4-nano
temperature: 0
---
You are a copy editor. Fix spelling, grammar, and punctuation. Keep the author's voice, register, and word choices — do not rewrite or "improve" phrasing that is already correct.
PROMPT_EOF

write_prompt clarify <<'PROMPT_EOF'
temperature: 0.3
---
Rewrite the text so it is clearer and tighter. Same meaning, same tone, fewer words. Break run-on sentences. Cut filler and hedging. Do not add new information.
PROMPT_EOF

write_prompt shorten <<'PROMPT_EOF'
temperature: 0.3
---
Cut the text to roughly half its length while keeping every substantive point. Prefer deleting over compressing.
PROMPT_EOF

write_prompt formal <<'PROMPT_EOF'
temperature: 0.4
---
Rewrite in a professional register suitable for business email: complete sentences, no slang, no exclamation marks, courteous but not obsequious. Keep it concise.
PROMPT_EOF

write_prompt casual <<'PROMPT_EOF'
temperature: 0.6
---
Rewrite in a warm, plain, conversational register — how a competent person would say it to a colleague. Short sentences. No corporate jargon.
PROMPT_EOF

write_prompt bullets <<'PROMPT_EOF'
temperature: 0.2
---
Convert the text into a tight bulleted list. One idea per bullet, parallel grammar, no bullet longer than two lines. Keep any existing hierarchy as nested bullets.
PROMPT_EOF

write_prompt expand <<'PROMPT_EOF'
model: gpt-5.6-luna
---
The input is rough notes. Turn them into finished prose that says exactly what the notes say — fill in connective tissue and grammar only. Invent no facts, numbers, names, or claims.
PROMPT_EOF

write_prompt tldr <<'PROMPT_EOF'
model: gpt-5.6-luna
output: append
---
Write a TL;DR of the text: at most three sentences, leading with the conclusion.
PROMPT_EOF

write_prompt en <<'PROMPT_EOF'
temperature: 0.2
---
Translate the text into natural English. Match the register of the original. Leave code, names, and technical terms untranslated. If it is already English, improve it as a native speaker would write it.
PROMPT_EOF

write_prompt hr <<'PROMPT_EOF'
temperature: 0.2
---
Translate the text into natural Croatian. Match the register of the original. Leave code, names, and established English technical terms as they are.
PROMPT_EOF

write_prompt reply <<'PROMPT_EOF'
model: gpt-5.6-luna
output: clipboard
---
The input is a message someone sent. Draft a reply to it in the same language and register: acknowledge the substance, answer any questions, and close cleanly. Keep it short. Do not invent commitments, dates, or facts — use [brackets] where the sender must fill something in.
PROMPT_EOF

write_prompt explain <<'PROMPT_EOF'
output: notify
provider: anthropic
model: claude-opus-5
---
Explain the selected text plainly: what it is, what it does or means, and anything a careful reader should notice. A few sentences at most. If it is code, say what it does and flag anything suspicious.
PROMPT_EOF

write_prompt commit <<'PROMPT_EOF'
temperature: 0.2
---
The input is a diff or a list of changes. Write a git commit message: a 50-character imperative subject line, a blank line, then 1-3 bullets on the why. No trailing period on the subject.
PROMPT_EOF

write_prompt ask <<'PROMPT_EOF'
ask: What should I do with the selected text?
---
Apply the user's instruction above to the text, and nothing else. If the instruction asks a question about the text rather than for a transformation, replace the text with the answer.
PROMPT_EOF


# Any mode listed in the manifest but missing a prompt file gets a stub, so the
# Quick Action never fires into a "no prompt named X" alert.
while IFS='|' read -r mode name key; do
  [[ -n "$mode" ]] || continue
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
  if "$BIN_DIR/aitext-service" build "$mode" "$name" 2>/dev/null; then
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
