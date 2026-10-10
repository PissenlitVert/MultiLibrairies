local cache = require("cache")
local egl = require("egl")
local entitlements = require("entitlements")
local legendary = require("legendary")
local logger = require("logger")
local platform = require("platform")
local utils = require("utils")

-- The merge of two legendary commands: `list`, everything the account owns, and
-- `list-installed`, what is on disk. Neither alone is enough - showing games you
-- own but haven't installed is the point of the plugin.

local library = {}

--- Cached so a cold start can draw the library before it has spoken to Epic.
local CACHE_PATH = utils.get_backend_path() .. "/data/cache/library.json"

---@class EpicGame
---@field app_name string Epic's internal id, and our stable key for everything
---@field title string Display name
---@field installed boolean
---@field install_path string|nil
---@field install_size integer|nil Bytes on disk
---@field version string|nil Installed build version
---@field latest_version string|nil Build version the catalog is shipping
---@field folder_name string|nil Directory Epic expects the game to live in
---@field cloud_saves boolean Whether Epic keeps this game's saves in the cloud
---@field needs_update boolean
---@field art_portrait string|nil Tall box art URL
---@field art_hero string|nil Wide art URL
---@field purchased_at integer|nil Unix seconds the account was granted the game

---@type EpicGame[]
local games = {}

---Where each installed game is, keyed by the name the account knows it by.
---@type table<string, EpicGame>
local installed_by_name = {}

---Rebuild that index.
---
---It exists because `install_dir` is asked once per game, and a linear scan
---asked 551 times walks the library 551 times: 303 000 comparisons for a
---question with one answer per game. Measured on a library of this size, the
---index takes that pass from 0.22 ms to 0.03 ms, and the pass is asked for twice
---- once to build the commands, once to check them - so it is the difference
---between work that grows with the square of the account and work that grows
---with it.
---
---Called wherever `games` is replaced, which is the only way the library ever
---changes.
local function reindex_installed()
  installed_by_name = {}

  for _, game in ipairs(games) do
    if game.install_path then
      installed_by_name[game.app_name] = game
    end
  end
end

--- Unix seconds of the last successful refresh.
local refreshed_at = 0

-- Artwork ---------------------------------------------------------------------

--- Which image types a title has varies with how old its store page is, so the
--- first one present wins.
local ART_TYPES = {
  portrait = { "DieselGameBoxTall", "OfferImageTall", "Thumbnail" },
  hero = { "DieselGameBox", "OfferImageWide", "DieselGameBoxWide" },
}

---Pick the best available image URL of one kind out of Epic's metadata.
---@param key_images table[]|nil
---@param kind "portrait"|"hero"
---@return string|nil url
local function pick_art(key_images, kind)
  if type(key_images) ~= "table" then
    return nil
  end

  for _, wanted in ipairs(ART_TYPES[kind]) do
    for _, image in ipairs(key_images) do
      if image.type == wanted and type(image.url) == "string" then
        return image.url
      end
    end
  end

  return nil
end

-- Persistence -----------------------------------------------------------------

