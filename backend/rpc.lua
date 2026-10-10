local config = require("config")
local config_vdf = require("config_vdf")
local exes = require("exes")
local grid = require("grid")
local jobs = require("jobs")
local json = require("json")
local launcher = require("launcher")
local legendary = require("legendary")
local library = require("library")
local logger = require("logger")
local manifest = require("manifest")
local millennium = require("millennium")
local platform = require("platform")
local shell = require("shell")
local store = require("store")
local text = require("text")
local trace = require("trace")
local umu = require("umu")
local usage = require("usage")
local utils = require("utils")
local vdf = require("vdf")

-- Every method takes one JSON payload and answers with one JSON document.

--- Polled once a second while a download is going, so tracing every one of
--- these would bury everything else in the file. Only traced when it fails or
--- takes long enough to be worth knowing about.
--
--- `Log` is in the list for the same reason, one step on: it is called from the
--- patches' own logging, so tracing every call would write two lines where the
--- one it is carrying is the one worth reading.
local QUIET = { GetJobs = true, Log = true }

--- What counts as long enough, for calls that are otherwise instant.
local SLOW_MS = 250

---Walk a handler's answer and make every string in it encodable. Keys as well
---as values, since a game name can be either.
---@param value any
---@param seen table<table, table>
---@param report { replaced: integer, window: string|nil }
---@return any
local function sanitise(value, seen, report)
  if type(value) == "string" then
    local scrubbed, replaced, position = text.scrub(value)
    if replaced > 0 and position then
      report.replaced = report.replaced + replaced
      report.window = report.window or text.window(value, position)
    end
    return scrubbed
  end
  if type(value) ~= "table" then
    return value
  end
  if seen[value] then
    return seen[value]
  end

  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    copy[sanitise(key, seen, report)] = sanitise(item, seen, report)
  end
  return copy
end

---Note that a call finished.
---@param name string
---@param started integer
---@param fields table<string, any>
local function record(name, started, fields)
  local elapsed = utils.time_ms() - started
  if QUIET[name] and elapsed < SLOW_MS then
    return
  end

  fields.method = name
  fields.ms = elapsed
  trace.event("rpc", fields)
end

