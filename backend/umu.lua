local config = require("config")
local fs = require("fs")
local logger = require("logger")
local utils = require("utils")

-- Which Proton build runs the Epic games, and how that is decided.
--
-- Not Steam's job, and this is the single most misunderstood thing about a
-- non-Steam shortcut on Linux: the game's _Properties > Compatibility_ tab used
-- to be the one place where choosing a build made the game not start, because
-- anything set there makes Steam launch the shortcut *inside* that tool, and the
-- shortcut is a shell script.
--
-- That is now a supported choice rather than a trap. When Steam has started the
-- shortcut inside a build, `launch.sh` runs the game by that build's own wine,
-- so the Proton picked in Steam's Properties is the one the game runs with. See
-- `launcher`.
--
-- So the build is chosen here and handed to umu through `PROTONPATH` in the
-- environment, on the command line, at launch. Not through a configuration file
-- of umu's: its only file is the TOML one passed to `umu-run --config`, which is
-- a different thing entirely and which requires `prefix`, `proton` and `exe` to
-- all be present. There is no `~/.config/umu-run/umu.conf` that umu reads by
-- itself, and a launcher that wrote one would appear to work while changing
-- nothing at all. The setting is in the plugin's own `config.json`, written by
-- the menu or by hand.
--
-- Why this is a module rather than a line of documentation: the build a user ends
-- up on is not always one that works. A Proton build whose bundled FFmpeg does
-- not match the one its own GStreamer plugin was linked against cannot decode
-- video at all, and it fails in a way that looks like the game's fault - videos
-- that never appear and a Unity "unhandled Color Standard" message on screen.
-- Nothing in the game's own settings shows the cause, so the build is checked
-- here, where the answer can still be given.

local umu = {}

---Memoised by `umu.umu_id`: it is read while `launch.sh` is being written, which
---is once per sync over a few hundred games.
---@type string|nil
local UMU_ID = nil

---Where the chosen build is remembered: the plugin's own `config.json`.
---
---The plugin's, not umu's and not Steam's: it is a setting of the plugin, it has
---to survive the plugin being moved, and nothing else on the machine should have
---an opinion about it. It is a plain JSON key rather than a file of its own so
---that a person can open one file and see every setting the plugin has.
---@return string path
function umu.config_path()
  return config.path()
end

---The build the plugin has chosen, or nil when it follows Steam's own setting.
---
---Trimmed on the way out because a hand-edited JSON file is the likeliest place
---for a stray newline, and a build called `Proton-CachyOS Latest\n` is not
---installed on any machine.
---@return string|nil build
function umu.proton()
  local chosen = config.get("proton")

  if type(chosen) ~= "string" then
    -- A JSON document can hold anything where a string was expected, and a
    -- number or an object here would otherwise reach a path built by
    -- concatenation.
    logger:warn("The proton setting is not a string, ignoring it")
    return nil
  end

  local trimmed = utils.trim(chosen)

  return trimmed ~= "" and trimmed or nil
end

---The build a launch actually uses, and the one answer the panel shows.
---
---Steam's global compatibility tool (appid `0` in `config.vdf`), and nothing
---else: it is written into `launch.sh` as `PROTONPATH`, so the build picked in
---_Settings > Compatibility_ is the one umu uses rather than whatever umu falls
---back to on its own. `nil` when Steam is set to "no tool", and umu's own
---default runs.
---
---A tool set per game in a shortcut's Properties cannot be honoured here - it
---applies only where Steam itself starts that shortcut, which `launch.sh`
---detects at launch - and it wins there by construction, since Steam has
---already picked the build by then.
---@return string|nil build
function umu.effective_proton()
  return umu.steam_global_tool()
end

