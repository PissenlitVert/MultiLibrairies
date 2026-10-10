local cache = require("cache")
local fs = require("fs")
local library_folders = require("library_folders")
local logger = require("logger")
local usage = require("usage")
local utils = require("utils")

-- An install manifest for a game Epic installed, so that Steam's own storage
-- page counts it.
--
-- Settings > Storage is built out of these files: one row per
-- `steamapps/appmanifest_<appid>.acf`, and the count in the page's own header is
-- the number of them. A non-Steam shortcut has none, and there is no API for
-- making one - Valve never intended one to be needed - so a game that is on disk
-- under `steamapps/common` and installed by the plugin instead of by Steam is
-- simply not in that page's world. Writing the file is the only way in, and it
-- is what this module is for.
--
-- What goes in it is deliberately the smallest thing that reads back as an
-- installed game: a name, the directory under `steamapps/common/`, and that
-- directory's measured size. No depot ids, because there are none - the content
-- came from Epic and is not in Steam's content system - and no build id, for
-- the same reason. Steam cannot verify, update or download anything for it, and
-- a shortcut needs none of that; what it does need is a row on a page that adds
-- the folder's size up.
--
-- `SizeOnDisk` is measured rather than Epic's figure, for the reason `usage.lua`
-- measures at all: the folder holds the patches, the shader caches and whatever
-- a mod manager added, and the question this page is opened to answer is where
-- the disk went.
--
-- `LastPlayed` is left out on purpose. Steam writes it into a real game's
-- manifest, and it would then believe it: the storage page shows "last played"
-- from that field, and a non-Steam shortcut's play time lives in `localconfig`
-- under `Playtime` instead. Omitting the key says nothing, where a 0 says
-- "never played" and would be believed.
--
-- Written whole, and only when it differs from what is on disk, so a Steam
-- watching `steamapps` sees no churn on a pass that changed nothing and a
-- half-written file - one Steam would try to read and fail on - never exists.

local manifest = {}

---Where the answers are kept: which app id was written where, and for which
---folder, so that a file which has stopped being ours is never deleted.
local CACHE_PATH = utils.get_backend_path() .. "/data/cache/manifests.json"

---@type table<string, {path: string, folder: string}>|nil App id -> what was written for it
local known = nil--- Steam's flag for an app that is installed and not downloading.
local STATE_INSTALLED = 4

---The appid as Steam writes it down: unsigned.
---
---Steam hands out appids above 2^31 for non-Steam shortcuts, and its API - and
---`shortcuts.vdf` - carry them as a *signed* 32-bit integer: Shogun Showdown's
---2 435 244 972 arrives as -1 859 722 324, and every Epic game on this machine
---is negative that way. The signed form is right for every `SteamClient` call,
---which is why it is not changed where it is read; it is wrong for a file name
---and for a number written into a text file, because
---`appmanifest_-1859722324.acf` is a file Steam never opens.
---@param app_id integer|string
---@return integer|string
function manifest.unsigned(app_id)
  local id = tonumber(app_id)
  if not id or id >= 0 then return app_id end

  return id + 4294967296
end

