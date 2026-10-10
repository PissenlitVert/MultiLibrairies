local fs = require("fs")
local millennium = require("millennium")
local utils = require("utils")

-- A reader for `shortcuts.vdf`, which is where Steam keeps every non-Steam
-- shortcut and the only place the truth about one is written down.
--
-- Reading it is the answer to a question no API can answer: when the plugin
-- calls `SetShortcutExe` on 548 shortcuts, nothing comes back, and some client
-- builds quietly ignore it. From here the shortcut can be *looked at* - the
-- program Steam will really run, the arguments, the icon - and compared with
-- what the plugin meant to write. A shortcut that did not take is otherwise
-- indistinguishable from a game that failed to start.
--
-- Read-only on purpose. Writing binary VDF by hand is how a plugin corrupts a
-- user's library, and the API that allocates appids is the one that has to do
-- the allocating.
--
-- The format, confirmed against a real 613-shortcut file:
--
--   <type><key NUL><value>   repeated, then 0x08 to close the run
--
-- `0x08` closes a map, `0x01` is a NUL-terminated string, `0x02` a little-endian
-- uint32, and `0x00` opens a map whose *value* is another run of entries. So a
-- file is: `0x00 "shortcuts" NUL`, then a map of index keys whose values are
-- maps of field names. `tags` is the only field of a shortcut that is itself a
-- map, and nothing here reads it.

local vdf = {}

---@class ShortcutFields
---@field appid integer
---@field AppName string|nil
---@field exe string|nil
---@field LaunchOptions string|nil
---@field StartDir string|nil
---@field icon string|nil
---@field IsHidden integer|nil
---@field LastPlayTime integer|nil

---The type byte for a little-endian uint32.
local UINT32 = 0x02

---Bytes a fixed-width value occupies, by type byte. Types outside this table are
---a format this reader does not know, and stop the walk rather than being guessed
---at: a misread offset makes every field after it nonsense, which is worse than
---no answer.
local WIDTHS = {
  [0x03] = 8,
  [0x04] = 4,
  [0x05] = 4,
  [0x06] = 8,
  [0x07] = 4,
}

---The type byte for a NUL-terminated string.
local STRING = 0x01

---The byte that closes a map.
local END_OF_MAP = 0x08

---The byte that opens one.
local MAP = 0x00

---Where Steam keeps this user's shortcuts.
---
---`account_id` is the 32-bit account id, which is what names the userdata folder.
---Without it, a machine with more than one account is refused rather than guessed
---at - reading another account's shortcuts would answer questions about the wrong
---library, and a machine with one account (the normal case) never needs it.
---@param account_id integer|string|nil
---@return string|nil path
---@return string? error
local function shortcuts_path(account_id)
  local userdata = millennium.steam_path() .. "/userdata"

  ---@type string|nil
  local account = tostring(account_id or "")
  if account ~= "" and fs.is_directory(userdata .. "/" .. account) then
    return userdata .. "/" .. account .. "/config/shortcuts.vdf"
  end

  local accounts = fs.list(userdata)

  if not accounts then
    return nil, "no Steam userdata folder at " .. userdata
  end

  local found = nil
  for _, entry in ipairs(accounts) do
    -- "0" is Steam's placeholder for "no account", and with more than one real
    -- account there is no basis for guessing which one is signed in.
    if entry.is_directory and entry.name ~= "0" then
      if found then
        return nil, "several Steam accounts on this machine"
      end
      found = entry.name
    end
  end

  if not found then
    return nil, "no Steam account folder in " .. userdata
  end

  return userdata .. "/" .. found .. "/config/shortcuts.vdf"
end

---The index of the next NUL at or after `position`, which is where a
---NUL-terminated string ends.
---@param bytes string
---@param position integer
---@return integer|nil index
local function nul_at(bytes, position)
  return bytes:find("\0", position, true)
end

