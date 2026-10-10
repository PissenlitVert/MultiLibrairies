local fs = require("fs")
local json = require("json")
local logger = require("logger")
local utils = require("utils")

-- The plugin's own settings, in one JSON file a person can edit.
--
-- Why a file and not the plugin manifest: Millennium's schema has no settings
-- object, and a settings dialog built out of a context menu is a poor place to
-- type a Proton build's name - which is spelled with a space and a capital
-- letter, and which the menu has to offer from a directory scan anyway.
--
-- So `backend/data/config.json` is the whole surface. It is written by the menu
-- and read by the launcher, and a person can open it in an editor and change one
-- line. Every unknown key is kept, so a setting added by a later version is not
-- deleted by an earlier one writing the file back, and every unreadable value
-- falls back to the default rather than stopping the plugin: a settings file
-- with a typo in it must not be able to stop someone's games from starting.
--
-- It lives under `backend/data` rather than beside the other files, next to the
-- cache and the queue, because it is state: deleting it resets the plugin's
-- settings, which is a reasonable thing to want and not a reasonable accident.

local config = {}

---The file every setting is kept in.
---@return string path
function config.path()
  return utils.get_backend_path() .. "/data/config.json"
end

---What a setting is when it has not been set, or was set to something the
---plugin does not understand.
---
---Kept beside the reader rather than in the reader, so a value's type and its
---default cannot drift apart: a `false` default for a setting that means "yes"
---is a bug that reads as a feature.
local DEFAULTS = {
  -- Which Proton build the Epic games run through, by directory name as Steam
  -- spells it. Empty means umu's own default, which is not necessarily one that
  -- can decode video - see `umu.can_decode_video`.
  proton = "",
  -- Wrapped around the game before umu is started: `mangohud gamemode`,
  -- `gamescope`, `strangle`. Empty means nothing in front.
  --
  -- Here rather than in the shortcut's launch options, because Steam appends
  -- that text *after* the whole command: a word typed there reaches legendary as
  -- an argument it ignores, and the game is then launched with no Proton at all.
  -- The words have to sit inside the `--wrapper` string, which is split twice -
  -- by Steam, and then by legendary's `shlex.split`. See `legendary.launch_command`.
  launch_options = "",
}

---A copy of the defaults, written out rather than handed back.
---
---The table is a module-level constant and the copy is shallow, which is enough
---because every value in it is a string: a caller that assigns to the returned
---table cannot reach the constant, and nothing can assign through it.
---@return table
local function defaults()
  local copy = {}

  for key, value in pairs(DEFAULTS) do
    copy[key] = value
  end

  return copy
end

---Every setting, with the ones that are not set filled in.
---@return table
function config.all()
  local content = utils.read_file(config.path())
  if not content then
    return defaults()
  end

  local ok, decoded = pcall(json.decode, content)

  if not ok or type(decoded) ~= "table" then
    -- Named in the log rather than shown: the panel has no way to say "your
    -- settings file is malformed" without becoming a second thing to read, and
    -- the file is small and hand-edited enough that a syntax error is the kind
    -- of thing a bug report should carry.
    logger:warn(
      "config.json is not readable JSON, using the defaults instead: "
        .. tostring(config.path())
    )
    return defaults()
  end

  local merged = defaults()

  for key, value in pairs(decoded) do
    merged[key] = value
  end

  return merged
end

---One setting, or its default.
---@param key string
---@return any
function config.get(key)
  return config.all()[key]
end

---Change some settings, leaving the rest of the file alone.
---
---Read-modify-write rather than a whole document from the caller, because the
---two writers - the menu and a person with the file open in an editor - must not
---erase each other. The file is rewritten whole either way, so an edit made
---while the menu was writing is still lost; there is no locking here and no
---claim of one.
---@param changes table
---@return boolean ok
---@return string? error
function config.update(changes)
  if type(changes) ~= "table" then
    return false, "no settings were given"
  end

  local current = config.all()

  for key, value in pairs(changes) do
    current[key] = value
  end

  local path = config.path()
  fs.create_directories(fs.parent_path(path))

  -- Through a temporary file, so an interrupted write cannot leave a truncated
  -- document behind - which for this file would mean every setting gone rather
  -- than one.
  local temp_path = path .. ".tmp"
  local ok, err = utils.write_file(temp_path, json.encode(current))

  if not ok then
    return false, "could not write " .. temp_path .. ": " .. tostring(err)
  end

  if fs.is_file(path) and not fs.remove(path) then
    return false, "could not replace " .. path
  end

  if not fs.rename(temp_path, path) then
    return false, "could not rename " .. temp_path
  end

  return true
end

---Set one string setting, refusing anything that is not a string.
---
---The type check is the point: a number or an object where a string is expected
---would otherwise reach a shell line and be interpolated into it, and a value
---read out of a hand-edited file is exactly as likely to be the wrong type as
---one written by the panel.
---@param key string
---@param value string
---@return boolean ok
---@return string? error
function config.set_string(key, value)
  if type(value) ~= "string" then
    return false, key .. " must be text, not " .. type(value)
  end

  return config.update({ [key] = utils.trim(value) })
end

return config