---Where the game has to be for a manifest to mean anything.
---
---`steamapps/common/<folder>` is the only place Steam looks for an installed
---game's files, and the manifest has to sit in `steamapps` beside `common` - a
---manifest anywhere else describes a folder Steam never scans, and is ignored. A
---game installed anywhere else gets no manifest rather than one that does
---nothing.
---@param install_path string|nil
---@return string|nil steamapps
---@return string|nil folder The directory's own name under `common/`
function manifest.steamapps(install_path)
  if type(install_path) ~= "string" then return nil end

  local marker = "steamapps/common/"
  local at = install_path:lower():find(marker, 1, true)
  if not at then return nil end

  local folder = install_path:sub(at + #marker):match("^([^/]+)/*$")
  if not folder then
    -- One level deeper than a game: Epic reports the executable's own folder,
    -- and a manifest naming it would measure the launcher's files rather than
    -- the game's.
    return nil
  end

  -- `steamapps` itself, and not the directory containing it: the file belongs
  -- beside `common`, which is what Steam looks in.
  return install_path:sub(1, at - 1) .. "steamapps", folder
end

---The manifest file for one app.
---@param app_id integer|string
---@param install_path string|nil
---@return string|nil path
---@return string|nil folder
function manifest.path(app_id, install_path)
  local steamapps, folder = manifest.steamapps(install_path)
  if not steamapps then return nil end

  return steamapps .. "/appmanifest_" .. tostring(manifest.unsigned(app_id)) .. ".acf", folder
end

---A value as text.
---
---Not `tostring`: every non-Steam appid is above 2^31 and every game over two
---gigabytes, and `tostring` on those numbers gives `3.0194e+09` - which Steam
---would read as an appid that does not exist, for a file whose only purpose is
---to name one correctly.
---@param value string|number
---@return string
local function as_text(value)
  if type(value) == "number" then
    return string.format("%d", value)
  end
  return tostring(value)
end

---A quoted VDF value, with what a game name can contain escaped.
---@param value string|integer
---@return string
local function quoted(value)
  local escaped = as_text(value):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
  return '"' .. escaped .. '"'
end

---A VDF pair, in the spacing Steam's own writer uses: the key, two tabs, the
---value.
---@param key string
---@param value string|integer
---@return string
local function pair(key, value)
  return string.format("\t%s\t\t%s\n", quoted(key), quoted(value))
end

---The manifest's own text.
---
---Public so the shape can be checked without a filesystem, which is where the
---mistake worth catching is: a key Steam does not know is ignored, and one that
---says something other than what it means is believed. The key names, their
---order and their spelling are Valve's, copied from the manifests Steam writes
---for its own games - `lastupdated` is lower case in Steam's file and upper case
---in its documentation, and only the file is read.
---@param app_id integer|string
---@param name string
---@param folder string
---@param size_bytes integer
---@param updated integer Unix seconds
---@return string
function manifest.content(app_id, name, folder, size_bytes, updated)
  local out = '"AppState"\n{\n'
  out = out .. pair("appid", manifest.unsigned(app_id))
  out = out .. pair("Universe", 1)
  out = out .. pair("name", name)
  out = out .. pair("StateFlags", STATE_INSTALLED)
  out = out .. pair("installdir", folder)
  out = out .. pair("lastupdated", updated)
  out = out .. pair("SizeOnDisk", size_bytes)
  out = out .. pair("StagingSize", 0)
  out = out .. pair("buildid", 0)
  out = out .. pair("DownloadType", 1)
  out = out .. pair("UpdateResult", 0)
  out = out .. pair("BytesToDownload", 0)
  out = out .. pair("BytesDownloaded", 0)
  out = out .. pair("BytesToStage", 0)
  out = out .. pair("BytesStaged", 0)
  out = out .. pair("TargetBuildID", 0)
  out = out .. pair("AutoUpdateBehavior", 0)
  out = out .. pair("AllowOtherDownloadsWhileRunning", 0)
  out = out .. pair("ScheduledAutoUpdate", 0)
  out = out .. '\t"InstalledDepots"\n\t{\n\t}\n'
  out = out .. '\t"UserConfig"\n\t{\n\t}\n'
  out = out .. '\t"MountedConfig"\n\t{\n\t}\n'
  out = out .. "}\n"

  return out
end

---Read what this plugin has written before, or nothing on the first run.
---@return table<string, {path: string, folder: string}>
local function remembered()
  if not known then
    known = cache.read(CACHE_PATH, "manifests") or {}
  end
  return known
end

---Record one manifest as ours, writing the cache only when that is new.
---@param app_id integer|string
---@param path string
---@param folder string
---@return boolean changed
local function remember(app_id, path, folder)
  local remembered_paths = remembered()
  app_id = manifest.unsigned(app_id)
  local previous = remembered_paths[tostring(app_id)]
  if previous and previous.path == path and previous.folder == folder then return false end

  remembered_paths[tostring(app_id)] = { path = path, folder = folder }
  cache.write(CACHE_PATH, remembered_paths, "manifests")
  return true
end

---Take one game's manifest away again.
---
---Only a file this plugin wrote, and only while it still names the folder it was
---written for: a shortcut whose app id was later given to a Steam game, and that
---game's own manifest, are not ours to delete.
---@param app_id integer|string
---@return boolean removed
---The library folder a game's `steamapps` sits in, which is what Steam's own
---per-folder app list is keyed on: `…/SteamLibrary/steamapps` -> `…/SteamLibrary`.
---@param steamapps string
---@return string
local function library_of(steamapps)
  return steamapps:match("^(.*)/steamapps/?$") or steamapps
end

---Tell Steam's own folder list about this game, or stop telling it.
---
---The second half of what puts a game on Settings > Storage, and the half a
---manifest alone does not do: the page counts each folder's `vecApps`, which is
---the `apps` list in `libraryfolders.vdf`. Written together with the manifest,
---because one without the other is a game Steam can read about and will not show.
---@param steamapps string
---@param app_id integer|string
---@param bytes integer|nil nil takes the app back out of the list
---@return boolean changed Whether the list itself moved, in any of its copies
local function folder_entry(steamapps, app_id, bytes)
  local changed, err = library_folders.set(library_of(steamapps), app_id, bytes)
  if err then
    logger:warn("Could not update Steam's library list: " .. tostring(err))
  end
  return changed
end

function manifest.remove(app_id)
  local remembered_paths = remembered()
  app_id = manifest.unsigned(app_id)
  local entry = remembered_paths[tostring(app_id)]
  if not entry then return false end

  if fs.is_file(entry.path) then
    local existing = utils.read_file(entry.path) or ""
    if not existing:find('"installdir"\t\t"' .. entry.folder .. '"', 1, true) then
      logger:warn("Leaving " .. entry.path .. " alone - it is not the one we wrote")
      remembered_paths[tostring(app_id)] = nil
      cache.write(CACHE_PATH, remembered_paths, "manifests")
      return false
    end

    fs.remove(entry.path)
    logger:info("Removed the manifest for " .. tostring(app_id))
  end

  local steamapps = entry.path:match("^(.*)/steamapps/")
  if steamapps then
    folder_entry(steamapps, app_id, nil)
  end

  remembered_paths[tostring(app_id)] = nil
  cache.write(CACHE_PATH, remembered_paths, "manifests")

  return true
end

---Take back every manifest this plugin has written.
---
---For "remove everything". A game that is still installed must stop being counted
---by Steam's storage page, and the only way out of that is to take the file away
---again - which is the plugin's own bookkeeping. The game's files are left where
---they are: they are the user's, and nothing here was asked to delete them.
---@return integer removed
function manifest.remove_all()
  local removed = 0
  for entry in pairs(remembered()) do
    if manifest.remove(entry) then
      removed = removed + 1
    end
  end

  logger:info("Took back " .. removed .. " install manifest(s)")

  return removed
end

---The date a manifest already carries, so an unchanged game keeps it.
---
---`lastupdated` means "when this app last changed", and a pass that found nothing
---changed must not write one that says it changed now: the file would then differ
---on every launch, and Steam would be told to rescan the folder every launch for
---nothing.
---@param content string|nil
---@return integer
local function stamp_of(content)
  return tonumber(content and content:match('"lastupdated"%s+"(%d+)"') or "") or 0
end

---Write one game's manifest, if it is installed somewhere Steam will find it.
---
---Measured through `usage`, so the figure is the folder's real size and the walk
---is the one every other caller shares.
---@param app_id integer|string
---@param app_name string Epic's own id, which is what usage is keyed on
---@param name string The game's title
---@param install_path string
---@return boolean written The file on disk is now ours
---@return string? reason Why not, when it wasn't
---@return boolean? changed Whether it was rewritten, rather than already correct
---@return integer? bytes The size written, which is the number the storage page shows
function manifest.write(app_id, app_name, name, install_path)
  local path, folder = manifest.path(app_id, install_path)
  if not path or not folder then
    return false, "not under steamapps/common"
  end

  local steamapps = manifest.steamapps(install_path)
  -- One variable for a two-value function takes the first, which is the
  -- `steamapps` directory itself.
  steamapps = select(1, steamapps)

  local bytes = usage.for_game(app_name, install_path)
  if not bytes or bytes <= 0 then
    -- The walk is running, or the folder is empty. A manifest claiming no size
    -- would be believed by Steam and counted as nothing, which is worse than no
    -- row at all; the next pass writes it.
    return false, "not measured yet"
  end

  -- Compared against the file as it stands, with its own date, before anything
  -- is written: a game whose size and name have not moved is not rewritten.
  local existing = utils.read_file(path)
  if existing and existing == manifest.content(app_id, name, folder, bytes, stamp_of(existing)) then
    remember(app_id, path, folder)

    -- The folder list is reconciled anyway, and saying whether it moved is the
    -- point: Steam rewrites that file in its own time, and copies one of its
    -- two copies over the other, so the list can lose a line while the manifest
    -- beside the game stays exactly as it was. A pass that returned here without
    -- looking left the page drawing a row nothing had put there, with no change
    -- reported and so no re-read asked for.
    return true, nil, folder_entry(steamapps, app_id, bytes), bytes
  end

  local content = manifest.content(app_id, name, folder, bytes, math.floor(utils.time()))
  local ok, err = utils.write_file(path, content)
  if not ok then
    logger:warn("Could not write " .. path .. ": " .. tostring(err))
    return false, "could not write " .. path
  end

  remember(app_id, path, folder)
  folder_entry(steamapps, app_id, bytes)
  logger:info("Wrote a manifest for " .. tostring(app_id) .. " (" .. folder .. ", " .. bytes .. " bytes)")

  return true, nil, true, bytes
end

---One installed game, as the caller knows it.
---@class ManifestGame
---@field app_id integer The Steam appid the shortcut was given
---@field app_name string Epic's own id
---@field title string
---@field install_path string

---Give Steam a manifest for every installed game, and take back the ones whose
---game is gone.
---
---Both halves in one pass, because the list the caller has is the truth: a game
---that was uninstalled must stop being counted, and it is the same walk over the
---same list that decides that.
---
---`changed` is whether any file on disk moved. Only then is there a reason to
---ask Steam to look at the folder again - it does that by rescanning it, which
---is not free.
---@param games ManifestGame[]
---@return {written: {app_id: integer, path: string, bytes: integer}[], removed: integer[], skipped: {app_id: integer, reason: string}[], changed: boolean, awaiting: boolean, measuring: boolean}
function manifest.sync(games)
  local written, removed, skipped = {}, {}, {}
  local awaiting, changed = false, false
  -- Whether any of the skips is a walk still going, rather than a folder with
  -- nothing in it. The caller waits far longer for the first than the second,
  -- and that difference is the whole of it: a `du` that takes a minute is normal
  -- and must not be given up on, while a second `du` of the same empty folder
  -- answers the same way and only costs time.
  local measuring = false
  local wanted = {}

  for _, game in ipairs(games or {}) do
    local app_id = tonumber(game.app_id)
    local app_name = game.app_name
    if app_id then app_id = manifest.unsigned(app_id) end
    if not app_id or not app_name then
      skipped[#skipped + 1] = { app_id = tonumber(game.app_id) or 0, reason = "no app id" }
    else
      wanted[tostring(app_id)] = true

      local ok, reason, rewrote, bytes = manifest.write(
        app_id,
        app_name,
        game.title or app_name,
        game.install_path
      )
      if ok then
        local path = remembered()[tostring(app_id)].path
        -- `bytes` travels with it because this is the one figure the storage
        -- page shows for the row, and it is measured here: the frontend that
        -- draws a row of its own has no other way to know it.
        written[#written + 1] = { app_id = app_id, path = path, bytes = bytes or 0 }
        if rewrote then changed = true end
      else
        skipped[#skipped + 1] = { app_id = app_id, reason = reason or "unknown" }
        if reason == "not measured yet" then
          awaiting = true
          if usage.is_measuring(app_name) then measuring = true end
        end
      end
    end
  end

  -- A game that is no longer installed has no row to keep. Its manifest would
  -- otherwise leave a game listed at the size it used to be, which is exactly
  -- what makes an uninstall look like it failed.
  for entry in pairs(remembered()) do
    if not wanted[entry] then
      if manifest.remove(entry) then
        removed[#removed + 1] = tonumber(entry) or 0
        changed = true
      end
    end
  end

  table.sort(written, function(one, another) return one.app_id < another.app_id end)
  table.sort(removed)

  -- Said only when there is something to say. This runs on every launch, and a
  -- line per launch saying nothing happened is how a log stops being read.
  --
  -- `info` rather than anything quieter, and that is not a preference: Millennium's
  -- backend logger has `info`, `warn` and `error` and nothing else, so a
  -- `logger:debug` here would not be quiet - it would throw, and take the whole
  -- pass with it. The test stub carried one, which is how that got as far as
  -- the client; it no longer does.
  if changed or #skipped > 0 then
    logger:info(
      "Manifests synced: "
        .. #written
        .. " written, "
        .. #removed
        .. " removed, "
        .. #skipped
        .. " skipped"
    )
  end

  return {
    written = written,
    removed = removed,
    skipped = skipped,
    changed = changed,
    awaiting = awaiting,
    measuring = measuring,
  }
end

return manifest
