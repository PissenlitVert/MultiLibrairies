#!/bin/sh
# Written by the steam-epic-games plugin. Do not edit: it is rewritten on
# every sync, and the shortcut's program is this file.
#
# Everything below exists to answer one question Steam cannot: why did
# pressing play do nothing? A non-Steam shortcut has no window, no console
# and no log of its own - Steam records that a process appeared and went
# away, and nothing else. So this writes down what it can see before it does
# anything, and everything the program and its wrapper print afterwards.

LOG='/home/Nathounette/.local/share/millennium/plugins/steam-epic-games-nathan/backend/launch.log'
ALT="${XDG_RUNTIME_DIR:-/tmp}/steam-epic-play.log"
say() { printf "%s\n" "$*" >>"$LOG" 2>/dev/null || printf "%s\n" "$*" >>"$ALT" 2>/dev/null || true; }
dump_env() { env | sort | while IFS= read -r line; do say "  $line"; done; }

# The environment as Steam handed it over, before anything is changed. This
# cannot be reconstructed afterwards: it is the only record of what Steam
# actually set, and several of these decide whether the game can run at all.
say "=== $(date -Iseconds) launch started ==="
say "script: $0"
say "cwd: $PWD"
say "argv: $*"
say "--- environment as Steam gave it ---"
dump_env

# Which game this is, and what the user put in front of it.
#
# `--game <id>` is how the per-game program in the user's `bin` says which
# game it starts: there is one of those per shortcut and this file is shared
# by all of them. Every word after it is what the user typed into that
# game's own _OPTIONS DE LANCEMENT_ box, which is theirs - the plugin writes
# nothing there any more, so `mangohud=1` typed into it reaches the game.
GAME=""
if [ $# -ge 2 ] && [ "$1" = "--game" ]; then
  GAME="$2"
  shift 2
fi
# A shortcut from before those programs existed carries its id in its launch
# options instead, as `launch <id>`. Read here rather than refused, so those
# keep starting across the upgrade instead of stopping at it - and shifted off
# in both cases, because what is left afterwards is what the user wrote and
# nothing else: a `launch` left in it would become a program in front of the
# game.
if [ -z "$GAME" ] && [ $# -ge 2 ] && [ "$1" = "launch" ]; then
  GAME="$2"
  shift 2
fi

# A word is passed on only when every character in it is one a command line
# can carry. The same rule the plugin applied to the value it used to write
# here: these words travel through two parsers - this shell, then legendary's
# `shlex.split` of the `--wrapper` string - and a value that arrives in
# pieces is not a setting the user got, it is a launch that fails naming a
# file that does exist.
accept_word() {
  case "$1" in
    "") return 1 ;;
    *[!A-Za-z0-9_@%+=:,.-]*) return 1 ;;
  esac
  return 0
}

options=""
refused=""
for word in "$@"; do
# In Steam `%command%` stands for the game itself. Here the game is already
# what gets run, so it is dropped rather than handed on as an argument.
  if [ "$word" = "%command%" ]; then continue; fi
  if accept_word "$word"; then
    options="$options $word"
  else
    refused="$refused [$word]"
  fi
done
options="${options# }"

if [ -n "$refused" ]; then
  say "Not passing these launch options, which cannot be passed safely:$refused"
fi

# What goes in front of the game: what this game's own box says, and only
# when it says nothing the value the plugin keeps as a default for every
# game. A word typed for one game is about that game, so it wins.
if [ -z "$options" ]; then options=''; fi
say "  game: ${GAME:-<none>}"
say "  in front of the game: ${options:-<nothing>}"

# Steam's own environment, minus the parts that break a PyInstaller build
# and minus the OpenSSL configuration the plugin already drops everywhere
# else. Removed rather than emptied: an empty variable is still a variable
# that says something, and `LD_PRELOAD=` and `LD_PRELOAD` are not the same
# to every loader.
unset OPENSSL_CONF LD_PRELOAD LD_LIBRARY_PATH

# Steam does not always set this, and a program that wants it and cannot
# find it does not always cope. Pointed at the user's own runtime directory
# when there is one rather than a made-up path that does not exist.
if [ -z "$XDG_RUNTIME_DIR" ] && [ -d "$HOME/run" ]; then
  XDG_RUNTIME_DIR="$HOME/run"
fi
if [ -z "$XDG_RUNTIME_DIR" ]; then
  XDG_RUNTIME_DIR="$(mktemp -d)"
fi
export XDG_RUNTIME_DIR

# Which Proton build runs the game, and in which prefix, is decided entirely
# by these - and umu decides it silently, on stdout, naming the answer only
# in the debug log. A diagnosis needs the resolved values rather than the
# request, so they are written out before the game has had a chance to fail.
# UMU_LOG is what makes umu name the Proton build and the prefix it chose.
export UMU_LOG=debug

if [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ -e "$WINEPREFIX/drive_c" ]; then
  say "Steam started this shortcut inside a Proton build (WINEPREFIX=$WINEPREFIX)."
  exe_file='/home/Nathounette/.local/share/millennium/plugins/steam-epic-games-nathan/backend/data/cache/exes'/"$GAME"
  if [ -f "$exe_file" ]; then
    exe=$(cat "$exe_file")
    say "  running: $exe"
    env $options wine "$exe" >>"$LOG" 2>&1
    status=$?
    say "exit: $status"
    say "=== finished ==="
    exit $status
  fi
  say "No executable of $GAME is known yet; one is resolved when the library syncs."
  say "Steam ran this shortcut inside a Proton, where umu cannot be used. Set"
  say "Compatibility to \"No tool\" to launch through the plugin's own build."
  exit 1
