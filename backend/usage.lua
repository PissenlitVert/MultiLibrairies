local cache = require("cache")
local logger = require("logger")
local shell = require("shell")
local trace = require("trace")
local utils = require("utils")

-- How much disk the installed Epic games actually take.
--
-- Steam's own Settings > Storage page cannot answer this for a non-Steam
-- shortcut, which is the whole reason this exists: that page is built out of
-- Steam's own install manifests, and a shortcut has none. It is also why the
-- plugin installs into `steamapps/common` anyway - so the files sit where a
-- person looking for them expects to find them, and so anything Steam *does*
-- know how to measure can find them - but the measurement itself has to be ours.
--
-- `legendary list-installed` reports an install size, and it is what the game
-- *should* occupy. It is not what it occupies: patches, shader caches, log files
-- and whatever a mod manager dropped in all land in the same folder, and on a
-- large install those add up to tens of gigabytes nobody can account for. So
-- this measures the folder.
--
-- `du -b`, started and collected rather than waited on, for the reason a game's
-- size is: a 200 GB install takes seconds to walk, which is far too long to hold
-- the one Lua state every other RPC goes through. A first call starts it and says
-- so; the caller asks again. Cached by path, so a second answer is free until
-- something is installed or removed.

local usage = {}

---Where the answers are kept between runs.
local CACHE_PATH = utils.get_backend_path() .. "/data/cache/usage.json"

---@class GameUsage
---@field bytes integer What is really on disk
---@field path string Which folder that was, so a moved game is measured again

---@type table<string, GameUsage>|nil
local known = nil

---The `du` still running, by app name, so asking twice waits on the one in flight.
---@type table<string, string>
local measuring = {}

local function load()
  known = cache.read(CACHE_PATH, "usage") or {}
  return known
end

local function save()
  cache.write(CACHE_PATH, known, "usage")
end

---`du`'s own answer, or nil when it printed nothing usable.
---
---`du -s -b` prints one line - the total, a tab, and the path - and nothing
---else. `-a` is deliberately not used: it lists every file, and an install with
---a hundred thousand of them would push a hundred thousand lines through the
---command daemon to produce a number already on the last one.
---@param output string
---@return integer|nil bytes
local function parse(output)
  return tonumber(output:match("^%s*(%d+)"))
end

---Record a measurement, and say what it came to.
---
---One place for both routes into an answer - the daemon's and the direct one -
---so a game measured either way is cached the same way.
---@param app_name string
---@param install_path string
---@param bytes integer|nil
---@return integer|nil bytes
local function record(app_name, install_path, bytes)
  if not bytes then
    logger:warn("Could not measure " .. app_name)
    return nil
  end

  known = known or load()
  known[app_name] = { bytes = bytes, path = install_path }
  save()

  logger:info("Measured " .. app_name .. ": " .. bytes .. " bytes on disk")
  return bytes
end

---What one installed game occupies on disk.
---
---Answered from the cache when the folder has not moved. `refresh` measures
---again, which is what a finished install asks for - the whole point of the
---measurement is that it disagrees with what Epic says, and a stale answer after
---an install is worse than none.
---@param app_name string
---@param install_path string
---@param refresh boolean|nil Measure again even if the answer is cached
---@return integer|nil bytes
---@return boolean|nil still_running The measurement has started, ask again shortly
function usage.for_game(app_name, install_path, refresh)
  known = known or load()

  local previous = known[app_name]
  if previous and not refresh and previous.path == install_path then
    return previous.bytes
  end

  local id = measuring[app_name]
  if not id then
    -- `-s` so one line comes back, `-b` so it is bytes rather than 1K blocks:
    -- a block count times 1024 is what Steam shows for a Steam game, and this
    -- has to be comparable with those numbers to be worth anything.
    local started, err = shell.start("du", { "-s", "-b", install_path })
    if not started then
      -- No command daemon on this machine, which `shell.run` copes with by
      -- spawning the command itself. So does this: a measurement that is
      -- unavailable is worse than one that briefly blocks, and a `du` of one
      -- directory is a local read of a directory tree rather than anything a
      -- person is waiting on.
      trace.event("usage.du_without_daemon", { app_name = app_name })
      return record(app_name, install_path, (shell.run("du", { "-s", "-b", install_path })))
    end

    measuring[app_name] = started
    return nil, nil, true
  end

  local output, status = shell.poll(id)
  if not output then
    return nil, nil, true
  end
  measuring[app_name] = nil

  -- `du` exits non-zero on a directory it could not read, which happens for a
  -- game folder with a broken symlink in it and is not a reason to throw the
  -- whole answer away: whatever it managed to count is still counted.
  if status ~= 0 then
    trace.event("usage.du_partial", { app_name = app_name, status = status })
  end

  local bytes = parse(output)
  if not bytes then
    return nil
  end

  return record(app_name, install_path, bytes)
end


---Drop what is known about a game, for after an install or an uninstall.
---
---Not merely tidy: after an uninstall the answer would be the size the game used
---to be, and a storage view that keeps showing it is exactly the thing that
---makes someone think the uninstall failed.
---@param app_name string
function usage.forget(app_name)
  known = known or load()

  if known[app_name] then
    known[app_name] = nil
    save()
  end
end

---Free a measurement still running for a game, so it is not polled for ever.
---@param app_name string
function usage.stop(app_name)
  measuring[app_name] = nil
end

---Whether a walk is in flight for this game right now.
---
---The question that separates "wait, it is still working" from "there is
---nothing there to measure", which look identical in the answer: both come back
---as no size. They are not the same to act on. The first wants waiting - a `du`
---of a 200 GB install on its own filesystem takes far longer than anyone would
---guess - and the second wants giving up, because asking again runs the same walk
---over the same empty folder and comes back with the same nothing.
---@param app_name string
---@return boolean
function usage.is_measuring(app_name)
  return measuring[app_name] ~= nil
end

return usage