---Read the cached library from disk, if there is one.
function library.load()
  local decoded = cache.read(CACHE_PATH, "library")
  if not decoded then
    logger:info("No cached library yet")
    return
  end

  games = decoded.games or {}
  reindex_installed()
  refreshed_at = decoded.refreshed_at or 0
  logger:info("Loaded " .. #games .. " games from cache")
end

local function save()
  cache.write(CACHE_PATH, { games = games, refreshed_at = refreshed_at }, "library")
end

-- Refresh ---------------------------------------------------------------------

--- Reads what's on disk. Local, so no round trip to Epic.
---
--- Without `--check-updates`, which as of legendary 0.21 only prints "Update
--- available!" in its human-readable output and puts nothing in the JSON, while
--- costing a login and a round trip to Epic. The build version to compare
--- against is in the catalog we already fetch, so we do the comparison here.
local LIST_INSTALLED = { "list-installed", "--json" }

--- Per `legendary import`. One manifest refetch, not a download.
local IMPORT_TIMEOUT = 30000

---Index one `list-installed` output by app name, so merging stays linear rather
---than a nested scan over 300+ titles.
---@param output string
---@return table<string, table>|nil installed_by_name
local function index_installed(output)
  local installed = legendary.decode_json(output)
  if type(installed) ~= "table" then
    return nil
  end

  local by_name = {}
  for _, game in ipairs(installed) do
    by_name[game.app_name] = game
  end
  return by_name
end

---The directory a game of ours really occupies under `steamapps/common/`.
---
---Epic's own `InstallLocation`, which is what `list-installed` answers with, is
---the folder the *executable* is in - one level inside the game's own directory
---for every launcher build that keeps its binary in a subfolder. Shogun Showdown
---is one: `.../steamapps/common/ShogunShowdown611f6/ShogunShowdown611f6`.
---
---Steam matches a shortcut's working directory against the `steamapps/common/`
---children, then counts and offers to delete the one it matched, so a path one
---level too deep matches nothing. The game is real, playable and invisible on
---Settings -> Storage, and a size measured from there leaves out everything
---outside that subfolder.
---@param install_path string|nil
---@param folder_name string|nil The game's own directory name, when the catalog has it
---@return string|nil path
function library.app_dir(install_path, folder_name)
  if type(install_path) ~= "string" or install_path == "" then return nil end

  local separator = platform.separator()
  local not_separator = "[^" .. separator .. "]"

  -- Already the directory itself, which is what an install that puts the
  -- executable at its root answers with. Compared as a whole path component and
  -- not as a suffix, because the nested build this exists for ends in a segment
  -- spelled exactly like the folder it sits in -
  -- `.../common/ShogunShowdown611f6/ShogunShowdown611f6` - and a suffix test
  -- calls that one already-correct and leaves it one level too deep.
  if type(folder_name) == "string" and folder_name ~= "" then
    if install_path:match(not_separator .. "$") == folder_name then return install_path end
  end

  local common = "steamapps" .. separator .. "common" .. separator

  -- Matched on a lowered copy, because `SteamLibrary` and a Windows drive can
  -- both be spelled any way, and a path only half matched is a path only half
  -- corrected.
  local at = install_path:lower():find(common, 1, true)
  if not at then return install_path end

  local name = install_path:sub(at + #common):match("^(" .. not_separator .. "+)")
  if not name or name == "" then return install_path end

  return install_path:sub(1, at + #common - 1 + #name)
end

---Copy the installed half of a game across from `list-installed`.
---
---An update is the installed build version differing from the catalog's, which
---is the same comparison legendary's own `--check-updates` makes. `latest_version`
---is kept on the game so this can be redone after an install without the
---catalog in hand.
---@param game table An EpicGame missing its installed fields
---@param local_game table|nil
---@param latest_version string|nil The catalog's build version, `game.latest_version` if nil
---@return EpicGame game
local function apply_installed(game, local_game, latest_version)
  game.installed = local_game ~= nil
  game.install_path = local_game and library.app_dir(local_game.install_path, game.folder_name)
    or nil
  game.install_size = local_game and local_game.install_size or nil
  game.version = local_game and local_game.version or nil
  game.latest_version = latest_version or game.latest_version

  -- Only ever an update against a build we actually know the name of: a missing
  -- catalog version would otherwise read as "every installed game is stale".
  game.needs_update = game.installed
    and game.latest_version ~= nil
    and game.version ~= nil
    and game.version ~= game.latest_version

  return game
end

---Register any Epic Games Launcher install `egl-sync` skipped (see egl.lua) and
---return the installed-game index with those folded in. Usually a no-op.
---@param owned table[] Decoded `legendary list` output
---@param installed_by_name table<string, table> app_name -> installed game
---@return table<string, table> installed_by_name
local function import_leftover_egl_installs(owned, installed_by_name)
  -- A manifest for something this account doesn't own belongs to another
  -- account, and importing it just fails.
  local owned_names = {}
  for _, game in ipairs(owned) do
    owned_names[game.app_name] = true
  end

  local commands = {}
  local titles = {}
  for _, manifest in ipairs(egl.get_manifests()) do
    if owned_names[manifest.app_name] and not installed_by_name[manifest.app_name] then
      table.insert(commands, egl.import_args(manifest.app_name, manifest.install_path))
      table.insert(titles, manifest.title)
    end
  end

  if #commands == 0 then
    return installed_by_name
  end
  logger:info(
    "Importing Epic Games Launcher installs egl-sync skipped: " .. utils.join(titles, ", ")
  )

  for _, args in ipairs(commands) do
    -- These run one after another and each blocks the Lua state, so they get a
    -- short leash: a handful of manifests legendary can't resolve shouldn't add
    -- up to minutes of frozen plugin on a refresh.
    legendary.run(args, IMPORT_TIMEOUT)
  end

  -- Re-read: the list only picks the imports up once they have happened.
  return index_installed(legendary.run(LIST_INSTALLED)) or installed_by_name
end

---Is this catalog entry a game? The catalog is also full of engine components,
---plugins and asset packs, which nobody wants in their Steam library.
---@param entry table
---@return boolean
local function is_game(entry)
  if entry.is_dlc then
    return false
  end

  for _, category in ipairs((entry.metadata or {}).categories or {}) do
    if category.path == "games" then
      return true
    end
  end

  return false
end

---The build Epic is currently shipping for a title, which is what an installed
---game is stale against. Keyed by platform, and we only ever install Windows.
---@param entry table One element of `legendary list`
---@return string|nil version
local function latest_version(entry)
  local windows = (entry.asset_infos or {}).Windows
  if type(windows) ~= "table" or type(windows.build_version) ~= "string" then
    return nil
  end
  return windows.build_version
end

---The Epic namespace a catalog entry belongs to, which is what an entitlement is
---keyed by. On the entry itself for most titles, on the Windows asset for the
---rest.
---@param entry table One element of `legendary list`
---@return string|nil namespace
local function namespace(entry)
  local from_metadata = (entry.metadata or {}).namespace
  if type(from_metadata) == "string" then
    return from_metadata
  end

  local windows = (entry.asset_infos or {}).Windows
  return type(windows) == "table" and windows.namespace or nil
end

---Fold one catalog entry together with what's installed on disk for it, if
---anything is.
---@param entry table One element of `legendary list`
---@param local_game table|nil The matching element of `legendary list-installed`
---@param granted table<string, integer> Grant dates by namespace, per entitlements.lua
---@return EpicGame
local function merge_game(entry, local_game, granted)
  local metadata = entry.metadata or {}
  local attributes = metadata.customAttributes or {}

  local game = {
    app_name = entry.app_name,
    title = entry.app_title or metadata.title or entry.app_name,
    -- What legendary names the directory when given no --game-folder, so the
    -- install dialog can show the full path up front.
    folder_name = (attributes.FolderName or {}).value,
    -- Out of the same custom attributes, so it costs nothing: a game with a
    -- cloud save folder on Epic's side is one whose saves can be synced, and
    -- the panel says how many of the library those are.
    cloud_saves = attributes.CloudSaveFolder ~= nil,
    art_portrait = pick_art(metadata.keyImages, "portrait"),
    art_hero = pick_art(metadata.keyImages, "hero"),
    purchased_at = granted[namespace(entry) or ""],
  }

  return apply_installed(game, local_game, latest_version(entry))
end

---Ask legendary for the whole library and rebuild from it.
---@param force boolean|nil Bypass legendary's own catalog cache
---@return EpicGame[]|nil games
---@return string? error
function library.refresh(force)
  -- Without this a missing binary reads as an empty library.
  local binary, binary_error = legendary.get_binary()
  if not binary then
    return nil, binary_error
  end

  -- Signed out, `legendary list` exits 1 with "ValueError: No saved
  -- credentials" and a traceback under it. Asked anyway, that is two failed
  -- subprocesses and a page of Python handed back as an error on every refresh.
  local status = legendary.get_status()
  if not status.authenticated then
    return nil, "Not signed in to Epic."
  end

  local list_args = { "list", "--json" }
  if force then
    table.insert(list_args, "--force-refresh")
  end

  -- The EGL sync goes first: it's what makes launcher installs visible to the
  -- list-installed after it. Its failure is only logged, since not having EGL
  -- is normal.
  logger:info("Epic Games Launcher sync: " .. utils.trim(legendary.run(egl.sync_args())))

  local owned, err = legendary.decode_json(legendary.run(list_args))
  if type(owned) ~= "table" then
    return nil, err or "legendary returned no library"
  end

  local installed_by_name =
    import_leftover_egl_installs(owned, index_installed(legendary.run(LIST_INSTALLED)) or {})

  local granted = entitlements.get_granted()

  local merged = {}
  for _, entry in ipairs(owned) do
    if is_game(entry) then
      table.insert(merged, merge_game(entry, installed_by_name[entry.app_name], granted))
    end
  end

  table.sort(merged, function(a, b)
    return a.title < b.title
  end)

  games = merged
  reindex_installed()
  refreshed_at = math.floor(utils.time())
  save()

  logger:info("Refreshed library: " .. #games .. " games")
  return games
end

---Re-read only what's on disk, leaving the catalog alone. This is the
---after-an-install refresh: a game the catalog has never seen can't appear this
---way, which is what `library.refresh` is for.
---@return EpicGame[]|nil games
---@return string? error
function library.refresh_installed()
  local binary, binary_error = legendary.get_binary()
  if not binary then
    return nil, binary_error
  end

  local installed_by_name = index_installed(legendary.run(LIST_INSTALLED))
  if not installed_by_name then
    return nil, "legendary returned no installed games"
  end

  local count = 0
  for _, game in ipairs(games) do
    apply_installed(game, installed_by_name[game.app_name])
    if game.installed then
      count = count + 1
    end
  end

  -- refreshed_at means "when did we last ask Epic", which this didn't.
  save()

  logger:info("Refreshed installs: " .. count .. " on disk")
  return games
end

---The library as we last saw it, empty until something refreshes it. Never
---refreshes on its own: this answers the frontend's first call at startup, and
---a cold `legendary list` there would hold the plugin behind a round trip to
---Epic.
---@return EpicGame[] games
function library.get()
  return games
end

---When the library was last read from Epic, in Unix seconds. 0 if never.
---@return integer
function library.get_refreshed_at()
  return refreshed_at
end

---Where one game is installed, for the things that need the folder itself.
---
---Steam's own storage accounting attributes a game's size to a directory under
---`steamapps/common/`, matched against the shortcut's working directory - so
---telling Steam where a game really is takes the directory itself, not the folder
---inside it that Epic's manifest happens to name, and not one assembled from the
---install request.
---
---Corrected on the way out rather than only on the way in, because the library is
---cached: a cache written before this was understood holds the executable's
---folder, and reading it back is what the shortcut and the size are built from.
---From {@link installed_by_name}, so the answer costs the same whatever the
---library's size.
---@param app_name string
---@return string|nil path
---@return string|nil folder The directory's own name
function library.install_dir(app_name)
  local game = installed_by_name[app_name]

  if game then
    return library.app_dir(game.install_path, game.folder_name), game.folder_name
  end

  return nil
end

return library
