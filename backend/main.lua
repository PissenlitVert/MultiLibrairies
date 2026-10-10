local grid = require("grid")
local legendary = require("legendary")
local library = require("library")
local logger = require("logger")
local millennium = require("millennium")
local launcher = require("launcher")
local shell = require("shell")
local trace = require("trace")

-- Millennium resolves RPC method names in _G, so every method has to be a
-- global. Copied by name so a method added to rpc.lua can't be forgotten here.
local RPC = require("rpc").RPC
for name, handler in pairs(RPC) do
  -- selene: allow(global_usage)
  _G[name] = handler
end

local function on_load()
  -- Written first, so the trace file says where one Steam session ends and the
  -- next begins even when the one before it stopped by crashing.
  trace.event("load")

  -- Started here so the one console window it costs goes up in the middle of
  -- Steam's own startup rather than in front of the first thing the user does.
  -- On Linux there is no window to cost: `shell.ensure()` has nothing to start
  -- and says so.
  shell.ensure()
  trace.event("load.daemon")

  -- Cache only, so the first GetLibrary is answered from disk.
  library.load()
  trace.event("load.library")

  -- The script a launch runs, written here so it exists before anything asks
  -- for it: it names the vendored binary, the log and the install directory,
  -- all of which are this plugin's own.
  --
  -- What it does *not* carry is the Proton build. Steam's compatibility setting
  -- is the only source of that, and the script reads it at launch rather than
  -- having it written in here - which is the whole reason it is read there: the
  -- setting changes while Steam runs, and a build baked into a file written at
  -- start-up is one decision behind, so the game starts under a build the app
  -- details page is not naming. Nothing to bring up to date, and no restart.
  local binary = legendary.get_binary()
  if binary then
    local umu_run = legendary.umu_run()
    launcher.ensure(binary, umu_run)
  end
  trace.event("load.script")

  -- Every icon handed back to the path Steam's own shortcut entry records, which
  -- is the only path Steam ever reads. Cheap: one VDF and a directory listing,
  -- and nothing to do on every launch after the first - a second pass finds the
  -- files where it left them.
  grid.repair_recorded_icons()
  trace.event("load.icons")

  millennium.ready()
  trace.event("load.ready")
  logger:info("Backend loaded, waiting for frontend...")
end

local function on_frontend_loaded()
  -- Where the one-off download happens, so a machine missing legendary pays for
  -- it at startup rather than in the middle of the first thing it's asked to do.
  local status = legendary.get_status()
  logger:info(
    string.format(
      "Frontend loaded. legendary available=%s authenticated=%s",
      tostring(status.available),
      tostring(status.authenticated)
    )
  )
  trace.event("frontend", { available = status.available, authenticated = status.authenticated })
end

local function on_unload()
  trace.event("unload")
  logger:info("Backend unloaded")
end

return {
  on_load = on_load,
  on_frontend_loaded = on_frontend_loaded,
  on_unload = on_unload,
}