fi

# The Proton build to run the game through. Steam's compatibility setting
# is read here, at launch, rather than written into this file when the file
# was generated: the setting changes while Steam runs, and a path written
# at start-up is one decision behind.
STEAM_ROOT='/home/Nathounette/.steam/steam'
STEAM_COMPAT_VDF=$STEAM_ROOT/config/config.vdf

steam_compat_tool() {
  [ -n "$1" ] || return 0
  [ -r "$STEAM_COMPAT_VDF" ] || return 0
  command -v awk >/dev/null 2>&1 || return 0
  awk -v want="$1" '  /"CompatToolMapping"/ { mapping = 1; next }
  mapping && !found && $0 ~ "^[[:space:]]*\"" want "\"[[:space:]]*$" { found = 1; next }
  found && /"name"/ {
    sub(/^[^"]*"name"[[:space:]]*"/, "")
    sub(/".*$/, "")
    print
    exit
  }
' "$STEAM_COMPAT_VDF"
}

# This game's own entry wins over the global one, exactly as in Steam: a
# build set in a game's Properties is that game's build, and the global one
# is what the games with no entry of their own get.
steam_appid="${SteamAppId:-}"
steam_tool="$(steam_compat_tool "$steam_appid")"
steam_scope="this game (Steam app id ${steam_appid:-unknown})"
if [ -z "$steam_tool" ]; then
  steam_tool="$(steam_compat_tool 0)"
  steam_scope="every game (Steam app id 0)"
fi

# Steam's own builds are named twice: `proton_experimental` is installed as
# `Proton - Experimental`, `proton_11` as `Proton 11.0`. A build put into
# `compatibilitytools.d` by hand is spelled the same in both places, which is
# why those always worked and these never did.
steam_proton_folder() {
  case "$1" in
    proton_experimental) printf '%s\n' 'Proton - Experimental' ;;
    proton_hotfix) printf '%s\n' 'Proton Hotfix' ;;
    proton_[0-9]*) printf '%s\n' "Proton ${1#proton_}.0" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
if [ -z "$steam_tool" ]; then
  say "  Steam's compatibility tool for $steam_scope: no tool, so umu's own build runs."
  unset PROTONPATH
else
  steam_folder="$(steam_proton_folder "$steam_tool")"
  say "  Steam's compatibility tool for $steam_scope: $steam_tool, installed as $steam_folder"
  if [ -d "$STEAM_ROOT/steamapps/common/$steam_folder" ]; then
    PROTONPATH="$STEAM_ROOT/steamapps/common/$steam_folder"
  elif [ -d "$STEAM_ROOT/compatibilitytools.d/$steam_tool" ]; then
    PROTONPATH="$STEAM_ROOT/compatibilitytools.d/$steam_tool"
  else
    say "  but that build is not installed, so umu's own runs."
    unset PROTONPATH
  fi
fi
if [ -n "${PROTONPATH:-}" ]; then
  export PROTONPATH
fi

say "--- umu configuration (resolved) ---"
UMU_ID='umu-win32'
UMU_RUN='/usr/bin/umu-run'
wrapper="env GAMEID=$UMU_ID"
[ -n "$options" ] && wrapper="$wrapper $options"
wrapper="$wrapper $UMU_RUN"
say "  wrapper: $wrapper"
say "  GAMEID=${GAMEID:-<unset>}"
say "  PROTONPATH=${PROTONPATH:-<unset>}"
say "  WINEPREFIX=${WINEPREFIX:-<unset>}"
say "  STORE=${STORE:-<unset>}"
say "  XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
say "  HOME=$HOME"
if command -v umu-run >/dev/null 2>&1; then
  say "  umu-run: $(command -v umu-run)"
else
  say "  umu-run: NOT ON PATH"
fi
UMU_CHOICE='/home/Nathounette/.local/share/millennium/plugins/steam-epic-games-nathan/backend/data/config.json'
if [ -f "$UMU_CHOICE" ]; then
  say "  config.json (the plugin settings, of which the build is one key):"
  sed "s/^/    /" "$UMU_CHOICE" >>"$LOG" 2>&1
else
  say "  chosen build: none (umu uses its own default)"
fi

# The environment after cleaning, so the two dumps can be compared and the
# effect of the lines above is visible rather than inferred.
say "--- environment after cleaning ---"
dump_env

say "--- running ---"
if [ ! -x '/home/Nathounette/.local/share/millennium/plugins/steam-epic-games-nathan/backend/vendor/legendary' ]; then
  say '/home/Nathounette/.local/share/millennium/plugins/steam-epic-games-nathan/backend/vendor/legendary' is missing or not executable
fi
say "  $ '/home/Nathounette/.local/share/millennium/plugins/steam-epic-games-nathan/backend/vendor/legendary' launch "$GAME" (the wrapper is above)"
'/home/Nathounette/.local/share/millennium/plugins/steam-epic-games-nathan/backend/vendor/legendary' launch "$GAME" --no-wine --wrapper "$wrapper" >>"$LOG" 2>&1
status=$?
say "exit: $status"
say "=== finished ==="

# Run rather than `exec`, so the exit code above is written down: it is the
# one thing a failing shortcut can still report, and losing it to a tidier
# process tree would leave nothing at all.
exit $status
