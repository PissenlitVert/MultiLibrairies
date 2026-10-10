-- What each installed game actually runs, remembered one file per game.
--
-- This exists for one case: a shortcut that Steam has decided to start inside a
-- Proton build, which is what choosing one in Properties > Compatibility does.
-- In there umu cannot be used - the prefix has its own `/usr`, so a
-- `#!/usr/bin/python3` program is not found - so the game is started directly by
-- the Proton's own wine. That needs the game's executable, and the obvious place
-- to read it, Epic's manifest, is encrypted: `~/.config/legendary/manifests/*.-
-- manifest` is a binary blob only legendary can open.
--
-- So legendary is asked, once per installed game, and the answer is written to a
-- file the launch script can read with `cat`. One file per game rather than one
-- JSON document, because the script has no JSON parser and a grep for a key in a
-- 548-game document is a way to start the wrong game.
--
-- The answer is never guessed. A game whose executable is not known yet is not
-- launched through this route at all: the script says so and stops, rather than
-- handing a prefix an empty program.

local fs = require("fs")
local json = require("json")
local logger = require("logger")
local shell = require("shell")
local trace = require("trace")
local utils = require("utils")

local exes = {}

---Questions in flight, one per game, so a sync that walks the library twice
---does not start the same command twice.
---@type table<string, string>
local pending = {}

---Where the answers are kept: inside the plugin's own cache, one file per game,
---named by Epic's app id, which is what the launch script has to hand.
---@return string
local function directory()
  return utils.get_backend_path() .. "/data/cache/exes"
end

---The file one game's answer lives in.
---@param app_name string
---@return string
function exes.path(app_name)
  return directory() .. "/" .. app_name
end

---What this game runs, when it is already known.
---@param app_name string
---@return string|nil path
function exes.get(app_name)
  local value = utils.read_file(exes.path(app_name))

  if type(value) ~= "string" then
    return nil
  end

  value = utils.trim(value)

  return value ~= "" and value or nil
end

---Pull the executable and the install folder out of `legendary info --json`.
---
---The command writes its own log line before the document - `[Core] INFO: Trying
---to re-use existing login session...` - so the walk starts at the first brace
---rather than at the first character.
---@param output string
---@return string|nil path
local function parse(output)
  local start = output:find("{", 1, true)

  if not start then
    return nil
  end

  local ok, decoded = pcall(json.decode, output:sub(start))

  if not ok or type(decoded) ~= "table" then
    return nil
  end

  local install = type(decoded.install) == "table" and decoded.install or {}
  local manifest = type(decoded.manifest) == "table" and decoded.manifest or {}
  local folder = install.install_path
  local exe = manifest.launch_exe

  if type(folder) ~= "string" or type(exe) ~= "string" then
    return nil
  end

  folder = folder:gsub("[/\\]+$", "")
  exe = exe:gsub("^[/\\]+", "")

  if folder == "" or exe == "" then
    return nil
  end

  return folder .. "/" .. exe
end

---Write one answer down.
---@param app_name string
---@param path string
---@return string path
local function remember(app_name, path)
  fs.create_directories(directory())

  if not utils.write_file(exes.path(app_name), path .. "\n") then
    logger:warn("Could not remember the executable of " .. app_name)
  end

  logger:info(app_name .. " runs " .. path)

  return path
end

---Make sure this game's executable is on disk, asking legendary if it is not.
---
---Asynchronous on purpose: this is called from the sync that walks the whole
---library, and `legendary info` takes about a second per game. Started on the
---first pass, collected on a later one, which the sync does by itself.
---@param app_name string
---@param binary string|nil legendary's own path, if it is installed
---@return string|nil path What is known now, if anything
function exes.ensure(app_name, binary)
  if type(app_name) ~= "string" or app_name == "" or type(binary) ~= "string" then
    return nil
  end

  local known = exes.get(app_name)

  if known then
    return known
  end

  local id = pending[app_name]

  if not id then
    local started = shell.start(binary, { "info", app_name, "--json" })

    if not started then
      -- No command daemon on this machine. Not a reason to refuse: this is one
      -- short local read, and a game that cannot be launched through Steam's own
      -- Proton is a worse outcome than a second of waiting.
      local output, status = shell.run(binary, { "info", app_name, "--json" })

      if status ~= 0 then
        trace.event("exes.info_failed", { app_name = app_name, status = status })
        return nil
      end

      local path = parse(output or "")

      return path and remember(app_name, path) or nil
    end

    pending[app_name] = started
    return nil
  end

  local output, status = shell.poll(id)

  if not output then
    return nil
  end

  pending[app_name] = nil

  if status ~= 0 then
    trace.event("exes.info_exited", { app_name = app_name, status = status })
    return nil
  end

  local path = parse(output)

  return path and remember(app_name, path) or nil
end

---Forget a game's executable, for after an install or an uninstall.
---
---An install can change which build is there and an uninstall removes the folder
---the answer names, so an answer kept across either is an answer pointing at
---nothing.
---@param app_name string
function exes.forget(app_name)
  pending[app_name] = nil

  local path = exes.path(app_name)

  if fs.is_file(path) then
    fs.remove(path)
  end
end

return exes