---One run of entries, up to and including the byte that closes it.
---
---`fields` is filled in place, so the two maps in a shortcut file - the index
---keys and the fields of each shortcut - are read by the same code at the two
---depths it is called at.
---@param bytes string
---@param position integer
---@param fields table
---@param depth integer 0 for the outermost run, 1 for a shortcut's own fields
---@return integer|nil next position
---@return string|nil error
local function read_entries(bytes, position, fields, depth)
  while position <= #bytes do
    local kind = bytes:byte(position)

    if kind == END_OF_MAP then
      return position + 1, nil
    end

    -- The type byte comes first and describes the *value*; the key is a plain
    -- NUL-terminated string either way.
    local after_key = nul_at(bytes, position + 1)
    if not after_key then
      return nil, "unterminated key at " .. tostring(position)
    end

    local key = bytes:sub(position + 1, after_key - 1)

    if kind == MAP then
      -- A nested map: its value is another run, and what it holds is this
      -- entry's value.
      local nested = {}
      local next_position, err = read_entries(bytes, after_key + 1, nested, depth + 1)
      if not next_position then
        return nil, err
      end
      fields[key] = nested
      position = next_position
    elseif kind == STRING then
      local after_value = nul_at(bytes, after_key + 1)
      if not after_value then
        return nil, "unterminated value for " .. key
      end
      fields[key] = bytes:sub(after_key + 1, after_value - 1)
      position = after_value + 1
    elseif kind == UINT32 then
      if after_key + 4 > #bytes then
        return nil, "truncated value for " .. key
      end
      -- Decoded rather than kept as the four bytes it is written as: an appid
      -- is the key everything below is looked up by, and comparing raw bytes
      -- against a number would never match.
      local b1, b2, b3, b4 = bytes:byte(after_key + 1, after_key + 4)
      fields[key] = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
      position = after_key + 5
    elseif WIDTHS[kind] then
      local width = WIDTHS[kind]
      if after_key + width > #bytes then
        return nil, "truncated value for " .. key
      end
      -- The other fixed-width types are not read by name, so they are skipped
      -- rather than guessed at. A wrong offset would make every field after it
      -- nonsense, which is worse than no answer.
      fields[key] = bytes:sub(after_key + 1, after_key + width)
      position = after_key + 1 + width
    else
      return nil, "unknown value type " .. tostring(kind) .. " for " .. key
    end
  end

  return position, nil
end

---Every shortcut Steam has, keyed by appid.
---
---The file itself is keyed by a plain index, and that index is not the appid: in
---a real library all 613 entries differ. `appid` is a field *inside* each entry,
---and it is the one the frontend's own map holds, so it is the key here - looking
---shortcuts up by index would silently audit the wrong ones.
---@param account_id integer|string|nil
---@return table<string, ShortcutFields>|nil shortcuts
---@return string? error
function vdf.read_shortcuts(account_id)
  local path, err = shortcuts_path(account_id)
  if not path then
    return nil, err
  end

  local bytes = utils.read_file(path)
  if not bytes then
    return nil, "could not read " .. path
  end

  -- Skip the root: its type byte is at 1, its key runs from 2, and the map
  -- itself starts at the byte after the key's NUL. Searching from 1 would find
  -- the root's own type byte - it is a NUL too - and hand back the file.
  local after_root = nul_at(bytes, 2)
  if not after_root then
    return nil, "no root key in " .. path
  end

  local indexed = {}
  local next_position, walk_error = read_entries(bytes, after_root + 1, indexed, 0)
  if not next_position then
    return nil, walk_error
  end

  local shortcuts = {}
  for _, fields in pairs(indexed) do
    if type(fields) == "table" and type(fields.appid) == "number" then
      shortcuts[tostring(fields.appid)] = fields
    end
  end

  return shortcuts, nil
end

---The fields of one shortcut, by appid.
---@param app_id integer|string
---@param account_id integer|string|nil
---@return ShortcutFields|nil
---@return string? error
function vdf.read_shortcut(app_id, account_id)
  local shortcuts, err = vdf.read_shortcuts(account_id)
  if not shortcuts then
    return nil, err
  end

  local entry = shortcuts[tostring(app_id)]
  if not entry then
    return nil, "no shortcut with appid " .. tostring(app_id)
  end

  return entry, nil
end

return vdf