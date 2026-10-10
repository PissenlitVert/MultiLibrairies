local fs = require("fs")
local logger = require("logger")
local millennium = require("millennium")
local utils = require("utils")
local vdf = require("vdf")

-- Steam's grid folder is where custom artwork ends up, and a shortcut's icon is
-- the one piece of it that is not an API call: `shortcuts.vdf` holds a *path*,
-- pointing at `<grid>/<appid>_icon.png`, and Steam reads the file from there.
--
-- The bytes come from the frontend, which is the only half of this plugin that
-- can fetch an image or draw one. What arrives here is either nothing - the
-- right name is already there - or a base64 PNG to put there.
--
-- The mistake this replaces is asking Steam to write the file and then looking
-- for it: `SetCustomArtworkForApp` returns before the client has written
-- anything, so the rename that followed found no file, every shortcut kept an
-- empty `icon`, and the only trace was a debug line nobody reads. It also
-- wrote the wrong bytes for the wrong games: Icon artwork lands at
-- `<grid>/<appid>.png`, which is the same name a PNG header takes, so the
-- header applied afterwards quietly replaced it.
--
-- Writing the file ourselves is the way out of both: no waiting, and a name
-- nothing else competes for.

local grid = {}

---The width and height an icon is drawn at, in pixels.
---
---Frontend/services/icons.ts crops to this, and it is the only thing the adopt
---path below can recognise an icon by - so the two have to agree, and neither
---can be changed without the other.
local ICON_SIZE = 256

---An appid as a file name spells it: unsigned.
---
---Steam's API and `shortcuts.vdf` both carry a non-Steam appid as a *signed*
---32-bit integer - 2 435 244 972 arrives as -1 859 722 324 - and every name in
---the grid folder is spelled unsigned. Passing the signed form on gives
---`-1001381534_icon.png`, a file Steam never looks at: correct for every
---`SteamClient` call, wrong for anything written to disk.
---@param app_id integer|string
---@return integer|string
local function unsigned(app_id)
  local id = tonumber(app_id)
  if not id or id >= 0 then return app_id end

  return id + 4294967296
end

---Where Steam keeps the custom artwork it's been given for this user.
---
---`account_id` is the 32-bit account id, not the 64-bit SteamID: that's what
---names the userdata folder. Falls back to the only folder present, which is
---the normal case on a single-account machine.
---@param account_id integer|string|nil
---@return string|nil path
---@return string? error
function grid.path(account_id)
  local userdata = millennium.steam_path() .. "/userdata"

  ---@type string|nil
  local account = tostring(account_id or "")
  if account == "" or not fs.is_directory(userdata .. "/" .. account) then
    account = nil

    for _, entry in ipairs(fs.list(userdata) or {}) do
      -- "0" is Steam's placeholder for "no account", and with more than one we
      -- have no business guessing which is signed in.
      if entry.is_directory and entry.name ~= "0" then
        if account then
          return nil, "several Steam accounts on this machine"
        end
        account = entry.name
      end
    end
  end

  if not account then
    return nil, "no Steam userdata folder"
  end

  local path = userdata .. "/" .. account .. "/config/grid"
  fs.create_directories(path)

  return path
end

---Extensions an icon can arrive as. Ours is a PNG we draw ourselves, but the
---grid folder is shared with anything else that writes icons and SteamGridDB's
---are usually `.ico`. Deliberately not jpg: `<app_id>.jpg` is the header image,
---and looking for one would rename that into an icon.
local ICON_EXTENSIONS = { "png", "ico" }

-- Base64 ---------------------------------------------------------------------

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

---What each base64 character is worth, read from the alphabet once.
---@type table<string, integer>
local VALUES = {}
for index = 1, #ALPHABET do
  VALUES[ALPHABET:sub(index, index)] = index - 1
end

