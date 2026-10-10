local fs = require("fs")
local millennium = require("millennium")
local utils = require("utils")

-- The per-folder app list inside Steam's own `libraryfolders.vdf` - which it keeps
-- in two files, and reads the one this used to leave alone. See `paths()`.
--
-- Settings > Storage is drawn from `SteamClient.InstallFolder.GetInstallFolders()`,
-- and each folder's `vecApps` is that list - which is what the page's own header
-- counts: it said 56 while `ls steamapps/appmanifest_*.acf` said 56, and Steam
-- writes one line per app it accepted, with the app's size as the value.
--
-- So a manifest beside the game's files is not the whole of what puts a row on
-- that page. A manifest written here, with the right appid in it, was on disk and
-- Steam restarted, and the count stayed at 56: the folder had never been told
-- about the app. Both are written, together, because one without the other is
-- what the page was showing.
--
-- Written the way Steam writes it - `"<appid>"` two tabs `"<bytes>"`, one line,
-- inside that folder's `apps` block - and whole, through a temp file, because a
-- half-written `libraryfolders.vdf` is a Steam that starts with no libraries at
-- all. Steam rewrites the file itself whenever its libraries change, so this is
-- an entry to keep rather than a file to own.

local library_folders = {}

---Every file Steam keeps this list in, in the order to write them.
--
-- Steam has two of them, and it reads the one this was not writing. `content_log.txt`
-- records `Loaded Steam library folders configuration: ~/.local/share/Steam/steamapps/libraryfolders.vdf`,
-- and the storage page's rows follow that copy. `config/libraryfolders.vdf` is the
-- one Steam copies *from*, when it reloads the configuration - not before - and
-- that is every symptom this had. A game never appeared on the page until Steam
-- had been restarted, because Steam had not reloaded its configuration since the
-- line was written. A game that was uninstalled kept its row indefinitely,
-- because the copy the page reads still had the line in it.
---@return string[]
function library_folders.paths()
  local steam = millennium.steam_path()
  return { steam .. "/config/libraryfolders.vdf", steam .. "/steamapps/libraryfolders.vdf" }
end

---An appid as Steam writes it down: unsigned.
---
---Steam carries a non-Steam appid as a signed 32-bit integer and spells it
---unsigned in every file it writes: 2 435 244 972 in `shortcuts.vdf`,
----1 859 722 324 over the wire.
---@param app_id integer
---@return integer
local function unsigned(app_id)
  if app_id < 0 then return app_id + 4294967296 end
  return app_id
end

---Where a folder's `apps` block is inside the file, and where its last entry ends.
---
---By indentation rather than by counting braces: the blocks nest, but there is
---exactly one `apps` block per folder and its entries are all at three tabs, so
---the `\t\t}` that closes it is the end of the list whatever is inside it.
---@param content string
---@param folder string The library folder, e.g. `/var/mnt/Jeux/SteamLibrary`
---@return number|nil first Just after the `apps` block's opening brace
---@return number|nil last The `\n` that ends its last entry
local function apps_block(content, folder)
  local path = content:find('"path"\t\t"' .. folder .. '"', 1, true)
  if not path then return nil end

  local apps = content:find('"apps"', path, true)
  if not apps then return nil end

  local opened = content:find("{\n", apps, true)
  if not opened then return nil end

  local closed = content:find("\n\t\t}\n", opened, true)
  if not closed then return nil end

  return opened + 2, closed
end

---One game's line, exactly as Steam spells it.
---@param app_id integer
---@param bytes integer
---@return string
local function entry(app_id, bytes)
  return string.format('\t\t\t"%d"\t\t"%d"\n', unsigned(app_id), bytes)
end

---Put the file back, whole, through a temp file.
---
---`rename()` will not replace an existing file on Windows, and this file is
---Steam's own, so the copy is what puts it back and the temp is what makes the
---replace never a short read. Steam still rewrites the file at its next library
---change, which is its right and not a loss: the manifest beside the game is what
---lets it put the line back.
---@param path string
---@param content string
---@return boolean changed
---@return string? error
local function save(path, content)
  local temp = path .. ".epic.tmp"
  local ok, err = utils.write_file(temp, content)
  if not ok then
    return false, "could not write " .. temp .. ": " .. tostring(err)
  end

  if not fs.copy(temp, path) then
    fs.remove(temp)
    return false, "could not replace " .. path
  end

  fs.remove(temp)
  return true
end

---Put one app in a folder's list, or take it out again, in one of the files.
---@param path string
---@param folder string The library folder, e.g. `/var/mnt/Jeux/SteamLibrary`
---@param app_id integer Signed or unsigned; both spell the same app
---@param bytes integer|nil
---@return boolean changed
---@return string? error
local function set_in(path, folder, app_id, bytes)
  local content = utils.read_file(path)
  if not content then
    return false, "could not read " .. path
  end

  local first, last = apps_block(content, folder)
  if not first then
    return false, "no apps list for " .. folder
  end

  local id = tostring(unsigned(tonumber(app_id) or app_id))
  -- The whole line, newline included: compared against the line this would write
  -- instead, so "nothing changed" is a real answer and a pass that rewrites
  -- Steam's own configuration on every launch cannot happen.
  local existing = content:sub(first, last):match('\t\t\t"' .. id .. '"\t\t"%d+"\n')

  if not existing then
    if not bytes then return false end

    -- Appended after the last entry rather than sorted in: Steam appends too,
    -- and re-sorting a five-hundred-game file on every launch is churn nobody
    -- asked for.
    return save(path, content:sub(1, last) .. entry(app_id, bytes) .. content:sub(last + 1))
  end

  local line = bytes and entry(app_id, bytes) or ""
  if existing == line then
    return false
  end

  local at = content:find(existing, first, true)
  return save(path, content:sub(1, at - 1) .. line .. content:sub(at + #existing))
end

---Put one app in a folder's list, or take it out again - in every copy Steam has.
---
---`bytes` of nil removes the app, which is the uninstall half: the game has to
---stop being counted rather than being counted at the size it used to be.
---
---Every file is written even when one of them fails, because writing only half of
---it is worse than an error: Steam copies `config/` over `steamapps/` at its next
---reload, so a change to only the copy the page reads is one reload from being
---undone, and a change to only the copy it copies from is one reload from being
---applied. The first failure is the one reported, and the first file that moved
---is what `changed` answers.
---@param folder string The library folder, e.g. `/var/mnt/Jeux/SteamLibrary`
---@param app_id integer Signed or unsigned; both spell the same app
---@param bytes integer|nil
---@return boolean changed
---@return string? error
function library_folders.set(folder, app_id, bytes)
  local changed, err = false, nil

  for _, path in ipairs(library_folders.paths()) do
    local moved, problem = set_in(path, folder, app_id, bytes)
    if moved then changed = true end
    if problem and not err then err = problem end
  end

  return changed, err
end

return library_folders