---Wrap a handler so it takes and returns JSON.
---
---Nothing here is allowed to throw: an error raised inside a handler unwinds
---into Millennium rather than back to the caller, which loses the call and the
---reason for it. So every half answers with a document instead.
---@param name string
---@param handler fun(data: table): table|nil
---@return fun(payload: string): string
local function method(name, handler)
  return function(payload)
    local started = utils.time_ms()

    local read, data = pcall(json.decode, payload)
    if not read or type(data) ~= "table" then
      trace.anomaly("rpc.payload", { method = name, bytes = #payload })
      return json.encode({ ok = false, error = "Malformed request payload" })
    end

    local ok, result = pcall(handler, data)
    if not ok then
      logger:error("RPC handler failed: " .. tostring(result))
      trace.anomaly("rpc.failed", { method = name, error = tostring(result) })
      return json.encode({ ok = false, error = (text.scrub(tostring(result))) })
    end

    -- Cannot return nothing or nil alone, because Millennium tries to stoi it.
    if not result then
      record(name, started, {})
      return "null"
    end

    local report = { replaced = 0 }
    -- Both halves inside the pcall, not just the encode: an argument is
    -- evaluated before the call that protects it, so sanitising out here would
    -- put its errors exactly where this whole function exists to keep them from
    -- going. Encoding throws on its own as well, for anything cjson can't
    -- represent - a number that isn't finite, a value type with no JSON
    -- equivalent.
    local wrote, encoded = pcall(function()
      return json.encode(sanitise(result, {}, report))
    end)
    if not wrote then
      logger:error("RPC response could not be encoded: " .. tostring(encoded))
      trace.anomaly("rpc.encode", { method = name, error = tostring(encoded) })
      return json.encode({ ok = false, error = "Response could not be encoded" })
    end

    -- Worth a line of its own: this is the shape that used to reach Millennium's
    -- parser and take the whole host down with it.
    if report.replaced > 0 then
      trace.anomaly(
        "rpc.invalid_utf8",
        { method = name, replaced = report.replaced, bytes = report.window }
      )
    end

    record(name, started, { bytes = #encoded })
    return encoded
  end
end

---@class RPC
local RPC = {}

-- Setup -----------------------------------------------------------------------

---Is legendary runnable, and is an Epic account signed in?
RPC.GetStatus = function(data)
  return legendary.get_status(data.refresh == true)
end

---Exchange the code from Epic's redirect page for a stored login. The browser
---half happens in the frontend. We never see the password - legendary trades
---the code for its own tokens and stores them.
RPC.SignIn = function(data)
  local ok, err = legendary.authenticate(data.code)
  if not ok then
    -- A rejected code costs nothing: authenticate() puts the previous session
    -- back, so the panel is told about it rather than left saying "not signed
    -- in" about an account that is still signed in.
    return { ok = false, error = err, status = legendary.get_status() }
  end

  -- authenticate() already re-read the status to decide whether it worked.
  return { ok = true, status = legendary.get_status() }
end

RPC.SignOut = function()
  legendary.sign_out()
  -- sign_out() already left the cached status current.
  return { ok = true, status = legendary.get_status() }
end

-- Diagnostics -----------------------------------------------------------------

-- Library ---------------------------------------------------------------------

---Everything the account owns, merged with what's installed on disk.
---
---Answers from the cache by default, since a cold `legendary list` takes a few
---seconds on a large account and shouldn't happen behind the user's back. Pass
---`refresh` to read it, `force` to also bypass legendary's own catalog cache,
---or `installed` to re-read just what's on disk.
RPC.GetLibrary = function(data)
  local games, err
  if data.installed then
    games, err = library.refresh_installed()
  elseif data.refresh then
    games, err = library.refresh(data.force == true)
  else
    games = library.get()
  end

  if not games then
    return { ok = false, error = err }
  end
  return { ok = true, games = games, refreshed_at = library.get_refreshed_at() }
end

---The command lines Steam should use for a set of games' shortcuts.
---
---It points at a program of ours named after the game rather than at the game's
---own executable: that program runs legendary, which waits on the game process,
---so playtime and "Currently playing" work, the shortcut survives Epic moving the
---exe, and it can exist before the game is installed. The arguments it comes back
---with are empty - Steam's launch options box is the user's, and this plugin
---writes nothing in it. See `legendary.launch_command`.
---
---Asked for the whole library in one call, because a sync asks it for every game
---and every game used to ask it on its own: 551 round trips to the backend and
---1 653 lines of trace file for an answer that is the same shape for all of them.
---Answered index for index, so a caller can zip it against what it asked with
---without inventing a key.
---@param data {entries: {app_name: string, title: string|nil}[]}
RPC.GetLaunchCommands = function(data)
  -- Read once for the whole pass rather than per game: it is the same answer
  -- every time, and asking per game meant asking a filesystem about the same
  -- path 551 times over.
  local binary = legendary.get_binary()
  local commands = {}

  for _, entry in ipairs(data.entries or {}) do
    local installed = library.install_dir(entry.app_name)
    local exe, arguments = legendary.launch_command(entry.app_name, entry.title, installed)

    -- Ask, once per installed game, what it runs. The answer is not needed for
    -- this command - the shortcut points at the script either way - but a launch
    -- that Steam has decided to run inside a Proton cannot use umu and needs the
    -- executable, and this is the one call the sync makes for every game, so it
    -- is where the question is cheapest to ask. Nothing here waits for the answer.
    if installed then
      exes.ensure(entry.app_name, binary)
    end

    if not exe then
      commands[#commands + 1] = { ok = false, error = arguments }
    else
      commands[#commands + 1] = {
        ok = true,
        exe = exe,
        arguments = arguments,
        -- The working directory is the game's own folder, not the one holding
        -- the launch script. Steam derives a shortcut's installed folder from
        -- it, and that folder name is how the storage page knows which
        -- directory under `steamapps/common/` to measure and which to delete on
        -- uninstall - so a shortcut pointing at the script's folder is a game
        -- Steam cannot account for.
        start_dir = installed or exe:match("^(.*)[\\/]") or "",
      }
    end
  end

  return { ok = true, commands = commands }
end

---What Steam actually wrote for a set of shortcuts, next to what it should have.
---
---The answer to "the plugin says it updated the command but the game still does
---nothing": `SetShortcutExe` returns nothing at all, and some client builds
---silently ignore it, so a plugin that trusts its own calls has no way to tell a
---migration that worked from one that quietly did not. `shortcuts.vdf` is where
---the truth is, and this reads it.
---
---Only the two fields that decide whether a game starts: the program and its
---arguments. The icon and the working directory are reported but never treated
---as failures - a missing icon is a grey box, a wrong program is a dead button,
---and conflating them would bury the second in the first.
---@param data {entries: {app_name: string, app_id: integer, title: string|nil}[], account_id: integer|nil, limit: integer|nil}
RPC.AuditShortcuts = function(data)
  local entries = data.entries or {}
  local wanted = {}
  for _, entry in ipairs(entries) do
    wanted[#wanted + 1] = entry
  end

  local shortcuts, err = vdf.read_shortcuts(data.account_id)
  if not shortcuts then
    logger:warn("Could not read shortcuts.vdf: " .. tostring(err))
    return { ok = false, error = err }
  end

  local mismatches = {}
  local missing = 0
  local limit = math.min(data.limit or 10, #wanted)

  for _, entry in ipairs(wanted) do
    local fields = shortcuts[tostring(entry.app_id)]

    if not fields then
      missing = missing + 1
    else
      local exe, arguments = legendary.launch_command(entry.app_name, entry.title, library.install_dir(entry.app_name))

      -- One report per shortcut even when both fields are wrong: two lines
      -- saying the same game is broken is noise, and the fix is the same.
      if exe and (fields.exe ~= exe or fields.LaunchOptions ~= arguments) then
        mismatches[#mismatches + 1] = {
          app_id = entry.app_id,
          app_name = entry.app_name,
          actual_exe = fields.exe,
          actual_options = fields.LaunchOptions,
          wanted_exe = exe,
          wanted_options = arguments,
          start_dir = fields.StartDir,
          icon = fields.icon,
        }
      end
    end

    if #mismatches >= limit then
      break
    end
  end

  return {
    ok = true,
    checked = #wanted,
    found = #wanted - missing,
    missing = missing,
    truncated = #mismatches >= limit,
    mismatches = mismatches,
  }
end

---Which of these appids Steam has been told to run through a compatibility tool.
---
---The one thing that stops an Epic game starting without a word of complaint:
---a non-Steam shortcut mapped to Proton in Steam's per-app settings is launched
---*inside* that Proton, and the plugin's `launch.sh` is a Linux shell script that
---cannot execute there. Steam writes the mapping itself - it is what its own
---Properties dialog edits - so the plugin cannot set or clear it through any API
---it has, and the best it can do is say which appids are affected and what to
---change.
---The key an appid is looked up under, whatever shape it arrived in.
---
---Steam's own keys are plain decimal digits, and an appid is small enough to be
---one exactly. Getting there from what the frontend sent is not automatic:
---`tostring` on a number this large can come out as `3.789737657e+09` on some
---runtimes, which matches no key in the file and so reports "no tool" for a game
---that plainly has one - silently, and on every call, because the answer being
---looked for is a miss rather than an error.
---
---`%.0f` is the one form that is always exact and never exponential. Strings are
---passed through, trimmed, because a JSON decoder is free to hand back a number
---as its own text.
---@param app_id any
---@return string key
local function appid_key(app_id)
  local number = tonumber(app_id)

  if not number then
    return utils.trim(tostring(app_id))
  end

  -- Steam's own keys are written as **unsigned** decimals, and the appid that
  -- reaches here is signed: a non-Steam shortcut's appid is above 2^31, so the
  -- two runtimes spell the same number `-505229639` and `3789737657`. Looked up
  -- as written, the key matches nothing - so a game with a tool set reports
  -- "none" forever, and the page falls back to the global one.
  if number < 0 then
    number = number + 4294967296
  end

  return string.format("%.0f", number)
end

---@param data {app_ids: integer[]}
RPC.CompatTools = function(data)
  local wanted = {}
  local order = {}

  -- `ipairs` alone is not enough: a decoded array that arrived as an object is
  -- skipped entirely, which is the same silent "no tool" for a different reason.
  -- `pairs` covers both, and the key is normalised anyway, so the order it walks
  -- cannot change the answer.
  for _, app_id in pairs(data.app_ids or {}) do
    local key = appid_key(app_id)

    if key ~= "" and not wanted[key] then
      wanted[key] = true
      order[#order + 1] = key
    end
  end

  local path = millennium.steam_path() .. "/config/config.vdf"
  local content = utils.read_file(path)

  if not content then
    return { ok = false, error = "could not read " .. path }
  end

  local block = config_vdf.compat_tool_mapping(content)
  local mapped = {}

  for _, key in ipairs(order) do
    local tool = block[key]

    if tool then
      mapped[#mapped + 1] = { app_id = tonumber(key), name = tool }
    end
  end

  -- One line saying what arrived and what the file holds, because the failure
  -- this whole function exists to avoid is a silent one: a key that does not
  -- match is indistinguishable from a game with no mapping, and the one that
  -- matters here is a Steam appid in the billions, not a small one.
  local known = 0
  for _ in pairs(block) do
    known = known + 1
  end

  local said = {}
  for _, entry in ipairs(mapped) do
    said[#said + 1] = tostring(entry.app_id) .. "=" .. entry.name
  end

  -- `table.concat` here takes no function: that is Lua 5.3, and this is LuaJIT.
  logger:info(
    "CompatTools asked for "
      .. table.concat(order, ",")
      .. " - "
      .. table.concat(said, ", ")
      .. " of "
      .. known
      .. " mappings"
  )

  return { ok = true, mapped = mapped }
end

---The last launch's output, for a user whose game did not start.
---
---Steam has no window and no console for a non-Steam shortcut, so a launch that
---fails leaves nothing anywhere: not in Steam's logs, which record only that a
---process appeared and went away, and not on screen. `launch.sh` writes what
---legendary and the Proton wrapper printed to a file of ours, and this is how the
---panel shows it - the answer to "nothing happened when I pressed play" has to be
---somewhere the user can reach without a file manager.
---
---The last few launches rather than all of them: the file is appended to on every
---launch and never trimmed, and the one that broke is almost always at the end.
---@param data {count: integer|nil}
---Everything a launch would do, without launching.
---
---`--dry-run` runs the whole of legendary's own work - the login, the manifest, the
---argument assembly - and stops just before it spawns anything, so the command it
---*would* have run comes back in full: the Proton wrapper, the game's own
---executable, and the Epic authentication arguments. That is the "what is actually
---being launched" that a failing shortcut never shows, because the shortcut is the
---only thing that knows and the only place it could say so is a file nobody reads
---until it misbehaves.
---
---The environment umu will resolve is resolved alongside it, from the same
---process, so the report is about this machine rather than about a guess.
---@param data {app_name: string, account_id: integer|nil}
RPC.DiagnoseLaunch = function(data)
  local app_name = data.app_name

  if type(app_name) ~= "string" or app_name == "" then
    return { ok = false, error = "no game was named" }
  end

  -- The binary, *not* what `launch_command` returns.
  --
  -- `launch_command` answers with the shim, and the shim is the wrong thing to
  -- run here for a reason that makes it worse than a detail: it redirects the
  -- program's output into `backend/launch.log`. Running it would carry the
  -- diagnosis out perfectly and return an empty string - the stub really would
  -- be executed, with the right arguments, and nothing would come back.
  local exe = legendary.get_binary()
  if not exe then
    return { ok = false, error = "legendary is not available on this machine" }
  end

  -- The same shape the shortcut runs, plus `--dry-run`: the wrapper is what
  -- makes legendary put umu in front of the game, so the diagnostic has to carry
  -- it or it would describe a different launch.
  local command = { "launch", platform.quote_argument(app_name), "--dry-run", "--no-wine" }

  local umu_run = legendary.umu_run()
  if umu_run then
    command[#command + 1] = "--wrapper"
    -- The same value `launch.sh` passes, built by the same code: a diagnosis
    -- that described a different wrapper than the one in force would be worse
    -- than none.
    command[#command + 1] = umu.launch_wrapper(umu_run)
  end

  local started = utils.time_ms()
  local output, status = shell.run(exe, command, { timeout = 120000 })

  -- Not trimmed: the line that says what would have run is the answer, and it is
  -- in the middle of the output rather than at the end of it.
  logger:warn("Diagnose launch for " .. app_name .. " (exit " .. tostring(status) .. "):\n" .. output)

  return {
    ok = true,
    app_name = app_name,
    output = output,
    status = status,
    took_ms = utils.time_ms() - started,
    umu_run = umu_run,
    umu_id = umu.umu_id(),
    install_dir = library.install_dir(app_name),
  }
end

---The four fields `shortcuts.vdf` holds about one shortcut, read back from the file.
---
---What Steam recorded, rather than what the plugin believes it recorded. The
---program and its arguments decide whether the game starts; the working directory
---is how Steam finds the install for the storage page; the icon is the one thing
---that is a file rather than a setting, and so goes missing on its own. All four
---are worth seeing together when a shortcut misbehaves.
---@param data {app_id: integer, account_id: integer|nil}
RPC.InspectShortcut = function(data)
  local fields, err = vdf.read_shortcut(data.app_id, data.account_id)

  if not fields then
    return { ok = false, error = err }
  end

  return {
    ok = true,
    app_id = data.app_id,
    name = fields.AppName,
    exe = fields.exe,
    launch_options = fields.LaunchOptions,
    start_dir = fields.StartDir,
    icon = fields.icon,
    last_play_time = tonumber(fields.LastPlayTime) or 0,
  }
end

---The Proton build the launches will use, and the ones this machine has.
---
---The build for a launch Steam starts itself. Where Steam starts the shortcut
---inside a compatibility tool, that tool is the build the game runs with, and
---this is only the answer for the other case.
---
---Nor umu's configuration file, which is the other thing that looks like it
---should be written here: umu reads a TOML file only when it is passed to
---`umu-run --config`, and it picks up no `umu.conf` of its own. The build is
---handed over in the environment at launch, as `PROTONPATH`.
---
---Each build is reported with whether it can decode video, which is a property of
---the build on this machine rather than of its name: a Proton whose GStreamer
---plugins were built against one FFmpeg and which ships another can decode
---nothing at all, and shows it as videos that never play.
---@param data {unused: any}
RPC.GetUmuConfig = function(_)
  local builds = umu.available_builds()
  local global_tool = umu.steam_global_tool()
  -- What a launch will use, which is the chosen build when there is one and
  -- Steam's global setting otherwise. Reported rather than the raw setting, so
  -- the control shows the answer a launch will actually give.
  local chosen = umu.effective_proton() or ""

  -- Said out loud because a global tool is invisible from any one game: it is set
  -- in Steam's Settings rather than in anything belonging to a game, and it
  -- decides the build for all of them.
  if global_tool then
    logger:warn(
      "Steam's global compatibility tool is set to "
        .. global_tool
        .. ", so every non-Steam shortcut is started inside it and games run with "
        .. "that build rather than the one chosen here. Set it to \"No tool\" in "
        .. "Steam's Settings, Compatibility to use the plugin's own build."
    )
  end

  return {
    ok = true,
    config_path = umu.config_path(),
    -- What the next launch uses. Empty only when there is neither a choice here
    -- nor a usable one in Steam's settings.
    proton = chosen,
    -- Whether that came from this plugin's own setting. Reported rather than
    -- assumed, because the two places a build can come from are not the same
    -- thing and the panel has to name which one it is showing.
    proton_is_own = umu.proton() ~= nil,
    -- Steam's global compatibility setting, named so the panel can say what is
    -- breaking the launches rather than only that something is. Never used as a
    -- value - see `umu.steam_global_tool`.
    steam_global = global_tool or "",
    -- True when Steam would start the shortcuts inside its own container. The
    -- launch still works there - `launch.sh` runs the game through that build's
    -- own wine - but with the build Steam chose rather than the one named below.
    blocked_by_global = global_tool ~= nil,
    -- The words in front of the game, so the menu can show what is set rather
    -- than only that something is.
    launch_options = config.get("launch_options") or "",
    -- Whether that value is one this plugin will actually use. A hand-edited
    -- file can hold anything, and one that would be refused has to say so here
    -- rather than leaving the panel showing a setting that is not in force.
    launch_options_valid = umu.check_options(config.get("launch_options")) ~= nil,
    -- Where a shortcut's _Target_ points, and what it is told to run - so the
    -- panel can show the whole chain instead of the user having to read it out
    -- of Steam's Properties dialog. The shared script, because that is the
    -- fallback; the real target is a program per game, named after it.
    launch_target = launcher.script_path(),
    builds = builds,
  }
end

---Rewrite `launch.sh` from the settings as they are on disk right now.
---
---The one function both settings go through, because the script is the only
---thing a launch reads: writing the file and answering is what makes a change
---take effect on the next press of play, rather than on the one after a sync
---that may never happen.
---@return string|nil error
local function rewrite_launch_script()
  local binary = legendary.get_binary()
  if not binary then
    return nil
  end

  local umu_run = legendary.umu_run()
  local _, err = launcher.ensure(binary, umu_run)
  return err
end

---Launch the games through a build, for every non-Steam game on this machine at once.
---
---Also what happens when `config.json` has been edited by hand since the panel
---last asked: the file is the real setting, and a menu that kept showing what it
---remembered would be lying about what the next launch will use.
---
---`attempt_clear` goes with an empty build: the panel offers, in the same
---gesture, to set Steam's global compatibility tool to "No tool", since with no
---build of ours that global is what would run. Steam has no API for that - the
---entry lives in `config.vdf`, written by Steam's own dialog - so it is done by
---rewriting the one line, the same edit Steam's dialog would make. Best effort:
---a file Steam has open in a different shape is reported, not forced.
---@param data {build: string, attempt_clear: boolean|nil}
RPC.SetProton = function(data)
  local build = data.build

  if type(build) ~= "string" then
    return { ok = false, error = "no build was named" }
  end

  local ok, err = umu.set_proton(build)
  if not ok then
    logger:error("Could not set the Proton build: " .. tostring(err))
    return { ok = false, error = err }
  end

  local cleared, clear_error = false, nil

  if build == "" and data.attempt_clear then
    cleared, clear_error = config_vdf.clear_global_compat_tool()

    if clear_error then
      logger:warn("Could not clear Steam's global compatibility tool: " .. clear_error)
    elseif cleared then
      logger:info("Steam's global compatibility tool set to No tool")
    end
  end

  -- The script rewritten *now*, before the answer goes back, so the build takes
  -- effect on the very next press of play rather than on the one after the sync
  -- finishes.
  --
  -- Which it did not, and that is a user-visible failure rather than a slow
  -- feature: `launch.sh` is what every shortcut runs, and it is normally only
  -- rewritten as a side effect of the sync that follows this call. A user who
  -- chose a build and pressed play while that sync - 548 shortcuts - was still
  -- running got the *previous* build, and no indication of it. The log showed
  -- the old PROTONPATH against a config that had already changed.
  local script_error = rewrite_launch_script()

  if script_error then
    -- Named rather than swallowed: the setting is saved either way, so a
    -- failure here means the next launch silently uses the old build, which is
    -- the thing worth knowing about.
    logger:error("Could not rewrite the launch script: " .. tostring(script_error))
  end

  logger:warn(
    (build == "" and "Games will use umu's own Proton build again."
      or ("Games will launch through Proton: " .. tostring(build)))
      .. (script_error and "" or " The launch script is already up to date.")
  )

  return {
    ok = script_error == nil,
    proton = build == "" and "" or build,
    config_path = umu.config_path(),
    -- Said separately from `ok`: the build *is* saved, and the panel has to be
    -- able to tell "it did not take" from "it did, but one thing went wrong".
    script_error = script_error,
    -- Whether Steam's global tool was cleared alongside. Nil when it was not
    -- asked for, so the panel can tell "not attempted" from "attempted and
    -- already clear".
    steam_global_cleared = data.attempt_clear and cleared or nil,
    steam_global_error = clear_error,
  }
end

---The words to put in front of the game: `mangohud=1`, `gamemoderun`,
---`gamescope --fsr`, `%command%`.
---
---Here rather than in each shortcut's launch options, which the plugin rewrites
---on every sync - so a value typed into Steam's own dialog is gone at the next
---one, without saying so.
---
---Refused rather than stored when it could not be passed safely: anything the
---shell would read as more than a word. `mangohud=1` and `gamescope --fsr` are
---not refused - they are what the field is for - and an error is still worth
---more than a setting that silently does nothing.
---@param data {options: string}
RPC.SetLaunchOptions = function(data)
  local options = data.options

  if type(options) ~= "string" then
    return { ok = false, error = "no options were given" }
  end

  local word, refused = umu.check_options(options)
  if refused then
    logger:error("Refusing launch options: " .. refused)
    return { ok = false, error = refused }
  end

  local ok, err = config.set_string("launch_options", word or "")

  if not ok then
    logger:error("Could not save the launch options: " .. tostring(err))
    return { ok = false, error = err }
  end

  -- Same as the Proton build: the script is rewritten before the answer goes
  -- back, so the next press of play uses it. Nothing in Steam has to be
  -- rewritten - the shortcut's own arguments no longer carry any of this.
  local script_error = rewrite_launch_script()
  if script_error then
    logger:error("Could not rewrite the launch script: " .. tostring(script_error))
  end

  logger:warn(
    (word == nil and "Games will be launched with nothing in front of them again."
      or ("Games will be launched through: " .. word))
      .. (script_error and "" or " The launch script is already up to date.")
  )

  return {
    ok = script_error == nil,
    launch_options = word or "",
    script_error = script_error,
  }
end

RPC.GetLaunchLog = function(data)
  local path = launcher.log_path()
  local content = utils.read_file(path)

  if not content then
    return { ok = true, text = "" }
  end

  -- Read from the end: a machine that has launched a lot of games has a file
  -- this has to walk, and only the tail of it is ever the answer.
  --
  -- Split on the "=== ... ===" headers rather than on lines, so a launch is kept
  -- whole however many lines it printed - the answer to "why did nothing happen"
  -- is usually the last thing before "exit: 1", and cutting on lines would put
  -- that on its own.
  local count = math.max(1, math.min(data and data.count or 3, 20))

  local blocks = {}
  local current = nil
  for line in (content .. "\n"):gmatch("(.-)\n") do
    if line:match("^=== ") and line:match(" ===$") then
      current = { line }
      blocks[#blocks + 1] = current
    elseif current then
      current[#current + 1] = line
    end
  end

  local kept = {}
  for index = math.max(1, #blocks - count + 1), #blocks do
    kept[#kept + 1] = table.concat(blocks[index], "\n")
  end

  return { ok = true, text = table.concat(kept, "\n"), path = path }
end

---How much room one game needs on disk, for the "Space Required" Steam shows
---beside the Install button. Kept out of GetLibrary because it costs a manifest
---fetch per game; slow once per game, cached after that.
RPC.GetGameSize = function(data)
  local size, err, still_running = legendary.get_size(data.app_name, data.refresh == true)
  -- Answered rather than waited for: the frontend asks again after retry_in
  -- milliseconds, and everything else keeps working meanwhile.
  if still_running then
    return { pending = true, retry_in = 500 }
  end
  if not size then
    return { ok = false, error = err }
  end
  return { ok = true, disk = size.disk, download = size.download }
end

---What the installed Epic games occupy on disk, measured rather than believed.
---
---The substitute for Steam's Settings > Storage, which cannot list a non-Steam
---shortcut at all: that page is built out of Steam's own install manifests, and a
---shortcut has none. So this measures the folders directly, one game per call, so
---a library of a hundred installed games costs a hundred cheap `du`s spread over
---a hundred ticks rather than one call that holds the Lua state while it walks
---all of them.
---
---`refresh` re-measures, which the panel asks for after an install or an
---uninstall: an answer that survived the change is worse than no answer, because
---it makes a finished uninstall look like a failure.
---@param data {app_name: string, refresh: boolean|nil}
RPC.GetGameUsage = function(data)
  local app_name = data.app_name
  if type(app_name) ~= "string" or app_name == "" then
    return { ok = false, error = "no game was named" }
  end

  local install_path = library.install_dir(app_name)
  if not install_path then
    -- Not an error the user caused, and not worth a line in the log on every
    -- render of a game that is simply not installed.
    return { ok = true, installed = false }
  end

  local bytes, still_running = usage.for_game(app_name, install_path, data.refresh == true)
  if still_running then
    return { pending = true, retry_in = 500 }
  end

  return {
    ok = true,
    installed = true,
    path = install_path,
    bytes = bytes or 0,
  }
end

---Drop what is remembered about a game, for after it has been installed or
---removed: its measured size, and the executable a launch inside a Steam-chosen
---Proton runs. An answer kept across either names a folder that has moved or no
---longer exists.
---@param data {app_name: string}
RPC.ForgetGameUsage = function(data)
  usage.forget(data.app_name)
  usage.stop(data.app_name)
  exes.forget(data.app_name)
  return { ok = true }
end

---One game's achievements, as Epic has them. Costs a round trip to Epic on a
---miss, cached in the backend after that; pass `refresh` to re-read one that
---has gone stale because the game has been played since.
RPC.GetAchievements = function(data)
  local result, err, still_running = legendary.get_achievements(data.app_name, data.refresh == true)
  -- Answered rather than waited for, the same way GetGameSize is.
  if still_running then
    return { pending = true, retry_in = 500 }
  end
  if not result then
    return { ok = false, error = err }
  end

  -- Copied rather than flagged in place: the table is legendary's cache entry,
  -- and an `ok` written into it would be persisted with it.
  return {
    ok = true,
    total = result.total,
    unlocked = result.unlocked,
    fetched_at = result.fetched_at,
    achievements = result.achievements,
  }
end

---What we already know about every game's achievements, counts only, straight
---from the cache. Never touches Epic, so the frontend can seed the whole
---library's completion percentages in one call.
RPC.GetCachedAchievements = function()
  -- A list rather than a map keyed by app name: the frontend camelises every
  -- key it gets back, and an app name is not a key it should be rewriting.
  local games = {}
  for app_name, summary in pairs(legendary.get_cached_achievements()) do
    table.insert(games, {
      app_name = app_name,
      total = summary.total,
      unlocked = summary.unlocked,
      fetched_at = summary.fetched_at,
    })
  end

  return { ok = true, games = games }
end

-- Installs --------------------------------------------------------------------

---Start installing, updating or resuming one game. Returns as soon as the job
---is spawned; progress is read back with GetJobs. Starting a game that is
---already installing returns the running job.
RPC.StartInstall = function(data)
  -- `library_path`, not a path the caller assembled: the join onto
  -- `steamapps/common` happens in the backend, where the platform's separator is
  -- known. A caller writing `folder + "\\" + sub` produces a literal backslash
  -- in a Linux directory name.
  local job, err = legendary.install(data.app_name, data.library_path, data.game_folder)
  if not job then
    return { ok = false, error = err }
  end
  return { ok = true, job = job }
end

---Update an installed game to the latest build. The same job machinery as an
---install, and the same queue - only one legendary runs at a time.
RPC.StartUpdate = function(data)
  local job, err = legendary.update(data.app_name)
  if not job then
    return { ok = false, error = err }
  end
  return { ok = true, job = job }
end

---Remove a game from disk. The Steam shortcut is left alone, since keeping
---uninstalled games in the library is the point of the plugin.
RPC.StartUninstall = function(data)
  local job, err = legendary.uninstall(data.app_name)
  if not job then
    return { ok = false, error = err }
  end
  return { ok = true, job = job }
end

---Every install or uninstall we know about, running or finished. Polled while
---something is downloading, so it only reads the small files the runner writes.
RPC.GetJobs = function()
  return { ok = true, jobs = jobs.list() }
end

-- Steam's storage page ----------------------------------------------------

---Give Steam an install manifest for every game the plugin installed, so that
---its Settings > Storage counts them among its own games.
---
---That page is built out of `steamapps/appmanifest_<appid>.acf`, one row per
---file, and a non-Steam shortcut has none - there is no API for making one,
---because Valve never expected anything else to be in that folder. Writing the
---file is the only way in, and it is what `manifest.lua` is for.
---
---The whole installed list goes in each time rather than one game: a game that
---has just been uninstalled has to stop being counted too, and the same list
---that says which games are installed is what says that. `changed` is whether
---anything on disk actually moved, so the frontend only asks Steam to rescan
---the folder when there is something new to read.
---
---A game whose folder is still being measured is left out rather than written
---with a size of nothing, and `awaiting` says so; one more pass writes it.
---Epic's store page for one game: the product page where Epic has one under the
---address its title implies, and its own search for the title where it does not.
---
---Settled by asking the store rather than by guessing, and remembered per game:
---one request, once, and never more than a click's waiting for the answer to
---arrive. The search is what comes back whenever the store could not be asked, so
---this is the search it used to do, with the real page when there is one.
---@param data {app_name: string, title: string, language: string|nil}
RPC.StorePage = function(data)
  return { ok = true, page = store.page(data.app_name, data.title, data.language) }
end

RPC.SyncManifests = function(data)
  local result = manifest.sync(data.games)

  return {
    ok = true,
    written = result.written,
    removed = result.removed,
    skipped = result.skipped,
    changed = result.changed,
    awaiting = result.awaiting,
    measuring = result.measuring,
  }
end

---Undo the two things this plugin writes into Steam's own files: the install
---manifests and the icons.
---
---Half of "remove everything" - Steam's shortcuts are the frontend's to remove,
---through the API that made them. Deliberately *not* touching the games' own
---files: those are the user's, and a button that deletes them is a button that
---destroys work.
---@param data table
---@return table
RPC.RemoveAll = function(data)
  local manifests = manifest.remove_all()
  local icons, err = grid.forget(data.app_ids, data.account_id)

  return {
    ok = true,
    manifests = manifests,
    icons = icons,
    error = err,
  }
end

-- Cloud saves ----------------------------------------------------------------

---Sync Epic's cloud saves for one game, or for every installed game when no
---game is named. Answered rather than waited on, the same way a game's size and
---achievements are: the caller asks again until there is an answer.
RPC.SyncSaves = function(data)
  local ok, err, summary, running = legendary.sync_saves(data.app_name, data.direction)
  if running then
    return { pending = true, retry_in = 500 }
  end

  if not ok then
    return { ok = false, error = err }
  end

  return { ok = true, summary = summary }
end

---Stop a running install, keeping what's already downloaded. legendary has no
---pause of its own, so this kills it; StartInstall is the resume.
RPC.PauseJob = function(data)
  return { ok = jobs.pause(data.app_name) }
end

---Stop a job and forget it. What's on disk is left where it is.
RPC.CancelJob = function(data)
  return { ok = jobs.cancel(data.app_name) }
end

-- Artwork ---------------------------------------------------------------------

---The icon Steam should read for each of these apps, if it is already there.
---
---Answers three ways on purpose: the file is where it should be, Steam had one
---under the wrong name and it has been adopted, or there is nothing to adopt and
---the frontend should draw an icon. The frontend asks this first on every sync
---because a missing icon is the failure this whole exchange exists to stop - for
---the whole library at once, so the answer costs one round trip rather than 551.
---@param data {app_ids: (integer|string)[], account_id: integer|nil}
RPC.PlaceIcons = function(data)
  local paths, err = grid.place_icons(data.app_ids or {}, data.account_id)
  if not paths then
    return { ok = false, error = err }
  end
  return { ok = true, paths = paths }
end

---Write an icon the frontend drew, and say where it went.
---
---The bytes come over as base64 because that is what the browser's `toDataURL`
---produces and because a JSON payload cannot carry anything else. Written here
---rather than by Steam, which writes `SetCustomArtworkForApp` output whenever it
---feels like it and under a name the header image also uses.
RPC.WriteIcon = function(data)
  local path, err = grid.write(data.app_id, data.account_id, data.data)
  if not path then
    return { ok = false, error = err }
  end
  return { ok = true, path = path }
end

-- Wrapped in one pass rather than at each definition, so a method cannot be
-- added without its JSON handling, and so the name a trace line carries is the
-- one the frontend called.
for name, handler in pairs(RPC) do
  RPC[name] = method(name, handler)
end

return { RPC = RPC }
