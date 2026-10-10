local fs = require("fs")
local logger = require("logger")
local text = require("text")
local trace = require("trace")
local utils = require("utils")

-- The Linux half of `shell.lua`, reached through its platform check at the
-- bottom of that module.
--
-- Everything the Windows daemon exists for is unnecessary here. There is no
-- console window to hide - a process started from Steam on Linux has no window
-- at all - so there is nothing to flash, nothing to hide, and no reason to keep
-- a PowerShell process alive to run commands on our behalf.
--
-- So a command is a small shell script, written once and started detached with
-- its output redirected to files. The interface is the daemon's, unchanged:
-- `start` hands back an id, `poll` answers once the exit code file has landed,
-- and `run` is the two of them in a loop with a deadline. Everything above this
-- file - legendary, jobs, the RPC layer - is written against that interface and
-- does not know which half of the module it is talking to.
--
-- The window this used to cost has one thing left: Steam starting while the
-- command is already running. `run` still blocks the Lua state for as long as
-- the command takes, which is why the work too slow for that lives in jobs.

local shell = {}

local ROOT = utils.get_backend_path() .. "/data/shell"

--- One command's files: the script that runs it, its output, and the exit code
--- written last so its arrival means the output beside it is complete.
local function file(id, extension)
  return ROOT .. "/" .. id .. "." .. extension
end

---Long enough for a slow `legendary list` on a big library, short enough that a
---script that has wedged doesn't hang Steam forever.
local TIMEOUT = 120000

--- How many broken responses to hold on to. Enough that the one which caused
--- trouble is still there a few commands later, few enough to not quietly
--- become a second copy of the library on disk.
local KEEP = 10

-- Small helpers ---------------------------------------------------------------

--- What to multiply milliseconds by to get whatever unit `utils.sleep` takes,
--- measured once rather than assumed.
---@type number|nil
local sleep_scale = nil

---Sleep for roughly `ms` milliseconds.
---@param ms number
local function nap(ms)
  if not sleep_scale then
    local started = utils.time_ms()
    pcall(utils.sleep, 1)
    sleep_scale = (utils.time_ms() - started) >= 500 and 0.001 or 1
  end

  pcall(utils.sleep, ms * sleep_scale)
end

---Escape a string for a single-quoted POSIX shell literal: close the quote,
---put an escaped one in its place, reopen. The only escape a shell has, and
---the reason every path goes through here rather than being concatenated.
---@param value string
---@return string
function shell.quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

---@param args (string|number)[]|nil
---@return string[]
local function to_strings(args)
  local result = {}
  for index, arg in ipairs(args or {}) do
    result[index] = tostring(arg)
  end
  return result
end

---Is that PID still running?
---
---The daemon on Windows proves liveness by holding a file open unshared; a
---shell has no equivalent that costs nothing, but `/proc` is the same trick for
---free - the directory exists exactly as long as the process does.
---@param pid integer|nil
---@return boolean
function shell.pid_alive(pid)
  if not pid or pid <= 0 then
    return false
  end

  -- Only Linux has /proc. Anywhere else there is no cheap answer, so a job is
  -- taken on its exit code alone rather than on a guess that costs a process
  -- launch once a second.
  if not fs.is_directory("/proc") then
    return true
  end

  return fs.is_directory("/proc/" .. pid)
end

---Is `path` a lock file that some process is holding open?
---
---Windows-only: nothing on Linux holds the job runner's lock, and the callers
---ask about a process instead. Kept so the interface `jobs.lua` is written
---against exists on both platforms.
---@param path string
---@return boolean
function shell.is_locked(path)
  return fs.is_file(path)
end

---Nothing to start on Linux, and nothing that can fail to start.
---@return boolean available
function shell.ensure()
  return true
end

-- Running a command -----------------------------------------------------------