---Decode base64 back to the bytes it stands for.
---
---The inverse of what the browser's `toDataURL` does, and hand-written because
---Millennium's `utils` has an encoder and no decoder. Refuses rather than
---guesses: a PNG that has lost a byte somewhere on the way is worse than no icon
---at all, and a wrong answer here would be a file Steam tries to draw and
---cannot.
---@param value string
---@return string|nil bytes
---@return string? error
function grid.decode_base64(value)
  if type(value) ~= "string" or value == "" then
    return nil, "no base64 payload"
  end

  local out = {}
  -- The three bytes of the group being read, filled in six bits at a time from
  -- the top. A character carries the top six bits of the first byte, the bottom
  -- two of that byte and the top four of the next, and so on - which is why a
  -- group is assembled in place rather than summed and shifted afterwards: the
  -- group a `=` cuts short is the same shape, only with bytes missing at the
  -- end.
  local first, second, third = 0, 0, 0
  local count, padding = 0, 0

  for index = 1, #value do
    local character = value:sub(index, index)

    if character == "=" then
      -- Padding is how a payload says it is not a whole number of groups: one
      -- `=` for a group of three, two for a group of two. Anything after it is
      -- not part of the data.
      padding = value:sub(index + 1, index + 1) == "=" and 2 or 1
      break
    elseif character == "\n" or character == "\r" or character == " " or character == "\t" then
      -- Not an error: some encoders wrap at 76 columns.
    else
      local digit = VALUES[character]
      if not digit then
        return nil, "not base64: " .. character
      end

      count = count + 1
      if count == 1 then
        first = digit * 4
      elseif count == 2 then
        first = first + math.floor(digit / 16)
        second = (digit % 16) * 16
      elseif count == 3 then
        second = second + math.floor(digit / 4)
        third = (digit % 4) * 64
      else
        third = third + digit
        out[#out + 1] = string.char(first % 256, second % 256, third % 256)
        first, second, third, count = 0, 0, 0, 0
      end
    end
  end

  -- The last group says how many bytes it stands for, and disagreeing with the
  -- padding is how a truncated payload announces itself. Emitting them anyway
  -- would produce a PNG one byte short of valid, which Steam would draw as a
  -- broken image rather than as the error it is.
  if padding == 0 then
    if count ~= 0 then
      return nil, "base64 payload is not a whole number of bytes"
    end
  elseif padding == 1 and count == 3 then
    out[#out + 1] = string.char(first % 256, second % 256)
  elseif padding == 2 and count == 2 then
    out[#out + 1] = string.char(first % 256)
  else
    return nil, "base64 payload does not match its padding"
  end

  return table.concat(out)
end

-- PNG ------------------------------------------------------------------------

---The size a PNG's header says it is, or nil if these aren't PNG bytes.
---
---Eight bytes of signature, the length of the first chunk, the name `IHDR`, and
---then the width and height as two big-endian 32-bit numbers - all of it inside
---the first 24 bytes, so this reads a header rather than an image.
---@param bytes string
---@return integer|nil width
---@return integer|nil height
local function png_dimensions(bytes)
  if #bytes < 24 or bytes:sub(1, 8) ~= "\137PNG\13\10\26\10" then
    return nil
  end
  if bytes:sub(13, 16) ~= "IHDR" then
    return nil
  end

  local byte = string.byte
  local width = byte(bytes, 17) * 16777216
    + byte(bytes, 18) * 65536
    + byte(bytes, 19) * 256
    + byte(bytes, 20)
  local height = byte(bytes, 21) * 16777216
    + byte(bytes, 22) * 65536
    + byte(bytes, 23) * 256
    + byte(bytes, 24)

  return width, height
end

-- Icons ----------------------------------------------------------------------

---Remove every file Steam would read this app's icon back from.
---
---All the extensions, not just the one about to be written: an icon left from
---another source is what Steam would go on reading otherwise, and a rename will
---not replace an existing file on Windows.
---@param path string
---@param id string
local function clear_icons(path, id)
  for _, candidate in ipairs(ICON_EXTENSIONS) do
    local existing = path .. "/" .. id .. "_icon." .. candidate
    if fs.is_file(existing) then
      fs.remove(existing)
    end
  end
end

---Where this app's icon already is, if it is anywhere.
---@param app_id integer|string
---@param account_id integer|string|nil
---@return string|nil path
---@return string? error
function grid.icon_path(app_id, account_id)
  local path, err = grid.path(account_id)
  if not path then
    return nil, err
  end

  local id = tostring(unsigned(app_id))
  for _, candidate in ipairs(ICON_EXTENSIONS) do
    local file = path .. "/" .. id .. "_icon." .. candidate
    if fs.is_file(file) then
      return file
    end
  end

  return nil
end

---Adopt the icon Steam already wrote, rather than downloading it again.
---
---An earlier version of this plugin asked Steam to write the icon artwork and
---then renamed what it found; hundreds of those files are still sitting in the
---grid folder under the wrong name, and re-downloading every game to replace
---them would cost more than the whole library.
---
---The size is what tells them apart. Icon artwork is the one thing in that
---folder written at {@link ICON_SIZE}, and a box art, a hero image or a header
---is not - the last two share the very filename, which is why a rename cannot be
---done on faith.
---@param app_id integer|string
---@param account_id integer|string|nil
---@return string|nil path Where the icon ended up
---@return string? error
function grid.adopt(app_id, account_id)
  local path, err = grid.path(account_id)
  if not path then
    return nil, err
  end

  local id = tostring(unsigned(app_id))
  local source = path .. "/" .. id .. ".png"

  if not fs.is_file(source) then
    return nil, "nothing to adopt for " .. id .. " in " .. path
  end

  -- Read only a file that could plausibly be an icon: this reads the whole
  -- thing, and the header art next to it is megabytes of someone else's
  -- bandwidth spent to look at 24 bytes of it.
  local size = fs.file_size(source) or 0
  if size > 1024 * 1024 then
    return nil, "the file at " .. source .. " is not icon sized"
  end

  local width, height = png_dimensions(utils.read_file(source) or "")
  if width ~= ICON_SIZE or height ~= ICON_SIZE then
    return nil,
      "the file at " .. source .. " is " .. tostring(width) .. "x" .. tostring(height)
        .. ", not a " .. ICON_SIZE .. "x" .. ICON_SIZE .. " icon"
  end

  clear_icons(path, id)
  local target = path .. "/" .. id .. "_icon.png"
  if not fs.rename(source, target) then
    return nil, "could not rename " .. source
  end

  return target
end

---Write an icon from the bytes the frontend drew.
---
---Written whole and in one go rather than appended to, because a half-written
---icon is one Steam will try to draw and fail on, and the next sync would see
---the file there and leave it alone.
---@param app_id integer|string
---@param account_id integer|string|nil
---@param base64 string
---@return string|nil path
---@return string? error
function grid.write(app_id, account_id, base64)
  local path, err = grid.path(account_id)
  if not path then
    return nil, err
  end

  local bytes, decode_error = grid.decode_base64(base64)
  if not bytes then
    return nil, decode_error
  end

  local id = tostring(unsigned(app_id))
  local target = path .. "/" .. id .. "_icon.png"

  if not utils.write_file(target, bytes) then
    return nil, "could not write " .. target
  end

  return target
end

---The icon Steam should read for each of these apps: the one already there, or
---the one Steam can be asked to hand over.
---
---Answers for the whole library at once because that is how it is asked. One
---call per game looked cheap and was not: each is a round trip across the
---process boundary, and each one also wrote three lines to the trace file, so a
---sync of 551 games spent 1 653 lines of it on the answer to a question with one
---answer for all of them.
---
---And inside the call, one listing rather than a `stat` per candidate. The
---folder being asked about is the one holding every game on the account, which
---is 9 000 files and climbing, so 551 apps was 1 102 path lookups against it.
---Listing it once and answering from that is less than half the work, measured
---on a real library: 4.5 ms down to 2.4 ms.
---
---Answered index for index rather than as a map keyed by appid, because an appid
---past 2^31 arrives signed from the client and is spelled unsigned on disk. Two
---spellings of one key is a trap this has no need to walk into.
---@param app_ids (integer|string)[]
---@param account_id integer|string|nil
---@return string[]|nil paths One per app id, "" where there is nothing to hand over
---@return string? error Only ever about the call as a whole
function grid.place_icons(app_ids, account_id)
  local path, err = grid.path(account_id)
  if not path then
    return nil, err
  end

  -- One listing, and only the files in it: `grid.icon_path` answered for files
  -- and nothing else, and a directory wearing an icon's name is not an icon.
  local present = {}
  for _, entry in ipairs(fs.list(path) or {}) do
    if not entry.is_directory then
      present[entry.name] = true
    end
  end

  local out, empty, adopted = {}, 0, 0

  for _, app_id in ipairs(app_ids) do
    local id = tostring(unsigned(app_id))
    local found

    for _, extension in ipairs(ICON_EXTENSIONS) do
      local name = id .. "_icon." .. extension
      if present[name] then
        found = path .. "/" .. name
        break
      end
    end

    if not found then
      -- Only the apps with nothing are asked the second question, and it is the
      -- one that reads a file and renames it. Having nothing to adopt is the
      -- ordinary answer for a game whose artwork has never been set, so it is
      -- counted rather than said anything about, one line for the whole call
      -- instead of one for every game.
      local taken = grid.adopt(app_id, account_id)
      if taken then
        found = taken
        adopted = adopted + 1
      end
    end

    if found then
      out[#out + 1] = found
    else
      out[#out + 1] = ""
      empty = empty + 1
    end
  end

  if adopted > 0 then
    logger:info("Adopted " .. adopted .. " icon(s) Steam had already written")
  end
  if empty > 0 then
    logger:info(empty .. " of " .. #app_ids .. " app(s) have no icon yet, and will have one drawn")
  end

  return out
end

---Take away the icons written for a set of apps.
---
---Only `<appid>_icon.<ext>`, the name this plugin writes under, and only for the
---appids it is given: the same folder holds box art and headers for every real
---Steam game, and a folder-wide sweep would take those with it.
---@param app_ids (integer|string)[]|nil
---@param account_id integer|string|nil
---@return integer removed
---@return string? error
function grid.forget(app_ids, account_id)
  local path, err = grid.path(account_id)
  if not path then
    return 0, err
  end

  local removed = 0
  for _, app_id in ipairs(app_ids or {}) do
    local icon = grid.icon_path(app_id, account_id)
    if icon and fs.remove(icon) then
      removed = removed + 1
    end
  end

  logger:info("Removed " .. removed .. " icon(s)")

  return removed
end

---Every account on this machine.
---
---The 32-bit ids, which is what `userdata` folders are named after. "0" is
---Steam's placeholder for "no account", and it has no artwork of its own.
---@return string[] accounts
function grid.accounts()
  local userdata = millennium.steam_path() .. "/userdata"
  local out = {}

  for _, entry in ipairs(fs.list(userdata) or {}) do
    if entry.is_directory and entry.name ~= "0" then
      out[#out + 1] = entry.name
    end
  end

  return out
end

---Put every icon back where Steam's own shortcut entry says it is.
---
---A shortcut does not look for its icon by name: its entry records the **path**
---it reads, and that path is what Steam draws from after a restart. The name in
---it is a convention - this plugin's unsigned one, handed over through
---`SetShortcutIcon` - and a convention is not a reference. So any pass that moves
---icons around on disk leaves every shortcut pointing at a file that is not
---there: a library of several hundred games reads as grey boxes after the next
---restart, with nothing in any log to say why, because Steam found nothing at
---the path it had been given.
---
---That is what renaming them did, and it is what this undoes. Read the shortcuts
---Steam itself lists, and for an entry whose icon path is not a file, give it
---back the icon written for that appid under the name this plugin uses.
---
---Copied, not moved: `grid.icon_path` reads the unsigned name to decide an icon
---is already there, so moving it away would make every pass after this one
---conclude it has to draw a fresh one - fetch the artwork again, cut an icon out
---of it, write it - for every game at once, on every launch. Leaving both means
---the repair runs once and the icon it left under this plugin's own name is what
---`SetShortcutIcon` is handed from then on, which is a path Steam reads too.
---
---Every account, and not only the signed-in one: the files are this plugin's own
---and which account wrote them is not something the machine still says. Two
---accounts here is what made the first attempt at a folder-wide sweep do nothing.
---
---Nothing is downloaded and Steam is told nothing: it is handed back the file at
---the path it has been reading all along.
---@param account_id integer|string|nil With none, every account is swept
---@return integer repaired
---@return string? error
function grid.repair_recorded_icons(account_id)
  local accounts = account_id and { tostring(account_id) } or grid.accounts()
  local repaired = 0

  for _, account in ipairs(accounts) do
    local path = grid.path(account)
    local shortcuts = path and vdf.read_shortcuts(account) or nil

    for _, entry in pairs(shortcuts or {}) do
      local recorded = type(entry) == "table" and entry.icon or nil
      if
        type(recorded) == "string"
        and recorded ~= ""
        and type(entry.appid) == "number"
        and not fs.is_file(recorded)
      then
        local id = tostring(unsigned(entry.appid))

        for _, extension in ipairs(ICON_EXTENSIONS) do
          local source = path .. "/" .. id .. "_icon." .. extension
          if fs.is_file(source) then
            local copied = fs.copy(source, recorded)
            if copied then
              repaired = repaired + 1
            else
              logger:warn("Could not put the icon for " .. id .. " back at " .. recorded)
            end
            break
          end
        end
      end
    end
  end

  if repaired > 0 then
    logger:info("Put " .. repaired .. " icon(s) back at the path Steam reads")
  end

  return repaired
end

return grid
