local fs = require("fs")
local shell = require("shell")
local umu = require("umu")
local utils = require("utils")

-- The script a shortcut's exe points at.
--
-- Steam runs a non-Steam shortcut with an environment of its own making, and
-- that environment is not the one a terminal hands a program: `LD_LIBRARY_PATH`
-- is rewritten for the runtime Steam picked, `LD_PRELOAD` may be set, and
-- `XDG_RUNTIME_DIR` is often absent. legendary is a PyInstaller build, which
-- unpacks itself to a temporary directory and loads libraries by name, so it is
-- sensitive to all three in a way the plugin's own commands are not - those go
-- through `vendor.run_clean`, which drops `OPENSSL_CONF` before running
-- anything, but a shortcut is started by Steam and not by us, so nothing was
-- dropping anything on that path.
--
-- The failure this fixes is also the reason for the script to exist rather than
-- just a longer command: a non-Steam shortcut that dies gives Steam nothing to
-- report. It has no window, no console and no log - the game simply does not
-- start, and all Steam logs record is that a process appeared and went away
-- again seconds later. So the script also writes everything the program and the
-- wrapper print to a file of our own, and the plugin reads that back after a
-- launch and puts it in the log where it can be found.
--
-- Written by the plugin rather than shipped as a file: it has to name the
-- vendored binary and the log, both of which depend on where the plugin is
-- installed, and a script that was shipped and then not rewritten would be a
-- script pointing at the previous version's paths.
--
-- It is also where everything the user can change about a launch is set:
-- `PROTONPATH`, the program to run the game through, umu's game id. All of that
-- used to travel inside the shortcut's `--wrapper` argument, which is a single
-- string that legendary splits again with `shlex.split`, and every Proton build
-- on a real machine is called something with a space in it. A path with a space
-- in a string that two parsers have to agree about is a path that arrives in
-- pieces: Steam does not decode backslashes, so the escaping meant for `shlex`
-- survived as far as `shlex`, which then split `Proton - Experimental` into
-- three arguments and left `env` with a command that does not exist.
--
-- It cost far more than that, too: each of those settings was baked into every
-- shortcut's arguments, so changing one meant rewriting the whole library -
-- minutes of work, and the only window in which a game would not start, which is
-- what "changing the Proton build breaks the game" turned out to be. From here
-- it is one line, and the next launch uses it.

local launcher = {}

---Where the script is written, and where its output is collected. Next to the
---vendored binary it launches, so a plugin that moves moves both.
---@return string
local function directory()
  return utils.get_backend_path() .. "/vendor"
end

---The script's own path.
---@return string
function launcher.script_path()
  return directory() .. "/launch.sh"
end



---Where a launch's output is appended.
---
---Under the plugin's own state directory rather than beside the binary: this is
---a log, it grows, and a user's install folder is not the place for that.
---@return string
function launcher.log_path()
  return utils.get_backend_path() .. "/launch.log"
end

---Single-quote a path for the shell script below.
---
---`shell.quote` is POSIX-only and this module is loaded on Windows too, where
---nothing here is ever used: the whole file is a no-op there. Quoting is only
---reachable from the script builder, which only runs when the shortcut is being
---written, so the local implementation keeps this loadable everywhere.
---@param value string
---@return string
local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

---What a per-game program is called inside its game's own folder.
---
---A dotfile, and not the game's own name: several tools walk a game folder and
---show what is in it, and a launcher for it is none of their business.
local FOLDER_PROGRAM = ".steam-epic-play.sh"