---Start a program detached and answer no more until `shell.poll` is called.
---@param exe string
---@param args string[]|nil
---@param options { cwd?: string }|nil
---@return string|nil id Hand this to `shell.poll`
---@return string? error
function shell.start(exe, args, options)
  options = options or {}
  local arguments = to_strings(args)
  local id = utils.uuid()

  fs.create_directories(ROOT)

  -- The script rather than a command line: the argument list is data, and a
  -- shell line assembled by concatenation is where quoting bugs live. The
  -- command itself is one line - a quoted token on a line of its own is a
  -- command of its own to a shell, which is not what an argument is.
  local command = { shell.quote(exe) }
  for _, argument in ipairs(arguments) do
    table.insert(command, shell.quote(argument))
  end

  local script = { "#!/bin/sh" }

  if options.cwd and options.cwd ~= "" then
    script[#script + 1] = "cd " .. shell.quote(options.cwd) .. " 2>/dev/null || cd /"
  end

  script[#script + 1] = "exec >>" .. shell.quote(file(id, "out") .. ".part") .. " 2>&1"
  script[#script + 1] = table.concat(command, " ")
  script[#script + 1] = "__code=$?"
  script[#script + 1] =
    "mv -f " .. shell.quote(file(id, "out") .. ".part") .. " " .. shell.quote(file(id, "out"))
  script[#script + 1] = "printf '%s' \"$__code\" > " .. shell.quote(file(id, "code") .. ".part")
  script[#script + 1] =
    "mv -f " .. shell.quote(file(id, "code") .. ".part") .. " " .. shell.quote(file(id, "code"))

  local ok, err = utils.write_file(file(id, "sh"), table.concat(script, "\n") .. "\n")
  if not ok then
    return nil, "Could not write the command script: " .. tostring(err)
  end

  -- Backgrounded with everything detached from Steam's own streams, so this
  -- returns at once and the command keeps running whatever Steam does next -
  -- which is what lets an install survive a client restart. `setsid` when it is
  -- there gives the command its own process group, so `jobs.lua` can take a
  -- whole download down rather than the shell wrapped round it.
  local runner = fs.is_file("/usr/bin/setsid") and "setsid " or ""
  local command = "nohup "
    .. runner
    .. "sh "
    .. shell.quote(file(id, "sh"))
    .. " </dev/null >/dev/null 2>&1 &"

  utils.exec(command)

  trace.event("shell.spawn", { id = id, exe = exe, args = #arguments })
  return id
end

---Drop all but the newest kept responses.
---@param dir string
local function prune(dir)
  local entries = fs.list(dir) or {}
  if #entries <= KEEP then
    return
  end

  table.sort(entries, function(a, b)
    return (fs.last_write_time(a.path) or 0) > (fs.last_write_time(b.path) or 0)
  end)
  for index = KEEP + 1, #entries do
    fs.remove(entries[index].path)
  end
end

---Move one command's output somewhere it outlives the call.
---
---A response that isn't valid UTF-8 is the shape that used to take Millennium
---down, and the bytes are the only thing that says which command produced them.
---@param id string
---@param out_path string
---@param output string
---@param position integer
local function keep(id, out_path, output, position)
  local dir = ROOT .. "/kept"
  fs.create_directories(dir)

  if not fs.rename(out_path, dir .. "/" .. id .. ".out") then
    return
  end

  trace.anomaly("shell.invalid_utf8", { id = id, bytes = text.window(output, position) })
  prune(dir)
end

---Has the command finished? Nil while it is still going, and the files are
---cleaned up by the read that collects them, so an id answers once.
---@param id string
---@return string|nil output
---@return integer? code
function shell.poll(id)
  local code_path = file(id, "code")
  local out_path = file(id, "out")

  if not fs.is_file(code_path) then
    return nil
  end

  local output = utils.read_file(out_path) or ""
  local code = tonumber(utils.trim(utils.read_file(code_path) or "")) or -1

  local invalid = text.first_invalid(output)
  if invalid then
    keep(id, out_path, output, invalid)
  elseif fs.is_file(out_path) then
    fs.remove(out_path)
  end
  fs.remove(code_path)
  -- The script has done its job by the time there is an exit code to read, and
  -- every command of a session writes one: kept, they are the largest thing in
  -- the plugin's data directory.
  fs.remove(file(id, "sh"))

  return output, code
end

---Give up on a command that is still queued, so its answer is never collected.
---@param id string
function shell.forget(id)
  for _, extension in ipairs({ "sh", "out", "code", "out.part", "code.part" }) do
    local path = file(id, extension)
    if fs.is_file(path) then
      fs.remove(path)
    end
  end
end

---Run a program and block until it exits.
---@param exe string
---@param args string[]|nil
---@param options { cwd?: string, timeout?: integer }|nil
---@return string output stdout followed by stderr
---@return integer code -1 if the command could not be run at all
function shell.run(exe, args, options)
  options = options or {}

  local id, err = shell.start(exe, args, options)
  if not id then
    logger:warn(tostring(err))
    trace.anomaly("shell.failed", { exe = exe, error = tostring(err) })
    return "", -1
  end

  local deadline = utils.time_ms() + (options.timeout or TIMEOUT)
  while true do
    local output, code = shell.poll(id)
    if output then
      return output, code or -1
    end

    if utils.time_ms() > deadline then
      logger:warn("Command timed out: " .. tostring(exe))
      trace.anomaly("shell.timeout", { exe = exe, ms = options.timeout or TIMEOUT })
      shell.forget(id)
      return "", -1
    end
    nap(5)
  end
end

return shell