---The compatibility tool Steam applies to every game, which is not a setting of
---this plugin at all - and the reason the plugin says which build it uses.
---
---Appid `0` in Steam's mapping is Steam's global default. Set it, and Steam runs
---every non-Steam shortcut inside that tool, including ours. Nothing stops: the
---game is then run by that build, which is what setting it asks for.
---
------The one source of the build: what `effective_proton` returns and what
---`proton_exports` writes into `launch.sh`. The plugin has no build of its own
---left to disagree with it.
---@return string|nil name
function umu.steam_global_tool()
  local path = require("millennium").steam_path() .. "/config/config.vdf"
  local content = utils.read_file(path)

  if not content then
    return nil
  end

  return require("config_vdf").global_compat_tool(content)
end

---Every Proton build this machine has, newest-looking first.
---
---Two places, because Steam keeps them in both: a build installed as a
---compatibility tool lives in `compatibilitytools.d`, and one that came with
---Steam's own store download lives in `steamapps/common`.
---@return table[] builds
local function installed_builds()
  local steam = require("millennium").steam_path()
  local found = {}
  local seen = {}

  ---@param directory string
  ---@param filter fun(name: string): boolean
  local function scan(directory, filter)
    for _, entry in ipairs(fs.list(directory) or {}) do
      -- Steam downloads a compatibility tool into a hidden directory first and
      -- renames it into place afterwards, so half-downloaded builds sit beside
      -- the real ones with a name no user could pick and a path that goes away.
      if not entry.is_directory or entry.name:sub(1, 1) == "." then
        -- not a directory, or not one to offer
      elseif filter(entry.name) and not seen[entry.name] then
        seen[entry.name] = true
        found[#found + 1] = { name = entry.name, path = directory .. "/" .. entry.name }
      end
    end
  end

  scan(steam .. "/compatibilitytools.d", function(name)
    return name:lower():find("proton") ~= nil or name:lower():find("umu") ~= nil
  end)

  scan(steam .. "/steamapps/common", function(name)
    return name:lower():find("proton") ~= nil or name:lower():find("umu") ~= nil
  end)

  table.sort(found, function(a, b)
    return a.name > b.name
  end)

  return found
end

---Whether this build can decode video.
---
---A Proton build carries its own GStreamer plugins *and* the FFmpeg they were
---built against, and they have to be the same one: the plugin is linked to a
---specific `libavfilter` soname, and if the matching library is not in the build
---the plugin cannot load and there is no video decoder at all. It shows up as
---videos that never play and, for a Unity game, as
---`WindowsVideoMedia error unhandled Color Standard` - which reads like a
---graphics problem and is not one.
---
---Checked on disk rather than assumed from the build's name, because the name
---says nothing: on one machine here every build but one shipped a matching
---FFmpeg, and that one was the default.
---@param build table
---@return boolean|nil can Decode: nil when the build cannot be inspected
function umu.can_decode_video(build)
  local lib = build.path .. "/files/lib/x86_64-linux-gnu"

  if not fs.is_directory(lib) then
    return nil
  end

  -- No GStreamer plugins at all means the build defers to the host's, which is
  -- a legitimate arrangement - the host's FFmpeg is the one its plugins will be
  -- matched against - so this is not a failure.
  local plugins = lib .. "/gstreamer-1.0"
  if not fs.is_directory(plugins) then
    return nil
  end

  local entry = plugins .. "/libgstlibav.so"
  if not fs.is_file(entry) then
    return true
  end

  -- Read the soname out of the binary itself rather than parsing the ELF: the
  -- string is what the dynamic linker will look for, and it is in there as
  -- plain text.
  local bytes = utils.read_file(entry)
  if not bytes then
    return nil
  end

  local wanted = bytes:match("libavfilter%.so%.(%d+)")
  if not wanted then
    return true
  end

  if fs.is_file(lib .. "/libavfilter.so." .. wanted) then
    return true
  end

  return false
end

---The builds on this machine, each with whether it can decode video.
---
---Ordered by that first, because it is the question a menu has to answer: a
---build that cannot decode video is not a worse build, it is a build whose
---intro videos will not play and whose failure looks like the game's. The ones
---that cannot be judged go between the two rather than at the end, so a menu
---too short to show them all still leads with the ones that work.
---@return table[]
function umu.available_builds()
  local builds = installed_builds()

  for _, build in ipairs(builds) do
    build.video = umu.can_decode_video(build)
  end

  local rank = { [true] = 0 }

  table.sort(builds, function(a, b)
    local first, second = rank[a.video] or 1, rank[b.video] or 1

    if first ~= second then
      return first < second
    end

    return a.name > b.name
  end)

  return builds
end

---Remember the build to launch through. An empty name restores umu's own default.
---@param build string
---@return boolean ok
---@return string? error
function umu.set_proton(build)
  if type(build) ~= "string" then
    return false, "no build was named"
  end

  local name = utils.trim(build)

  if name == "" then
    -- Written as an empty value rather than left out: an absent key and an empty
    -- one are the same answer, and the file then shows the setting instead of
    -- hiding it.
    local ok, err = config.update({ proton = "" })
    if not ok then
      return false, err
    end
    return true
  end

  -- Checked against what is on disk: a name that is not installed is written out
  -- faithfully and then quietly ignored by umu, which is how a user ends up
  -- believing they picked something.
  local known = false
  for _, candidate in ipairs(umu.available_builds()) do
    if candidate.name == name then
      known = true
      break
    end
  end

  if not known then
    return false, name .. " is not installed on this machine"
  end

  local ok, err = config.update({ proton = name })
  if not ok then
    return false, err
  end

  return true
end

---The `PROTONPATH` value the launch command should carry, or nil for none.
---
---A full path rather than the bare name: umu accepts either, but a bare name is
---looked up in the places umu chooses to look, and one of them is a directory
---this machine does not have. The path is resolved here, from the same scan the
---menu was built from, so the name in the menu and the path in the command can
---never disagree.
---
---Takes the build by name rather than always reading the setting, so the global
---fallback in `proton_exports` can resolve Steam's own tool through the same
---scan - and a name Steam knows that we do not fails here rather than arriving
---in the script as a path that does not exist.
---@param build string|nil The build's name; nil reads the plugin's own setting
---@return string|nil path
---Steam's store builds, under the name `config.vdf` records them and the folder
---they are installed as. Lua patterns, and matched against a lower-cased name.
local STEAM_STORE_BUILDS = {
  { app = "proton_experimental", folder = "Proton - Experimental", match = "^proton %- experimental$" },
  { app = "proton_hotfix", folder = "Proton Hotfix", match = "^proton hotfix$" },
}

---`proton_11` is installed as `Proton 11.0`. The number moves with each release,
---so this matches the shape rather than a list that would be stale by next month.
---@param name string
---@return string|nil pattern
local function numbered_store_build(name)
  local number = name:match("^proton_(%d+)$")

  if not number then
    return nil
  end

  return "^proton " .. number .. "%.0$"
end

function umu.proton_path(build)
  local name = build or umu.effective_proton()

  if not name then
    return nil
  end

  local builds = umu.available_builds()

  for _, candidate in ipairs(builds) do
    if candidate.name == name then
      return candidate.path
    end
  end

  -- Steam's own builds are named twice: `config.vdf` records the internal app
  -- name, and the folder on disk is a display name. `proton_experimental` is
  -- installed as `Proton - Experimental`, and the numbered ones as `Proton 11.0`
  -- - so the name the user picked matched nothing here, the function returned
  -- nil, and umu quietly ran its own default instead. Builds put into
  -- `compatibilitytools.d` by hand are spelled the same in both places, which
  -- is why those worked and hid this.
  local pattern = numbered_store_build(name)

  for _, entry in ipairs(STEAM_STORE_BUILDS) do
    if entry.app == name then
      pattern = entry.match
    end
  end

  if pattern then
    for _, candidate in ipairs(builds) do
      if candidate.name:lower():match(pattern) then
        logger:info("Steam's \"" .. name .. "\" is installed as \"" .. candidate.name .. "\"")

        return candidate.path
      end
    end
  end

  -- One reason to be here now that the global setting is not a fallback: the
  -- build the user chose is simply not on this machine any more. Said rather
  -- than returning nil quietly, because falling back to umu's own build is how
  -- the failure this whole module exists for comes back with no explanation.
  logger:warn("The chosen Proton build is no longer installed: " .. name)

  return nil
end

---The user's own words to put in front of the game, or nil for none.
---
---`mangohud=1`, `gamemoderun`, `gamescope --fsr`: what a person types into
---Steam's own launch-options box on a Windows game. Several words, each with
---its own flags, is the point - a field that takes one bare program and refuses
---`mangohud=1` is not a launch-options field.
---
---`%command%` is accepted and dropped. In Steam it stands for the game's own
---command; here the game is always last, so the placeholder has already been
---honoured, and passing it on would hand the game a literal `%command%` as one
---of its arguments.
---
---What is refused is anything the shell would read as something other than a
---word: quotes, `$`, `;`, `&`, `|`, `<`, `>`, a backslash. The value travels
---through two parsers - this script's shell, then legendary's `shlex.split` of
---the `--wrapper` string - and a value that would arrive in pieces is not a
---setting the user got; it is a launch that fails with a message about a file
---that does exist.
---@param value any
---@return string|nil options Normalised, single-spaced, without `%command%`
---@return string? error
function umu.check_options(value)
  if type(value) ~= "string" then
    return nil, "the launch options must be text, not " .. type(value)
  end

  local trimmed = utils.trim(value)

  if trimmed == "" then
    return nil
  end

  if trimmed:find("[\"'`$\\!*?()<>|;&]") then
    return nil, "no quotes, $, ;, &, |, <, > or backslashes in the launch options"
  end

  local words = {}

  for word in trimmed:gmatch("%S+") do
    if word:lower() ~= "%command%" then
      if not word:match("^[%w_@%%+=:,%.%-]+$") then
        return nil, "unexpected character in " .. word
      end

      words[#words + 1] = word
    end
  end

  if #words == 0 then
    return nil
  end

  return table.concat(words, " ")
end

---The launch options that are actually in force, validated.
---
---The log line is here rather than only at the point of writing, because the
---value is read from a hand-edited file as often as from the panel - and a
---refused value that said nothing would leave the user believing it was set.
---@return string|nil options
function umu.launch_options()
  local options, err = umu.check_options(config.get("launch_options"))

  if err then
    logger:warn("Ignoring launch options, which cannot be passed safely: " .. tostring(err))
    return nil
  end

  if options then
    logger:info("Games will be launched through: " .. options)
  end

  return options
end

---The whole `--wrapper` value a launch script has to pass to legendary.
---
---One string, the same for every game, and that is the point: it is now written
---into `launch.sh` rather than into each shortcut's arguments, so choosing a
---different Proton build or a different program in front of the game rewrites
---one file instead of every shortcut in the library - and a launch picks it up
---on the very next press of play.
---
---`env GAMEID=<id> [program] umu-run`: the game id and the program are
---environment and prefix respectively because umu-run takes neither as an
---argument. Its synopsis is `umu-run [FILE [ARG...]]`, and the positional it does
---take is the executable to run - so an id passed there asks umu to launch a game
---called `umu-win32`, which it reports as `Executable not found: umu-win32`, and
---which Steam shows as nothing at all.
---@param umu_run string Absolute path of umu-run, resolved by the caller
---@return string wrapper
function umu.launch_wrapper(umu_run)
  local words = { "env", "GAMEID=" .. umu.umu_id() }

  local extra = umu.launch_options()
  if extra then
    words[#words + 1] = extra
  end

  words[#words + 1] = umu_run

  return table.concat(words, " ")
end

---The umu id a launch is run under.
---
---Read from the environment when set, so a machine that needs something else
---(`umu-ge-proton9-20`, a Proton version Steam's own numbers for) can ask for it
---without a new release of the plugin. Only read once: it is written into
---`launch.sh` when that is written, and cannot change while Steam is running.
---
---`umu-win32` is umu's own "an ordinary 32-bit Windows program" id, which is what
---an Epic game is.
---@return string
function umu.umu_id()
  if UMU_ID then
    return UMU_ID
  end

  local configured = utils.trim(utils.getenv("EPIC_GAMES_UMU_ID") or "")
  UMU_ID = configured ~= "" and configured or "umu-win32"

  return UMU_ID
end

---The awk program a launch script reads one of Steam's compatibility settings
---with, the key passed in as `want`.
---
---`CompatToolMapping` holds one entry per appid: the global one under `0`, and
---one per game under the appid Steam gives that shortcut. So the answer for a
---game is two lookups, and this takes the key rather than deciding which.
---
---The entry has to be entered before the name is taken, which is what `found` is
---for: a Proton is also the name of an appid of its own in the same file, and a
---name taken on sight would be taken from the wrong block.
---
---Nothing is printed when the key has no entry. Steam does not write an entry
---whose name is empty - 40 entries on a real library, none of them blank - so
---"no entry" and "No tool" are the same thing here, and the caller answers with
---the global rather than with nothing.
local COMPAT_TOOL_AWK = [==[
  /"CompatToolMapping"/ { mapping = 1; next }
  mapping && !found && $0 ~ "^[[:space:]]*\"" want "\"[[:space:]]*$" { found = 1; next }
  found && /"name"/ {
    sub(/^[^"]*"name"[[:space:]]*"/, "")
    sub(/".*$/, "")
    print
    exit
  }
]==]

---The lines a launch script needs to decide the Proton build, as a list.
---
---Steam's compatibility setting is read *by the script, when the game starts*,
---and is not resolved here and written down. That is why this emits a resolver
---rather than a path: Steam's setting changes while Steam is running, and a path
---baked into a file written when the plugin loaded cannot follow it. The user
---picks a build in _Properties_ > _Compatibility_, presses play a moment later,
---and the game runs under umu's own build because `PROTONPATH` still holds
---whatever it held at start-up - while the panel, reading the same setting live,
---says a different thing.
---
---That is not a rare thing to do: it is the ordinary way to change a build.
---
---In the order Steam applies them: **this game's own entry first**, then the
---global one. The game's key is `SteamAppId`, which Steam puts in the
---environment of every process it starts for a shortcut - the value that
---identifies the shortcut rather than the Epic app, and the one Steam itself
---looks a game's own settings up by. Reading only the global entry is what made
---a per-game choice in _Properties_ do nothing at all: the game started under
---the build every other game used, and nothing said so.
---
---The names are `STEAM_STORE_BUILDS` rendered into a `case`, rather than a
---second list kept in step by hand - the same two places answering "what did
---Steam ask for" and "what is installed" is how this file once ended up with a
---build in it that was installed under another name.
---
---`PROTONPATH` is left unset when Steam says no tool or when the build it names
---is not on this machine, and both are written down: umu then uses its own
---build, and a launch that silently does not do what was asked for is the one
---failure this whole module exists to prevent.
---
---A list rather than a string because the caller splices it into a `table.concat`
---of lines, and because "set the variable" and "do not set it" are different
---shapes for that - a nil in the middle of a concat is an error rather than an
---absent line.
---@param quote fun(value: string): string Shell-quote for one value
---@return string[] lines
function umu.proton_exports(quote)
  -- Steam's own _Settings > Compatibility_ decides, and nothing else. The plugin
  -- had a field of its own that came first, so two places answered the same
  -- question and the answer depended on which one you asked.
  --
  -- Both of Steam's answers are resolved by the script, at launch: this game's
  -- own entry when it has one, the global entry otherwise. Neither is ours.
  --
  -- `steam_path()` hands back the trailing slash it is given, and this splices
  -- paths together below.
  local steam = require("millennium").steam_path():gsub("/+$", "")

  local lines = {
    "# The Proton build to run the game through. Steam's compatibility setting",
    "# is read here, at launch, rather than written into this file when the file",
    "# was generated: the setting changes while Steam runs, and a path written",
    "# at start-up is one decision behind.",
    "STEAM_ROOT=" .. quote(steam),
    "STEAM_COMPAT_VDF=$STEAM_ROOT/config/config.vdf",
    "",
    -- One key, one answer. An empty key answers nothing rather than answering
    -- for whichever entry happened to match: the caller passes a real key, or
    -- none at all and gets the global.
    "steam_compat_tool() {",
    '  [ -n "$1" ] || return 0',
    '  [ -r "$STEAM_COMPAT_VDF" ] || return 0',
    -- No awk is no build, rather than a shell error in the middle of a launch:
    -- umu's own build is a working game, and this is a diagnosis written down.
    "  command -v awk >/dev/null 2>&1 || return 0",
    "  awk -v want=\"$1\" '" .. COMPAT_TOOL_AWK .. "' \"$STEAM_COMPAT_VDF\"",
    "}",
    "",
    "# This game's own entry wins over the global one, exactly as in Steam: a",
    "# build set in a game's Properties is that game's build, and the global one",
    "# is what the games with no entry of their own get.",
    'steam_appid="${SteamAppId:-}"',
    'steam_tool="$(steam_compat_tool "$steam_appid")"',
    'steam_scope="this game (Steam app id ${steam_appid:-unknown})"',
    'if [ -z "$steam_tool" ]; then',
    '  steam_tool="$(steam_compat_tool 0)"',
    '  steam_scope="every game (Steam app id 0)"',
    "fi",
    "",
    "# Steam's own builds are named twice: `proton_experimental` is installed as",
    "# `Proton - Experimental`, `proton_11` as `Proton 11.0`. A build put into",
    "# `compatibilitytools.d` by hand is spelled the same in both places, which is",
    "# why those always worked and these never did.",
    "steam_proton_folder() {",
    '  case "$1" in',
  }

  for _, entry in ipairs(STEAM_STORE_BUILDS) do
    lines[#lines + 1] = "    " .. entry.app .. ") printf '%s\\n' " .. quote(entry.folder) .. " ;;"
  end

  -- The numbered builds follow a shape rather than a list, so this stays true
  -- of a version that does not exist yet.
  lines[#lines + 1] = "    proton_[0-9]*) printf '%s\\n' \"Proton ${1#proton_}.0\" ;;"
  lines[#lines + 1] = '    *) printf \'%s\\n\' "$1" ;;'
  lines[#lines + 1] = "  esac"
  lines[#lines + 1] = "}"

  table.insert(lines, 'if [ -z "$steam_tool" ]; then')
  table.insert(lines, "  say \"  Steam\'s compatibility tool for $steam_scope: no tool, so umu\'s own build runs.\"")
  table.insert(lines, "  unset PROTONPATH")
  table.insert(lines, "else")
  table.insert(lines, '  steam_folder="$(steam_proton_folder "$steam_tool")"')
  table.insert(
    lines,
    '  say "  Steam\'s compatibility tool for $steam_scope: $steam_tool, installed as $steam_folder"'
  )

  -- Steam's own copy first: a store build is also copied into `compatibilitytools.d`
  -- by people who prefer it there, and Steam runs the one it downloaded.
  table.insert(lines, '  if [ -d "$STEAM_ROOT/steamapps/common/$steam_folder" ]; then')
  table.insert(lines, '    PROTONPATH="$STEAM_ROOT/steamapps/common/$steam_folder"')
  table.insert(lines, '  elif [ -d "$STEAM_ROOT/compatibilitytools.d/$steam_tool" ]; then')
  table.insert(lines, '    PROTONPATH="$STEAM_ROOT/compatibilitytools.d/$steam_tool"')
  table.insert(lines, "  else")
  table.insert(lines, '    say "  but that build is not installed, so umu\'s own runs."')
  table.insert(lines, "    unset PROTONPATH")
  table.insert(lines, "  fi")
  table.insert(lines, "fi")

  table.insert(lines, 'if [ -n "${PROTONPATH:-}" ]; then')
  table.insert(lines, "  export PROTONPATH")
  table.insert(lines, "fi")

  return lines
end

return umu