---The name a game is given on disk, from its own title.
---
---Slug rather than the title itself: a name in the user's `bin` is a name every
---shell on the machine sees, and titles carry spaces, accents, apostrophes and
---the occasional slash. Kept short because it ends up on screen in _CIBLE_.
---@param title any
---@return string
local function slug(title)
  local name = tostring(title or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")

  if #name > 48 then
    name = name:sub(1, 48):gsub("%-+$", "")
  end

  return name ~= "" and name or "game"
end

---Whether a program on disk is already the one for this game.
---
---By what it names rather than by when it was written: two games can produce the
---same slug, and a second one silently taking the first's name would start the
---wrong game from a shortcut the user is looking at. Rewriting a file that
---already belongs to another game is the one mistake here that is invisible.
---@param path string
---@param game_id string
---@return boolean
local function belongs_to(path, game_id)
  local content = utils.read_file(path)

  return content ~= nil and content:find("--game " .. quote(game_id), 1, true) ~= nil
end

---The program one game's shortcut runs: its own name, and nothing in a box.
---
---Steam prints a shortcut's target verbatim, so every one of them read
---`steam-epic-play` - a name that says the plugin runs rather than which game,
---repeated 551 times, and the only thing a user has to go on when they open
---_Propriétés_. It now says the game.
---
---A program rather than a link to the shared script because it has to carry
---something a link cannot: which game it starts. `launch.sh` is shared by all of
---them, so the game's id used to travel in the shortcut's launch options - which
---is why that box was never empty, and why anything typed into it was gone again
---at the next sync. With one small program per game the id moves into it and the
---box belongs to the user alone.
---
---**In the game's own folder**, which is the whole of the second half of that:
---both lines of the properties dialog then read
---
---    /var/mnt/Jeux/SteamLibrary/steamapps/common/SpiderFoxflDwt/.steam-epic-play.sh
---    /var/mnt/Jeux/SteamLibrary/steamapps/common/SpiderFoxflDwt
---
---and neither of them says anything about this plugin. A dotfile, because a
---launcher sitting next to a game's data is not something it should trip over,
---and because the game folder is the only place on the machine that is already
---this game's. Two games cannot collide in it, which is why nothing has to be
---disambiguated, and uninstalling takes the file with it rather than leaving it
---in a `bin` directory for ever.
---
---`~/.local/bin` is what it falls back to for a game that is not on disk yet -
---a shortcut is made before its game is - and `epic-` in front of that name
---because `~/.local/bin` is on `PATH`: a game called _Steam_ or _ls_ must not
---become the command a shell finds first. The shared script is the last resort,
---so the worst case is the old behaviour, which starts games.
---@param game_id string Epic's own id, which is what a launch is keyed on
---@param title any The game's name, which is what the file is called
---@param install_path string|nil The game's own folder, when it is installed
---@return string path
---@return string? error
function launcher.game_program(game_id, title, install_path)
  if type(game_id) ~= "string" or game_id == "" then
    return launcher.script_path(), "no game id, so the shared script is used"
  end

  local body = table.concat({
    "#!/bin/sh",
    "# Written by the steam-epic-games plugin for " .. tostring(title or game_id) .. ".",
    "# Do not edit: this file is rewritten on every sync, and it is the whole",
    "# of what pressing play on this shortcut runs.",
    "exec " .. quote(launcher.script_path()) .. " --game " .. quote(game_id) .. ' "$@"',
    "",
  }, "\n")

  ---Write the program where it belongs, if that can be done.
  ---
  ---A write that fails is not fatal: the caller goes on to the next place, and a
  ---folder this cannot write is a folder the game was not installed into either.
  ---@param path string
  ---@return string|nil path
  local function write_at(path)
    if not utils.write_file(path, body) then
      return nil
    end

    -- Steam starts the program with `execve` and no shell, so its own bit is the
    -- only thing that makes it a program.
    shell.run("chmod", { "+x", path })

    return path
  end

  -- Trailing slash trimmed rather than tested for: every answer about a folder
  -- in this plugin has been built by joining, and one of them ending in a slash
  -- is not worth a special case.
  local folder = type(install_path) == "string" and install_path:gsub("/+$", "") or ""

  if folder ~= "" and fs.is_directory(folder) then
    local path = write_at(folder .. "/" .. FOLDER_PROGRAM)
    if path then
      return path
    end
  end

  local home = utils.getenv("HOME")
  if not home or home == "" then
    return launcher.script_path()
  end

  local directory = home .. "/.local/bin"
  local name = slug(title)
  local fingerprint = game_id:sub(1, 8)

  if not fs.create_directories(directory) then
    return launcher.script_path()
  end

  -- Three names rather than one: the plain slug, then the slug and the game's
  -- own fingerprint either way round. Stable, so a game keeps the name it was
  -- first given and the shortcuts pointing at it stay right from one sync to
  -- the next.
  for _, candidate in ipairs({
    "epic-" .. name,
    "epic-" .. name .. "-" .. fingerprint,
    "epic-" .. fingerprint .. "-" .. name,
  }) do
    local path = directory .. "/" .. candidate

    if not fs.exists(path) or belongs_to(path, game_id) then
      if utils.read_file(path) ~= body then
        local written = write_at(path)
        if written then
          return written
        end

        return launcher.script_path(), "could not write " .. path
      end

      shell.run("chmod", { "+x", path })

      return path
    end
  end

  return launcher.script_path()
end

---The script itself.
---
---Run the binary as a child rather than `exec`ing it, which is the opposite of
---the usual advice and is what makes this worth saying: legendary waits on the
---game, so this script waits on legendary, so the process Steam started stays
---alive exactly as long as the game does. That is what Steam's playtime, its
---"currently playing" state and its overlay follow. `exec` would be tidier - one
---process instead of two, the same process Steam started is the one running the
---game - but it would throw away the exit code, and the exit code is the reason
---this script is here at all: a launch that fails writes nothing to Steam's
---logs but the fact that something went away, so the one line saying how it ended
---is worth one extra process.
---
---`$@` unquoted is deliberate and wrong for a shell, right here: Steam has
---already split the launch options into arguments using its own parser, so each
---one is an argument again by the time this runs, and re-quoting them would
---pass the quotes themselves to legendary.
---
---The `--wrapper` value is *added here* rather than arriving in `"$@"`, which is
---the whole reason this file exists in its present shape. It used to travel in
---the shortcut's launch options, and that string is cut in half by Steam's own
---parser before legendary ever sees it - so every setting inside it (the Proton
---build, the program in front of the game) could only be changed by rewriting
---every shortcut in the library, which is minutes of work during which a game
---will not start, and which is what "changing the Proton build breaks the game"
---turned out to be. Written here it is one line in one file, and the next press
---of play uses it.
---
---Single-quoted because it goes through this shell and no other parser: the build
---name has a space in it and the value must arrive as one argument to legendary,
---who splits it again with `shlex` - which this quoting does not interfere with,
---because the shell has already removed the quotes by then.
---@param binary string
---@param umu_run string|nil Absolute path of umu-run, or nil to launch plainly
---@return string
local function script(binary, umu_run)
  -- The Proton lines are their own list spliced in at a known place, rather than
  -- listed inline. There are a variable number of them, and `table.unpack`
  -- *inside* a literal does not work: `table.concat` takes the function itself
  -- as one of its elements and ignores it, so the export would silently never
  -- reach the script. That is what happened the first time this was written that
  -- way, and the script looked complete because everything else in it was.
  --
  -- Position matters: before the dump below, so the diagnostic shows the value
  -- that is really in force rather than `<unset>`.
  local proton = umu.proton_exports(quote)

  -- Read once here: this is the value used when a game's own launch options box
  -- says nothing, so it is a default rather than an order.
  local default_options = umu.launch_options()

  local lines = {
    "#!/bin/sh",
    "# Written by the steam-epic-games plugin. Do not edit: it is rewritten on",
    "# every sync, and the shortcut's program is this file.",
    "#",
    "# Everything below exists to answer one question Steam cannot: why did",
    "# pressing play do nothing? A non-Steam shortcut has no window, no console",
    "# and no log of its own - Steam records that a process appeared and went",
    "# away, and nothing else. So this writes down what it can see before it does",
    "# anything, and everything the program and its wrapper print afterwards.",
    "",
    "LOG=" .. quote(launcher.log_path()),
    -- Two places, because one of them is not writable from everywhere this runs.
    -- A shortcut started inside a Proton is inside a container whose filesystem
    -- is read-only outside `/tmp` and `/run`, so the log this writes on every
    -- other launch cannot be appended to there - and a diagnosis that vanishes
    -- exactly when something went wrong is worse than no log. The fallback is
    -- the runtime directory, which is a bind of the host's and writable.
    'ALT="${XDG_RUNTIME_DIR:-/tmp}/steam-epic-play.log"',
    'say() { printf "%s\\n" "$*" >>"$LOG" 2>/dev/null || printf "%s\\n" "$*" >>"$ALT" 2>/dev/null || true; }',
    'dump_env() { env | sort | while IFS= read -r line; do say "  $line"; done; }',
    "",
    "# The environment as Steam handed it over, before anything is changed. This",
    "# cannot be reconstructed afterwards: it is the only record of what Steam",
    "# actually set, and several of these decide whether the game can run at all.",
    'say "=== $(date -Iseconds) launch started ==="',
    'say "script: $0"',
    'say "cwd: $PWD"',
    'say "argv: $*"',
    'say "--- environment as Steam gave it ---"',
    "dump_env",
    "",
    "# Which game this is, and what the user put in front of it.",
    "#",
    "# `--game <id>` is how the per-game program in the user's `bin` says which",
    "# game it starts: there is one of those per shortcut and this file is shared",
    "# by all of them. Every word after it is what the user typed into that",
    "# game's own _OPTIONS DE LANCEMENT_ box, which is theirs - the plugin writes",
    "# nothing there any more, so `mangohud=1` typed into it reaches the game.",
    'GAME=""',
    'if [ $# -ge 2 ] && [ "$1" = "--game" ]; then',
    '  GAME="$2"',
    "  shift 2",
    "fi",
    "# A shortcut from before those programs existed carries its id in its launch",
    "# options instead, as `launch <id>`. Read here rather than refused, so those",
    "# keep starting across the upgrade instead of stopping at it - and shifted off",
    "# in both cases, because what is left afterwards is what the user wrote and",
    "# nothing else: a `launch` left in it would become a program in front of the",
    "# game.",
    'if [ -z "$GAME" ] && [ $# -ge 2 ] && [ "$1" = "launch" ]; then',
    '  GAME="$2"',
    "  shift 2",
    "fi",
    "",
    "# A word is passed on only when every character in it is one a command line",
    "# can carry. The same rule the plugin applied to the value it used to write",
    "# here: these words travel through two parsers - this shell, then legendary's",
    "# `shlex.split` of the `--wrapper` string - and a value that arrives in",
    "# pieces is not a setting the user got, it is a launch that fails naming a",
    "# file that does exist.",
    "accept_word() {",
    '  case "$1" in',
    '    "") return 1 ;;',
    "    *[!A-Za-z0-9_@%+=:,.-]*) return 1 ;;",
    "  esac",
    "  return 0",
    "}",
    "",
    'options=""',
    'refused=""',
    'for word in "$@"; do',
    "# In Steam `%command%` stands for the game itself. Here the game is already",
    "# what gets run, so it is dropped rather than handed on as an argument.",
    '  if [ "$word" = "%command%" ]; then continue; fi',
    "  if accept_word \"$word\"; then",
    '    options="$options $word"',
    "  else",
    '    refused="$refused [$word]"',
    "  fi",
    "done",
    'options="${options# }"',
    "",
    'if [ -n "$refused" ]; then',
    '  say "Not passing these launch options, which cannot be passed safely:$refused"',
    "fi",
    "",
    "# What goes in front of the game: what this game's own box says, and only",
    "# when it says nothing the value the plugin keeps as a default for every",
    "# game. A word typed for one game is about that game, so it wins.",
    'if [ -z "$options" ]; then options=' .. quote(default_options or "") .. '; fi',
    'say "  game: ${GAME:-<none>}"',
    'say "  in front of the game: ${options:-<nothing>}"',
    "",
    "# Steam's own environment, minus the parts that break a PyInstaller build",
    "# and minus the OpenSSL configuration the plugin already drops everywhere",
    "# else. Removed rather than emptied: an empty variable is still a variable",
    "# that says something, and `LD_PRELOAD=` and `LD_PRELOAD` are not the same",
    "# to every loader.",
    "unset OPENSSL_CONF LD_PRELOAD LD_LIBRARY_PATH",
    "",
    "# Steam does not always set this, and a program that wants it and cannot",
    "# find it does not always cope. Pointed at the user's own runtime directory",
    "# when there is one rather than a made-up path that does not exist.",
    'if [ -z "$XDG_RUNTIME_DIR" ] && [ -d "$HOME/run" ]; then',
    '  XDG_RUNTIME_DIR="$HOME/run"',
    "fi",
    'if [ -z "$XDG_RUNTIME_DIR" ]; then',
    '  XDG_RUNTIME_DIR="$(mktemp -d)"',
    "fi",
    "export XDG_RUNTIME_DIR",
    "",
    "# Which Proton build runs the game, and in which prefix, is decided entirely",
    "# by these - and umu decides it silently, on stdout, naming the answer only",
    "# in the debug log. A diagnosis needs the resolved values rather than the",
    "# request, so they are written out before the game has had a chance to fail.",
    "# UMU_LOG is what makes umu name the Proton build and the prefix it chose.",
    "export UMU_LOG=debug",
    "",
    -- A shortcut started inside a Proton, which is what Steam's *Compatibility*
    -- tab does to a non-Steam shortcut, cannot use umu: the prefix has its own
    -- `/usr`, so a `#!/usr/bin/python3` script is not found, and `PROTONPATH`
    -- would be read by a Proton that Steam has already chosen.
    --
    -- So the game is run by the build Steam picked, with that build's own wine -
    -- which is the first thing on `PATH` inside the container, because the
    -- container was made by it. Choosing a Proton in Steam's Properties is
    -- therefore honoured rather than refused: the shortcut runs inside the tool
    -- the user asked for, and the panel's own build is what a launch uses when
    -- Compatibility says "No tool".
    --
    -- The executable is not guessed. Epic's manifests are encrypted, so only
    -- legendary can say what a game runs, and `legendary info --json` is asked
    -- once per installed game and written to a file the script can read with no
    -- JSON parser at all. Without that file the launch is refused, and says so,
    -- rather than opening a game-less prefix and reporting a crash.
    'if [ -n "$STEAM_COMPAT_DATA_PATH" ] && [ -e "$WINEPREFIX/drive_c" ]; then',
    '  say "Steam started this shortcut inside a Proton build (WINEPREFIX=$WINEPREFIX)."',
    '  exe_file=' .. quote(utils.get_backend_path() .. "/data/cache/exes") .. '/"$GAME"',
    '  if [ -f "$exe_file" ]; then',
    '    exe=$(cat "$exe_file")',
    '    say "  running: $exe"',
    '    env $options wine "$exe" >>"$LOG" 2>&1',
    "    status=$?",
    '    say "exit: $status"',
    '    say "=== finished ==="',
    "    exit $status",
    "  fi",
    '  say "No executable of $GAME is known yet; one is resolved when the library syncs."',
    '  say "Steam ran this shortcut inside a Proton, where umu cannot be used. Set"',
    '  say "Compatibility to \\"No tool\\" to launch through the plugin\'s own build."',
    "  exit 1",
    "fi",
    "",
    -- The Proton build, set here rather than in the shortcut's arguments. Every
    -- build's name has a space in it, and a value with a space in it does not
    -- survive being written into the one string that Steam's launch-options
    -- splitter and legendary's `shlex.split` both have to agree about. A shell
    -- here is one parser and one quoting style.
  }

  for _, line in ipairs(proton) do
    lines[#lines + 1] = line
  end

  table.insert(lines, "")
  table.insert(lines, 'say "--- umu configuration (resolved) ---"')

  -- The wrapper is built here, at launch, rather than written into this file:
  -- it is `env GAMEID=<id> <what this game's box says> umu-run`, and the middle
  -- of it is the user's own launch options, which can differ from one game to
  -- the next. One list rather than a line built by concatenation, because the
  -- wrapper is optional and a nil cannot go into `table.concat`: "no wrapper at
  -- all" has to be a shape this script can be written in as well as one it can
  -- be run in.
  local invocation = { quote(binary), 'launch "$GAME"' }

  if umu_run then
    lines[#lines + 1] = "UMU_ID=" .. quote(umu.umu_id())
    lines[#lines + 1] = "UMU_RUN=" .. quote(umu_run)
    lines[#lines + 1] = 'wrapper="env GAMEID=$UMU_ID"'
    lines[#lines + 1] = '[ -n "$options" ] && wrapper="$wrapper $options"'
    lines[#lines + 1] = 'wrapper="$wrapper $UMU_RUN"'
    lines[#lines + 1] = 'say "  wrapper: $wrapper"'
    invocation[#invocation + 1] = "--no-wine"
    invocation[#invocation + 1] = "--wrapper"
    invocation[#invocation + 1] = '"$wrapper"'
  end

  local rest = {
    'say "  GAMEID=${GAMEID:-<unset>}"',
    'say "  PROTONPATH=${PROTONPATH:-<unset>}"',
    'say "  WINEPREFIX=${WINEPREFIX:-<unset>}"',
    'say "  STORE=${STORE:-<unset>}"',
    'say "  XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"',
    'say "  HOME=$HOME"',
    'if command -v umu-run >/dev/null 2>&1; then',
    '  say "  umu-run: $(command -v umu-run)"',
    "else",
    '  say "  umu-run: NOT ON PATH"',
    "fi",
    -- The plugin's own record of the chosen build, not `~/.config/umu-run`:
    -- umu reads no file of its own here. It takes PROTONPATH from the
    -- environment and its TOML file only from `umu-run --config`, which this
    -- command does not use - so a setting written into a umu configuration
    -- file would change nothing while looking as though it had worked.
    'UMU_CHOICE=' .. quote(utils.get_backend_path() .. "/data/config.json"),
    'if [ -f "$UMU_CHOICE" ]; then',
    '  say "  config.json (the plugin settings, of which the build is one key):"',
    '  sed "s/^/    /" "$UMU_CHOICE" >>"$LOG" 2>&1',
    "else",
    '  say "  chosen build: none (umu uses its own default)"',
    "fi",
    "",
    "# The environment after cleaning, so the two dumps can be compared and the",
    "# effect of the lines above is visible rather than inferred.",
    'say "--- environment after cleaning ---"',
    "dump_env",
    "",
    'say "--- running ---"',
    "if [ ! -x " .. quote(binary) .. " ]; then",
    "  say " .. quote(binary) .. " is missing or not executable",
    "fi",
    'say "  $ ' .. quote(binary) .. ' launch \"$GAME\" (the wrapper is above)"',
    table.concat(invocation, " ") .. ' >>"$LOG" 2>&1',
    "status=$?",
    'say "exit: $status"',
    'say "=== finished ==="',
    "",
    "# Run rather than `exec`, so the exit code above is written down: it is the",
    "# one thing a failing shortcut can still report, and losing it to a tidier",
    "# process tree would leave nothing at all.",
    "exit $status",
    "",
  }

  return table.concat(lines, "\n") .. "\n" .. table.concat(rest, "\n")
end

---Write the script if it is missing or out of date, and make it runnable.
---
---Cheap enough to call on every sync, which is what makes it self-healing: a
---user who edited the script, or a plugin update that moved its paths, gets the
---right one back without being told to reinstall anything.
---
---The Proton build and the default words in front of the game are written in here
---too, which is what makes choosing a build take effect on the next press of play
---rather than after every shortcut in the library has been rewritten. What a
---game's own launch options box says is not written in here at all: it is read
---out of that game's own arguments when the game starts.
---@param binary string
---@param umu_run string|nil Absolute path of umu-run, or nil to launch plainly
---@return string|nil path The shared script, for a shortcut with nowhere else
---@return string? error
function launcher.ensure(binary, umu_run)
  if not binary then
    return nil, "no legendary binary to launch"
  end

  local path = launcher.script_path()
  fs.create_directories(directory())
  local wanted = script(binary, umu_run)

  if utils.read_file(path) ~= wanted then
    if not utils.write_file(path, wanted) then
      return nil, "could not write " .. path
    end
  end

  -- Steam starts the program with execve and no shell, so the script's own bit
  -- is the only thing that can make it a program. `chmod` rather than any
  -- filesystem call: this is the same way the vendored binary is made runnable,
  -- and it is a coreutils binary that is certainly there.
  shell.run("chmod", { "+x", path })

  return path
end

return launcher