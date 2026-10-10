local disk = require("cache")
local fs = require("fs")
local jobs = require("jobs")
local json = require("json")
local launcher = require("launcher")
local logger = require("logger")
local platform = require("platform")
local shell = require("shell")
local utils = require("utils")
local vendor = require("vendor")

-- A wrapper around the `legendary` CLI (https://github.com/derrod/legendary),
-- which owns Epic's OAuth entirely - we never see a password or a token.

local legendary = {}

--- Where Epic sends the user to log in. The page it lands on prints the
--- authorization code we need.
local LOGIN_URL = "https://legendary.gl/epiclogin"

---@type string|nil
local BINARY = nil

---The legendary binary, downloading it if this machine hasn't got it yet.
---Public because a shortcut points at it - Steam launches legendary, not the
---game's own exe.
---@return string|nil path
---@return string? error
function legendary.get_binary()
  if BINARY and fs.is_file(BINARY) then
    return BINARY
  end

  local path, err = vendor.ensure()
  BINARY = path

  -- Always with a reason, so every caller can hand the error straight on
  -- rather than inventing wording of its own.
  if not path then
    return nil, err or "legendary binary not found"
  end
  return path
end

-- Commands --------------------------------------------------------------------

---The subcommand out of one argument list, for a log line.
---@param args string[]
---@return string
local function subcommand(args)
  for _, arg in ipairs(args) do
    if arg:sub(1, 1) ~= "-" then
      return arg
    end
  end
  return "?"
end

---Run one legendary command and block until it exits.
---@param args string[] Arguments to legendary, unquoted
---@param timeout integer|nil Milliseconds to wait, `shell.run`'s default if nil
---@return string output stdout followed by stderr, empty if the binary is missing
---@return integer status -1 if there was nothing to run
function legendary.run(args, timeout)
  local binary, err = legendary.get_binary()
  if not binary then
    logger:error("No legendary binary: " .. tostring(err))
    return "", -1
  end

  local started = utils.time_ms()
  local output, status = shell.run(binary, args, { timeout = timeout })

  local summary = subcommand(args) .. " in " .. (utils.time_ms() - started) .. "ms"
  if status == 0 then
    logger:info("Ran " .. summary)
  else
    logger:warn("Ran " .. summary .. ", exited " .. status)
  end

  return output, status
end

---Is this one of legendary's own log lines, like "[cli] INFO: Logging in..."?
---@param trimmed string
---@return boolean
local function is_log_line(trimmed)
  return trimmed:match("^%[[%w%-%._]+%]%s+%u+:") ~= nil
end

---Decode the JSON a legendary command printed.
---@param output string
---@return any|nil decoded
---@return string? error
function legendary.decode_json(output)
  -- The JSON arrives with legendary's log lines mixed in, and those look like
  -- "[cli] INFO: Logging in..." - so a search for the first "[" finds a log
  -- line, not the document.
  local lines = utils.split(output, "\n")
  for index, line in ipairs(lines) do
    local trimmed = utils.trim(line)
    local opens = trimmed:sub(1, 1)
    if (opens == "{" or opens == "[") and not is_log_line(trimmed) then
      -- Stops at the next log line rather than running to the end of the
      -- output: stderr is appended after stdout, so legendary's chatter lands
      -- on both sides of the document.
      local last = #lines
      for offset = index + 1, #lines do
        if is_log_line(utils.trim(lines[offset])) then
          last = offset - 1
          break
        end
      end

      local ok, decoded = pcall(json.decode, table.concat(lines, "\n", index, last))
      if ok then
        return decoded
      end
      return nil, "could not decode legendary output: " .. tostring(decoded)
    end
  end

  -- Only the last error line, never the whole output: a legendary that fell over
  -- prints a Python traceback, and handing kilobytes of it back as an error
  -- string tells nobody anything and travels through the whole RPC path.
  local trimmed = utils.trim(output)
  return nil, legendary.last_error(output) or trimmed:sub(1, 200)
end

---The last error line in some legendary output, if it printed one.
---@param output string
---@return string|nil
function legendary.last_error(output)
  local last
  for line in output:gmatch("[^\r\n]+") do
    if line:find("ERROR:") or line:find("CRITICAL:") then
      last = utils.trim(line)
    end
  end
  return last
end

-- Status ----------------------------------------------------------------------

---@class LegendaryStatus
---@field available boolean Is the binary present
---@field authenticated boolean Is there a logged in Epic account
---@field account string|nil Epic display name, when authenticated
---@field login_url string Where to send the user to sign in
---@field error string|nil Why we couldn't read a status

--- Cached: reading it costs a subprocess, and it's checked
--- on every panel render.
---@type LegendaryStatus|nil
local status = nil

---@param refresh boolean|nil Re-read rather than using the cached answer
---@return LegendaryStatus
function legendary.get_status(refresh)
  if status and not refresh then
    return status
  end

  local binary, err = legendary.get_binary()
  if not binary then
    status = {
      available = false,
      authenticated = false,
      login_url = LOGIN_URL,
      error = err or "legendary could not be downloaded.",
    }
    return status
  end

  -- The only command that reports the logged in account. It answers
  -- "<not logged in>" rather than failing when nobody is.
  local output = legendary.run({ "status", "--json" })
  local decoded, decode_error = legendary.decode_json(output)

  local account = type(decoded) == "table" and decoded.account or nil
  if account == json.null or account == "<not logged in>" then
    account = nil
  end

  status = {
    available = true,
    authenticated = account ~= nil,
    account = account,
    login_url = LOGIN_URL,
    -- Only when we came away with nothing: a decode complaint about the log
    -- lines around the document isn't a failure if the account came out of it.
    error = account == nil and decode_error or nil,
  }

  logger:info("Status: account=" .. tostring(account))
  return status
end

---Start a legendary command without waiting for it, for work too slow to hold
---the Lua state for. Collect it with `legendary.collect`.
---@param args string[] Arguments to legendary, unquoted
---@return string|nil id
---@return string? error
function legendary.start(args)
  local binary, err = legendary.get_binary()
  if not binary then
    return nil, err
  end

  return shell.start(binary, args)
end

---The output of a command started with `legendary.start`, or nil while it is
---still running. Answers once: collecting it clears it.
---@param id string
---@return string|nil output
function legendary.collect(id)
  return shell.poll(id)
end

-- Sizes ----------------------------------------------------------------------

-- How much room a game needs before it is installed, for the "Space Required"
-- Steam shows beside the Install button. `legendary list` does not carry it and
-- `legendary info` costs a manifest fetch per title, so it is read one game at a
-- time and cached by app name.
--
-- Nothing here can tell that a cached size has gone stale: knowing which build
-- it was measured against would cost the manifest fetch the cache exists to
-- avoid. So the frontend drops a game's size when a job touches it instead.

---@class GameSize
---@field disk integer Bytes the installed game occupies - what Steam calls "Space Required"
---@field download integer Bytes actually transferred, which is smaller: Epic ships compressed

local SIZES_PATH = utils.get_backend_path() .. "/data/cache/sizes.json"

---@type table<string, GameSize>|nil
local sizes = nil

--- The `legendary info` still running for a game, by app name, so asking twice
--- while the first is in flight waits on that one.
---@type table<string, string>
local sizing = {}

-- One number out of legendary's JSON, read as text rather than decoded.
--
-- `json.decode` hands the figure back through a 32-bit field, so a manifest
-- over 2 GiB arrives wrapped: Sifu's 32,560,431,714 bytes come back as
-- -1,799,306,654, and that negative is what the play bar then shows, because
-- the plugin hands it straight to Steam. A wrapped figure that lands *positive*
-- is worse - it is the very same number as a real size of that much, so
-- nothing downstream can tell it was ever wrong, and no amount of arithmetic
-- puts it back. So the digits are taken out of the text, where `tonumber` has
-- no width to run out of.
--
---@param output string Everything the command printed
---@param key string The field to take, e.g. `"disk_size"`
---@return number|nil size
local function figure(output, key)
  return tonumber(output:match('"' .. key .. '"%s*:%s*(-?%d+)'))
end

---Bumped whenever what a cached size means changes, which drops the cache.
local SIZES_VERSION = 2
local SIZES_VERSION_KEY = "version"

---The cached sizes, or none at all if they were written by an older plugin.
---
---Dropped whole rather than repaired: every figure in them went through that
---32-bit field, and one that wrapped back into positive range is the same
---number as a real size, so there is nothing left to detect it by. The cost is
---one manifest fetch per game, once, for a figure that was never right.
local function read_sizes()
  local stored = disk.read(SIZES_PATH, "sizes")

  if type(stored) ~= "table" or stored[SIZES_VERSION_KEY] ~= SIZES_VERSION then
    return {}
  end

  return stored
end

---What one game needs on disk.
---
---A miss costs a manifest fetch from Epic, several seconds of it, which is far
---too long to hold the Lua state for. So a miss starts the command and says so;
---the caller asks again, and the answer is there once it is. Never blocks.
---@param app_name string
---@param refresh boolean|nil Re-read even if it's cached
---@return GameSize|nil size
---@return string? error
---@return boolean? still_running The command has been started, ask again shortly
function legendary.get_size(app_name, refresh)
  if type(app_name) ~= "string" or app_name == "" then
    return nil, "No app name provided"
  end

  sizes = sizes or read_sizes()
  if sizes[app_name] and not refresh then
    return sizes[app_name]
  end

  local id = sizing[app_name]
  if not id then
    local started, err = legendary.start({ "info", app_name, "--json" })
    if not started then
      return nil, err
    end

    sizing[app_name] = started
    return nil, nil, true
  end

  local output = legendary.collect(id)
  if not output then
    return nil, nil, true
  end
  sizing[app_name] = nil

  local decoded, err = legendary.decode_json(output)
  if type(decoded) ~= "table" then
    return nil, err or "legendary returned no info"
  end

  -- No manifest means legendary could not reach Epic, which is the offline
  -- answer rather than a failure worth showing.
  local manifest = decoded.manifest
  if type(manifest) ~= "table" or type(manifest.disk_size) ~= "number" then
    return nil, "no manifest for " .. app_name
  end

  -- The manifest is only asked about for whether it is there at all; the two
  -- figures are read out of the text, where they are still whole.
  local disk_size = figure(output, "disk_size")
  if not disk_size then
    return nil, "no size in the manifest for " .. app_name
  end

  local size = {
    disk = disk_size,
    download = figure(output, "download_size") or disk_size,
  }

  sizes[SIZES_VERSION_KEY] = SIZES_VERSION
  sizes[app_name] = size
  disk.write(SIZES_PATH, sizes, "sizes")

  logger:info("Sized " .. app_name .. ": " .. size.disk .. " bytes on disk")
  return size
end

-- Achievements ---------------------------------------------------------------

-- Epic's achievements for one game, as `legendary achievements` reports them.
-- Read a game at a time and cached by app name, like sizes above: the command
-- talks to Epic, so it is far too slow to hold the Lua state for.
--
-- Unlike a size, this answer really does go stale - the user unlocks things by
-- playing - so `fetched_at` rides along and the frontend decides when to ask
-- again.

local ACHIEVEMENTS_PATH = utils.get_backend_path() .. "/data/cache/achievements.json"

---@class Achievement
---@field id string Epic's internal name, unique within the game
---@field name string Display name
---@field description string
---@field unlocked boolean
---@field progress number 0 to 1
---@field unlocked_at string|nil Epic's timestamp, parsed by the frontend
---@field icon string|nil Icon URL, already locked or unlocked as appropriate
---@field rarity number|nil Percent of players holding it
---@field hidden boolean Undiscovered, so Steam blurs it

---@class GameAchievements
---@field total integer
---@field unlocked integer
---@field fetched_at integer Unix seconds
---@field achievements Achievement[]

---@type table<string, GameAchievements>|nil
local achievements = nil

--- The `legendary achievements` still running for a game, by app name.
---@type table<string, string>
local achieving = {}

---Flatten one of legendary's four buckets into our own shape.
---@param entries table[]|nil
---@param out Achievement[]
local function collect_achievements(entries, out)
  if type(entries) ~= "table" then
    return
  end

  for _, entry in ipairs(entries) do
    table.insert(out, {
      id = entry.name,
      name = entry.display_name or entry.name,
      description = entry.description or "",
      unlocked = entry.unlocked == true,
      progress = entry.progress or 0,
      unlocked_at = type(entry.unlock_date) == "string" and entry.unlock_date or nil,
      icon = entry.icon_link,
      rarity = (entry.rarity or {}).percent,
      hidden = entry.hidden == true,
    })
  end
end

---Turn one `legendary achievements --json` document into a GameAchievements.
---@param decoded table
---@return GameAchievements
local function build_achievements(decoded)
  local list = {}
  -- Every bucket, in the order Steam wants them read: unlocked first, then
  -- what's under way, then the rest.
  collect_achievements(decoded.completed, list)
  collect_achievements(decoded.in_progress, list)
  collect_achievements(decoded.uninitiated, list)
  collect_achievements(decoded.hidden, list)

  return {
    total = decoded.total_achievements or #list,
    unlocked = decoded.user_unlocked or 0,
    fetched_at = math.floor(utils.time()),
    achievements = list,
  }
end

---One game's achievements.
---
---Started and collected the way `get_size` is: a miss says so rather than
---waiting, and the caller asks again shortly. Never blocks.
---@param app_name string
---@param refresh boolean|nil Ask Epic again even if it's cached
---@return GameAchievements|nil result
---@return string? error
---@return boolean? still_running The command has been started, ask again shortly
function legendary.get_achievements(app_name, refresh)
  if type(app_name) ~= "string" or app_name == "" then
    return nil, "No app name provided"
  end

  achievements = achievements or disk.read(ACHIEVEMENTS_PATH, "achievements") or {}
  if achievements[app_name] and not refresh then
    return achievements[app_name]
  end

  local id = achieving[app_name]
  if not id then
    -- --hidden, because Steam draws undiscovered achievements itself, blurred,
    -- and dropping them here would leave its counts short of the total.
    local started, err = legendary.start({ "achievements", app_name, "--json", "--hidden" })
    if not started then
      return nil, err
    end

    achieving[app_name] = started
    return nil, nil, true
  end

  local output = legendary.collect(id)
  if not output then
    return nil, nil, true
  end
  achieving[app_name] = nil

  local decoded, err = legendary.decode_json(output)

  -- Plenty of Epic games have no achievements at all, and legendary says so in
  -- a log line rather than an empty document. Cached like any other answer, or
  -- every session would ask Epic about them again.
  if type(decoded) ~= "table" and output:find("No achievements found", 1, true) then
    decoded = {}
  elseif type(decoded) ~= "table" then
    return nil, err or "legendary returned no achievements"
  end

  local result = build_achievements(decoded)
  achievements[app_name] = result
  disk.write(ACHIEVEMENTS_PATH, achievements, "achievements")

  logger:info(
    "Read achievements for " .. app_name .. ": " .. result.unlocked .. "/" .. result.total
  )
  return result
end

---Every game we already have achievements cached for, counts only.
---
---Reads nothing from Epic and starts nothing, so the frontend can ask about the
---whole library at once - which is what the library home's "% of Achievements
---Completed" sort needs, since it asks about every game as it draws and a
---command per game would be a subprocess storm.
---@return table<string, { total: integer, unlocked: integer, fetched_at: integer }>
function legendary.get_cached_achievements()
  achievements = achievements or disk.read(ACHIEVEMENTS_PATH, "achievements") or {}

  local summaries = {}
  for app_name, entry in pairs(achievements) do
    summaries[app_name] = {
      total = entry.total,
      unlocked = entry.unlocked,
      fetched_at = entry.fetched_at,
    }
  end

  return summaries
end

-- Long-running commands ------------------------------------------------------

---Where inside a Steam library folder an Epic game has to go.
---
---`steamapps/common/`, and not somewhere tidier of our own choosing, because
---that is the one directory Steam's storage accounting looks at. It attributes a
---game's size to the folder there that matches the shortcut's working directory,
---and offers to delete that folder when the game is uninstalled from
---Settings -> Storage. A game installed anywhere else is real, playable, and
---completely invisible to the page a user goes to when they want to know what is
---taking up their disk.
local STEAM_COMMON = { "steamapps", "common" }

---Build the install directory for a game inside a Steam library folder.
---@param library_path string The library folder itself, as Steam spells it
---@param game_folder string|nil The game's own folder name, if it has one
---@return string path
function legendary.steam_install_path(library_path, game_folder)
  -- Trailing separators come back from Steam on some platforms and not others,
  -- and joining onto one leaves an empty path component - which `..` and Steam's
  -- own folder scanner both read differently than the same path without it.
  local separator = platform.separator()
  local base = library_path:gsub("[/\\]+$", "")

  local parts = { base }
  for _, part in ipairs(STEAM_COMMON) do
    parts[#parts + 1] = part
  end
  if type(game_folder) == "string" and game_folder ~= "" then
    parts[#parts + 1] = game_folder
  end

  return platform.to_native(table.concat(parts, separator))
end

---Install, update or resume a game, as a job rather than a wait.
---
---legendary's `install` is also its update and its resume: pointed at a partial
---download, it continues from there.
---
---`library_path` is a Steam library folder, not the directory to install into:
---the path itself is assembled here so the separator is this platform's rather
---than whichever one the caller happened to write.
---@param app_name string
---@param library_path string|nil Steam library folder, legendary's default if nil
---@param game_folder string|nil Directory name inside it
---@return Job|nil job
---@return string? error
function legendary.install(app_name, library_path, game_folder)
  local binary, err = legendary.get_binary()
  if not binary then
    return nil, err
  end

  local args = { "-y", "install", app_name }

  if type(library_path) == "string" and library_path ~= "" then
    table.insert(args, "--base-path")
    table.insert(args, legendary.steam_install_path(library_path, game_folder))
    -- The folder name is the path's last component now, so passing it again
    -- would ask for `<base>/<folder>/<folder>`.
  elseif type(game_folder) == "string" and game_folder ~= "" then
    table.insert(args, "--game-folder")
    table.insert(args, game_folder)
  end

  return jobs.start(app_name, "install", binary, args)
end

---Update an already installed game, as a job.
---
---The same `install` underneath, since legendary fetches only the chunks that
---changed, but `--update-only` makes it refuse a game that isn't installed
---rather than quietly installing the whole thing.
---@param app_name string
---@return Job|nil job
---@return string? error
function legendary.update(app_name)
  local binary, err = legendary.get_binary()
  if not binary then
    return nil, err
  end

  return jobs.start(app_name, "update", binary, { "-y", "install", app_name, "--update-only" })
end

---@param app_name string
---@return Job|nil job
---@return string? error
function legendary.uninstall(app_name)
  local binary, err = legendary.get_binary()
  if not binary then
    return nil, err
  end

  return jobs.start(app_name, "uninstall", binary, { "-y", "uninstall", app_name })
end

-- Launching ------------------------------------------------------------------

-- A shortcut runs the game through legendary, so the game sits in Steam's own
-- library: Steam times it, names it as currently playing, and draws the overlay
-- over it. legendary waits on the game process rather than exiting once the
-- launcher is up, which is what makes those three work - and it is also what
-- keeps a game needing an online login able to have one.
--
-- On Windows that is the whole story: legendary launches the game's own
-- executable and Windows runs it.
--
-- On Linux the game's executable is a Windows program, so something has to put
-- Wine or Proton in front of it, and legendary's answer is `wine` - which is
-- either not installed or, on a gaming machine, an older build than the one
-- Steam itself ships. The machine's Steam already has Proton (GE, or whatever
-- the user chose), and it knows how to configure a prefix for it; `umu-run` is
-- the standard way to reach that from outside the client, which is why every
-- other launcher for these stores does exactly this.
--
-- So on Linux the shortcut is legendary, and legendary is told to put umu-run
-- in front of the game rather than a Wine of its own. Everything after that -
-- the prefix, the Proton build, the compatibility data - is Steam's, and a game
-- installed outside Steam behaves the way the user expects it to.
--
-- The direction of that is not negotiable, and getting it backwards is silent:
-- `umu-run <game-id> <command>` takes a *umu id* as its first argument, not a
-- program. A shortcut whose exe is umu-run and whose arguments are the legendary
-- call therefore asks umu to launch a game called "launch", running the Linux
-- legendary binary inside Wine - which cannot execute at all, so nothing happens
-- and nothing is logged. legendary is a Linux program and runs natively; umu is
-- only ever the wrapper around the game's Windows executable.

---The umu-run binary, or nil when this machine has no umu installed.
---
---A hit is remembered: it is asked for on every sync, and the answer cannot
---change while Steam is running. A miss is not, because the one thing that makes
---it wrong is installing umu - which is exactly what a user who has just read
---the log telling them to do it will do, and a game that cannot be started at
---all until they restart Steam is a poor reward for that. The scan is a handful
---of stat calls, so repeating it costs nothing worth caching around.
---@type string|nil
local umu_binary = nil

---Whether the "no umu here" warning has been said. Once, because it is in the log
---a user reads when a game will not start, and a sync of 548 games would
---otherwise write it 548 times.
local umu_missing = false

---@return string|nil path
function legendary.umu_run()
  if umu_binary then
    return umu_binary
  end

  -- Windows launches these games directly, so umu is never looked for there.
  if platform.IS_WINDOWS then
    return nil
  end

  local found = "umu-run"
  for _, directory in ipairs(utils.split(utils.getenv("PATH") or "", ":")) do
    if directory ~= "" then
      local candidate = directory .. "/" .. found
      if fs.is_file(candidate) then
        umu_binary = candidate
        logger:info("Games will launch through " .. candidate)
        return umu_binary
      end
    end
  end

  if not umu_missing then
    umu_missing = true
    logger:warn(
      "umu-run is not installed, so games will launch through whatever Wine legendary "
        .. "finds. Install umu-launcher to use Steam's Proton instead."
    )
  end

  return nil
end

---The command one game's shortcut should run, as its exe and its arguments.
---
---The exe is a script the plugin writes, not legendary itself: Steam starts a
---shortcut's program with an environment of its own making, and a PyInstaller
---build like legendary does not always survive it. The script clears what Steam
---sets that breaks such a program, and records what legendary and the game
---wrapper print - which a failing non-Steam shortcut otherwise never tells
---anyone, since Steam has no window and no log for it.
---
---The arguments are nothing at all, which is the whole shape of this function
---now. The game's id travels in the program instead - a file per game, named
---after it - so the shortcut's launch options are left empty and belong to the
---user: what they type there is passed to the game. Everything else a launch
---needs - umu-run, the Proton build, the default words in front of the game - is
---written into the shared script, because a value inside a shortcut's launch
---options is a value baked into all 551 of them.
---
---That also fixes the two parsers. Steam splits the launch options with its own
---rules and does not decode backslashes, and legendary then splits the wrapper
---again with `shlex`, so a Proton build - whose name always has a space in it -
---arrived in three pieces. A shell here is one parser and one quoting style.
---@param app_name string
---@param title string|nil The game's name, which names its program
---@param install_path string|nil The game's own folder, where its program goes
---@return string|nil exe
---@return string|nil arguments
function legendary.launch_command(app_name, title, install_path)
  local binary, err = legendary.get_binary()
  if not binary then
    return nil, err
  end

  -- Windows launches the game's own executable directly, with no umu in front
  -- of it, so there is no wrapper to write and the binary is the program.
  if platform.IS_WINDOWS then
    return binary, "launch " .. platform.quote_argument(app_name)
  end

  local umu_run = legendary.umu_run()
  local shared, script_error = launcher.ensure(binary, umu_run)
  if not shared then
    return nil, script_error
  end

  -- The program named after this game, which is what carries the id. Empty
  -- arguments: that box is the user's, and the only thing that belongs in it is
  -- what they chose to put there. It goes in the game's own folder when there is
  -- one, so both of the paths Steam shows are the game.
  local program, program_error = launcher.game_program(app_name, title, install_path)
  if not program then
    return nil, program_error
  end

  return program, ""
end

-- Cloud saves ----------------------------------------------------------------

-- `legendary sync-saves` for one game, or for everything installed when no game
-- is named. `-y` answers the prompts: without a save path recorded for a title
-- it computes one and asks whether it is right, which is a question with no
-- answer here - the two `sync-saves` flags below stop it from ever getting that
-- far, at the cost of the sync being one way.
--
-- `--skip-upload` downloads what Epic has, `--skip-download` uploads what is
-- here. Neither is the default: without one, legendary syncs in both
-- directions, preferring whichever side is newer, and only asks when it cannot
-- tell. That is the one to use, and what the panel's button runs.

---@alias SaveDirection "both" | "download" | "upload"

---The arguments for one save sync.
---@param app_name string|nil Which game, or every installed one
---@param direction SaveDirection|nil Which way, both by default
---@return string[]
function legendary.sync_saves_args(app_name, direction)
  local args = { "-y", "sync-saves" }

  if type(app_name) == "string" and app_name ~= "" then
    table.insert(args, '"' .. app_name .. '"')
  end

  if direction == "download" then
    table.insert(args, "--skip-upload")
  elseif direction == "upload" then
    table.insert(args, "--skip-download")
  end

  return args
end

---Whether Epic has cloud saves for a game at all.
---
---Out of the catalog `legendary list` already brought in, rather than a command
---per game: this is a single custom attribute, and asking Epic about it costs a
---manifest fetch each time.
---@param entry table One element of `legendary list`
---@return boolean
function legendary.supports_cloud_saves(entry)
  local attributes = ((entry.metadata or {}).customAttributes or {})
  return attributes.CloudSaveFolder ~= nil
end

---A sync still running, by key, so asking twice waits on the one in flight.
---
---Keyed by game rather than by request: two syncs of the same game are the same
---sync, and the second one should join the first rather than start its own.
---@type table<string, string>
local syncing = {}

---Sync one game's cloud saves, or every installed game's.
---
---Started and collected the way `get_size` and `get_achievements` are, rather
---than waited on: it is a handful of small files in each direction, but it is
---still a round trip to Epic, and holding the Lua state for it would freeze
---every other plugin call while it runs. So a first call starts the command and
---says so, and the caller asks again until there is an answer.
---@param app_name string|nil Which game, or every installed one
---@param direction SaveDirection|nil Which way, both by default
---@return boolean|nil ok
---@return string? error
---@return string? summary What it did, on success
---@return boolean? still_running The command has been started, ask again shortly
function legendary.sync_saves(app_name, direction)
  local key = (app_name or "") .. "/" .. tostring(direction or "both")

  local id = syncing[key]
  if not id then
    local started, err = legendary.start(legendary.sync_saves_args(app_name, direction))
    if not started then
      return nil, err
    end

    syncing[key] = started
    return nil, nil, nil, true
  end

  local output, status = legendary.collect(id)
  if not output then
    return nil, nil, nil, true
  end
  syncing[key] = nil

  -- A save sync for a title Epic has nothing for is not a failure, and neither is
  -- one that found nothing to move - so what is reported is what happened rather
  -- than a bare "ok". `sync-saves` exits 0 for both, which is why the exit code
  -- alone would answer nothing useful here.
  local uploaded = 0
  local downloaded = 0
  local skipped = 0
  for line in output:gmatch("[^\r\n]+") do
    if line:find("Uploading save game") or line:find("Uploaded save") then
      uploaded = uploaded + 1
    elseif line:find("Downloading save") then
      downloaded = downloaded + 1
    elseif line:find("skipping due to --yes") or line:find("Nothing to upload") then
      skipped = skipped + 1
    end
  end

  if status ~= 0 then
    return nil,
      legendary.last_error(output)
        or ("The save sync exited " .. status .. ": " .. utils.trim(output):sub(1, 200))
  end

  local summary = "Checked "
    .. tostring(uploaded + downloaded + skipped)
    .. " game"
    .. ((uploaded + downloaded + skipped) == 1 and "" or "s")
    .. ", uploaded "
    .. uploaded
    .. ", downloaded "
    .. downloaded
  if skipped > 0 then
    summary = summary .. ", " .. skipped .. " had no save folder set up yet"
  end

  logger:info("Cloud saves: " .. summary)
  return true, nil, summary
end

-- Authentication --------------------------------------------------------------

-- `legendary auth --import` would lift a login out of the Epic Games Launcher
-- with no browser at all, but Epic allows one session per client id: importing
-- signs the user out of the launcher. Not something to do behind their back.

---Where legendary keeps the signed-in session.
---
---Its own default, which is also where `entitlements.lua` reads its cache from,
---so the two cannot drift onto different directories.
---@return string
local function session_path()
  return platform.config_path() .. "/legendary/user.json"
end

---Put the current session somewhere safe, because trying a new code destroys it.
---
---`legendary auth --code` clears the stored login before it tries the code it
---was given. That is the right thing for a command line, where the code always
---comes from a login the user just did - but here the code is pasted by hand
---and is wrong often enough to matter: a mistimed paste, a code from a previous
---attempt, a stray character. Without this, every one of those mistakes signs
---the user out of a working session.
---@return string|nil backup Where the session was copied, if it was
local function stash_session()
  local session = session_path()
  if not fs.is_file(session) then
    return nil
  end

  local backup = session .. ".plugin-backup"
  if not fs.copy(session, backup) then
    logger:warn("Could not back the Epic session up before signing in")
    return nil
  end

  return backup
end

---Put a stashed session back, so a rejected code costs nothing.
---@param backup string|nil
local function restore_session(backup)
  if not backup then
    return
  end

  if not fs.copy(backup, session_path()) then
    logger:error("Could not put the Epic session back after a failed sign in")
    return
  end

  fs.remove(backup)
end

---Finish a sign in with the code from Epic's redirect page.
---
---`--code` is the non-interactive form. Plain `legendary auth` blocks on stdin
---waiting for the code, and there is no stdin here.
---
---legendary exits 0 even when a login fails, so success is read by asking it who
---it thinks we are afterwards.
---@param code string The authorizationCode from Epic's redirect page
---@return boolean success
---@return string? error
function legendary.authenticate(code)
  if type(code) ~= "string" or utils.trim(code) == "" then
    return false, "No code provided"
  end

  local backup = stash_session()

  local output = legendary.run({ "auth", "--code", utils.trim(code) })
  if legendary.get_status(true).authenticated then
    -- The new session is the one that is wanted, so the old copy is now litter.
    if backup then
      fs.remove(backup)
    end
    return true
  end

  -- The attempt cost the previous session whatever it cost: put it back, so a
  -- bad paste is a message rather than a sign out. The status is re-read
  -- afterwards because the cached one describes the session that no longer
  -- exists, and the panel is about to be told who is signed in.
  restore_session(backup)
  if backup then
    legendary.get_status(true)
  end

  return false,
    legendary.last_error(output)
      or "That code didn't work, it may have expired or already been used. Press Sign in for a fresh one."
end

---Sign out, so the next sign in starts clean.
---@return boolean success
function legendary.sign_out()
  legendary.run({ "auth", "--delete" })
  return not legendary.get_status(true).authenticated
end

return legendary
