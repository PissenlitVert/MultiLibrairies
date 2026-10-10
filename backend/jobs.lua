local fs = require("fs")
local json = require("json")
local logger = require("logger")
local platform = require("platform")
local shell = require("shell")
local utils = require("utils")

-- Work too long to wait for: installs, updates, uninstalls.
--
-- Running one through `shell.run` would freeze the Lua state, and every RPC
-- with it, for the length of the download. So a job is a detached process that
-- owns the command and writes its progress and its last error to small files;
-- this module only reads those files back.
--
-- Nothing here knows what it is running. The progress lines it watches for are
-- legendary's, but the caller supplies the program and the arguments, and
-- `legendary.lua` is what turns "install this game" into either of those.
--
-- legendary refuses to run two of these at once, so only one job ever has a
-- runner. The rest sit in the directory with everything needed to start them
-- and no process, and `jobs.list()` starts the next one as soon as it sees the
-- previous finish. The queue is therefore on disk like the rest of it, and a
-- Steam restart mid-queue loses nothing.
--
-- The frontend polls `jobs.list()` about once a second, so that path stays
-- cheap: it only reads files, and nothing it reads grows with the download.

local jobs = {}

local ROOT = utils.get_backend_path() .. "/data/jobs"

--- Everything a job directory holds, named the way `shell.lua` names the
--- daemon's files: the ones the runner process itself owns carry its name, and
--- the small ones it writes as it goes say what is in them.
---
--- The runner script spells these as `{lock}` and so on rather than repeating
--- them, so this table stays the only place they're written down.
local FILES = {
  lock = "runner.lock",
  script = platform.IS_WINDOWS and "runner.ps1" or "runner.sh",
  program = "progress.awk",
  launcher = "runner.vbs",
  pid = "runner.pid",
  meta = "job.json",
  log = "log.txt",
  status = "status.txt",
  error = "error.txt",
  exit = "exit.txt",
  paused = "paused.txt",
  spawned = "spawned.txt",
}

--- How long a job is allowed to have neither a lock nor a PID before it counts
--- as a runner that never came up. Only has to cover a wscript launch.
local SPAWN_GRACE = 15

--- How many times a job interrupted without reporting is picked up again.
---
--- A runner that is killed rather than finishing - a reboot, an out-of-memory
--- kill, a power cut - leaves what it had already fetched on disk, and the same
--- command resumes from it, so the first interruption is worth another go. It is
--- not worth an unlimited number: something that reliably kills the job is
--- broken outside this plugin, and retrying forever hides that behind a job
--- that never sits still.
local MAX_ATTEMPTS = 3

---@alias JobKind "install" | "update" | "uninstall"
---@alias JobState "queued" | "running" | "paused" | "done" | "failed"

---@class JobProgress
---@field percent number 0-100
---@field downloaded integer Bytes, as legendary counts them
---@field total integer Bytes
---@field eta string|nil "00:10:00", straight from legendary
---@field elapsed string|nil "00:01:23"
---@field speed number|nil MiB/s, raw off the wire

---@class Job
---@field app_name string
---@field kind JobKind
---@field attempts integer How many times this job has been started, so one interrupted run is not read as a first attempt for ever
---@field state JobState
---@field pid integer|nil PID of the runner, which owns legendary as a child
---@field started_at integer When the job was asked for, which is its place in the queue
---@field spawned_at integer|nil When its runner was actually launched, nil while queued
---@field exit_code integer|nil Set once the runner has finished
---@field progress JobProgress|nil
---@field error string|nil Last error line legendary printed, when it failed
---@field interrupted boolean|nil True when the job was killed without finishing and the attempts ran out

-- Job directories -------------------------------------------------------------

---One directory per game. Epic's app names are alphanumeric already, but
---they're not ours to trust as path components.
---@param app_name string
---@return string
local function job_dir(app_name)
  return ROOT .. "/" .. (app_name:gsub("[^%w%-%_]", "_"))
end

---One of a job directory's files, by its key in `FILES`.
---@param dir string
---@param key string
---@return string
local function file(dir, key)
  return dir .. "/" .. FILES[key]
end

---Read a file, or nil if it isn't there yet. The runner creates these as it
---goes, so missing is normal.
---@param path string
---@return string|nil
local function read(path)
  if not fs.is_file(path) then
    return nil
  end
  return utils.read_file(path)
end

-- The runner ------------------------------------------------------------------

--- The script the detached process runs. legendary goes in a pipeline so this
--- one PID owns everything - `taskkill /T` on it takes legendary down too - and
--- `2>&1` pulls in stderr, where the progress lines go.
---
--- Every line is appended to the log, and the ones carrying progress or an error
--- also overwrite a small file of their own, so reading either back never costs
--- a scan of a log hundreds of kilobytes long.
local RUNNER = [[
$ErrorActionPreference = 'Continue'

# Held, unshared, for as long as this process lives, so the plugin can tell
# whether the runner is still going by trying to open it. Deliberately never
# closed: the handle goes when the process does, which is after the exit code
# at the end of this script has been written.
$Lock = [System.IO.File]::Open("$Dir\{lock}", 'Create', 'Write', 'None')

$PID | Out-File -Encoding ascii -FilePath "$Dir\{pid}"

# One handle held open for the whole download rather than an open, write and
# close per line: legendary prints thousands of them, and it is the only work
# this loop does on every single one.
$Log = New-Object System.IO.StreamWriter "$Dir\{log}", $true, (New-Object System.Text.UTF8Encoding $false)
$Log.AutoFlush = $true

$percent = 0; $done = 0; $total = 0; $eta = ''; $elapsed = ''; $speed = 0

& $Exe @Arguments 2>&1 | ForEach-Object {
  $line = [string]$_
  $Log.WriteLine($line)

  if ($line -match 'Progress: ([\d.]+)% \((\d+)/(\d+)\), Running for ([\d:]+), ETA: ([\d:]+)') {
    $percent = $matches[1]; $done = $matches[2]; $total = $matches[3]
    $elapsed = $matches[4]; $eta = $matches[5]
  } elseif ($line -match 'Download\s+- ([\d.]+) MiB/s \(raw\)') {
    $speed = $matches[1]
  } else {
    if ($line -match '(ERROR|CRITICAL):') {
      $line | Out-File -Encoding utf8 -FilePath "$Dir\{error}"
    }
    return
  }

  @(
    "percent=$percent", "downloaded=$done", "total=$total",
    "eta=$eta", "elapsed=$elapsed", "speed=$speed"
  ) -join "`n" | Out-File -Encoding ascii -FilePath "$Dir\{status}"
}

$code = $LASTEXITCODE
$Log.Dispose()
if ($null -eq $code) { $code = 0 }
$code | Out-File -Encoding ascii -FilePath "$Dir\{exit}"
]]

--- The script as the runner actually runs it.
local RUNNER_SCRIPT = (RUNNER:gsub("{(%w+)}", FILES))

-- The same job on Linux, as a POSIX shell script.
--
-- legendary is a Python program that reports progress on stderr, one line at a
-- time, so this is the same job as the PowerShell above: every line goes to the
-- log, the two shapes worth knowing about - a progress line and a speed line -
-- go to the status file, the last error goes to its own file, and the exit code
-- goes to its own file last.
--
-- The awk program is written to a file of its own by a quoted heredoc and run
-- with `awk -f`, rather than being pasted into a single-quoted shell argument.
-- Inside one of those it is a shell string first and an awk program second, so a
-- stray apostrophe in a comment ends the program where nobody is looking and
-- takes the download's progress reporting down with it. A heredoc cannot do
-- that.

---The awk program that turns legendary's output into the files this module
---polls. Kept apart from the shell around it for the reason above.
local AWK_PROGRESS = [[
function flush_status(   line) {
  line = sprintf("percent=%s\ndownloaded=%s\ntotal=%s\neta=%s\nelapsed=%s\nspeed=%s\n", \
    percent, downloaded, total, eta, elapsed, speed)
  printf "%s", line > status_file
  # Closed so the next write truncates rather than appends: the file holds this
  # snapshot, not every snapshot so far.
  close(status_file)
}

{
  print >> log_file

  if (match($0, /Progress: [0-9.]+%/)) {
    percent = substr($0, RSTART + 10, RLENGTH - 11)
    progress_seen = 1
  }

  if (match($0, /\([0-9]+\/[0-9]+\)/)) {
    split(substr($0, RSTART + 1, RLENGTH - 2), counts, "/")
    downloaded = counts[1]
    total = counts[2]
  }

  if (match($0, /Running for [0-9:]+/)) {
    elapsed = substr($0, RSTART + 12, RLENGTH - 12)
  }

  if (match($0, /ETA: [0-9:]+/)) {
    eta = substr($0, RSTART + 5, RLENGTH - 5)
  }

  if (match($0, /[0-9.]+ MiB\/s \(raw\)/)) {
    speed = substr($0, RSTART, RLENGTH - 12)
  }

  # At the end of the line, not where the progress was recognised: the byte
  # counts and the ETA are further along the same line, so a status written
  # before they are read carries the previous line's numbers.
  if (progress_seen) {
    flush_status()
    progress_seen = 0
  }

  if ($0 ~ /(ERROR|CRITICAL):/) {
    print > error_file
    close(error_file)
  }
}

END {
  close(log_file)
  close(status_file)
  close(error_file)
}
]]

local RUNNER_POSIX = [[
#!/bin/sh
# Written by the Epic Games plugin: run as `sh runner.sh <command> [args...]`,
# with the job's own directory already filled in below. Nothing here is meant to
# be edited by hand.
DIR={DIR}

# Whatever this script itself has to say - a missing awk, a directory that went
# away - goes in the log beside the command's own output. Spawned with its own
# streams closed, the alternative is a runner that dies quietly and a job that
# then reads as a download which did nothing, which is the one answer nobody can
# act on.
exec >> "$DIR/{log}" 2>&1

# The runner's own PID, which is also its process group's ID: `spawn` started it
# under setsid, so stopping the job is a kill on -PID and takes legendary down
# with it rather than leaving an orphaned download writing into a directory
# nobody is watching.
echo $$ > "$DIR/{pid}"

# The program is written out rather than quoted into the command line, so
# nothing in it - a comment, a regex, an apostrophe - can be read by the shell.
# The variables are named with a _file suffix because `log` is gawk's natural
# logarithm, and `awk -v log=...` is a fatal error there.
cat > "$DIR/{program}" <<'AWK_PROGRAM_END'
]] .. AWK_PROGRESS .. [[
AWK_PROGRAM_END

# The exit code is written by the group rather than read off the pipeline: in a
# POSIX shell `$?` after `a | b` is b's status, which here would be awk's, and
# every download would be recorded as a failure.
{ "$@" 2>&1; printf '%s' "$?" > "$DIR/{exit}.part"; } |
  awk -f "$DIR/{program}" \
    -v log_file="$DIR/{log}" \
    -v status_file="$DIR/{status}" \
    -v error_file="$DIR/{error}"

# Renamed into place last, so a poll never sees an exit code next to output that
# is still being written.
mv -f "$DIR/{exit}.part" "$DIR/{exit}"
]]

--- The Linux script as the runner actually runs it, with the job's own directory
--- filled in where the PowerShell version has it as a variable. Through a
--- function rather than a pattern: a path is data, and a `$` or a `%` in one
--- would otherwise be read as a replacement escape.
---@param dir string
---@return string
local function posix_script(dir)
  return (RUNNER_POSIX:gsub("{DIR}", function()
    return shell.quote(dir)
  end):gsub("{(%w+)}", FILES))
end

---Start a detached runner for one legendary command.
---
---On Windows that runner is a hidden PowerShell, reached through wscript because
---it is the only way to get no console window at all: `powershell
----WindowStyle Hidden` still flashes one, and this window would sit on screen for
---the length of the download.
---
---On Linux it is a shell script with nothing to hide - a process started from
---Steam has no window at all - so it is run through `setsid` instead, which
---gives it its own process group. That is what makes stopping one a job: killing
---the group takes legendary down with it, the way `taskkill /T` does on Windows.
---@param dir string
---@param exe string The program the runner owns
---@param args string[] Arguments to it
---@return boolean started
---@return string? error
local function spawn(dir, exe, args)
  if not platform.IS_WINDOWS then
    -- The command is handed to the script as arguments rather than written into
    -- it, so the shell that runs it does the splitting and no quoting rule of
    -- ours can be wrong about it.
    local command = { "sh " .. shell.quote(file(dir, "script")), shell.quote(exe) }
    for _, arg in ipairs(args) do
      table.insert(command, shell.quote(arg))
    end

    local ok, err = utils.write_file(file(dir, "script"), posix_script(dir))
    if not ok then
      return false, "Could not write the job script: " .. tostring(err)
    end

    -- Before the launch, not after: this is what stops the job reading as
    -- queued, and a read landing in between would otherwise start a second
    -- runner.
    utils.write_file(file(dir, "spawned"), tostring(math.floor(utils.time())))

    -- `setsid` is in util-linux and on every distribution Steam runs on, but a
    -- machine without it still gets its download: the process group is what
    -- makes a clean stop possible, not what makes the start possible.
    local detached = fs.is_file("/usr/bin/setsid") and "setsid " or ""
    utils.exec(
      "nohup " .. detached .. table.concat(command, " ") .. " </dev/null >/dev/null 2>&1 &"
    )
    return true
  end

  local quoted = {}
  for index, arg in ipairs(args) do
    quoted[index] = shell.ps_quote(arg)
  end

  local script = "$Dir = "
    .. shell.ps_quote(dir)
    .. "\n$Exe = "
    .. shell.ps_quote(exe)
    -- Not $Args: that's a PowerShell automatic variable and can't be assigned.
    .. "\n$Arguments = @("
    .. table.concat(quoted, ", ")
    .. ")\n"
    .. RUNNER_SCRIPT

  local script_path = file(dir, "script")
  local ok, err = utils.write_file(script_path, script)
  if not ok then
    return false, "Could not write the job script: " .. tostring(err)
  end

  local launcher_path = file(dir, "launcher")
  ok, err = utils.write_file(
    launcher_path,
    shell.vbs_launcher(
      'powershell -NoProfile -ExecutionPolicy Bypass -File "'
        .. (script_path:gsub("/", "\\"))
        .. '"'
    )
  )
  if not ok then
    return false, "Could not write the job launcher: " .. tostring(err)
  end

  -- Before the launch, not after: this is what stops the job reading as queued,
  -- and a read landing in between would otherwise start a second runner.
  utils.write_file(file(dir, "spawned"), tostring(math.floor(utils.time())))

  -- Returns as soon as wscript has handed the runner off, which is the point:
  -- nothing here waits for a download.
  shell.run("wscript", { (launcher_path:gsub("/", "\\")) })
  return true
end

-- Reading a job back ----------------------------------------------------------

---Is the runner that owns this directory still alive?
---
---Asked once a second per job, so it can't cost a subprocess: `tasklist` here
---was a console window flashing up and stealing focus for the length of every
---download. The runner holds `runner.lock` open unshared instead, the same way
---the command daemon holds `daemon.lock`, and nothing else can open it until
---the process has exited.
---
---On Linux the runner writes its PID instead and `/proc` answers for free, which
---is the same question asked of the filesystem rather than of a file's lock.
---@param dir string
---@param pid integer|nil
---@param spawned_at integer|nil
---@return boolean
local function is_running(dir, pid, spawned_at)
  if not platform.IS_WINDOWS then
    if not pid then
      return (utils.time() - (spawned_at or 0)) < SPAWN_GRACE
    end
    return shell.pid_alive(pid)
  end

  local lock = file(dir, "lock")
  if not fs.is_file(lock) then
    -- The runner takes the lock before it writes its PID, so no lock and a PID
    -- is a job that predates the lock or one whose runner died on the way up.
    -- No lock and no PID is the first moments of a job - but only for a moment:
    -- a wscript that never got the runner up would otherwise leave a job that
    -- reads as running forever, polled once a second with nothing behind it.
    return pid == nil and (utils.time() - (spawned_at or 0)) < SPAWN_GRACE
  end

  return shell.is_locked(lock)
end

---@param dir string
---@return JobProgress|nil
local function read_progress(dir)
  local text = read(file(dir, "status"))
  if not text then
    return nil
  end

  local fields = {}
  -- Underscores included: a key pattern of `%w+` reads `updated_at` as `at`.
  for key, value in text:gmatch("([%w_]+)=([^\r\n]*)") do
    fields[key] = value
  end
  if not fields.percent then
    return nil
  end

  return {
    percent = tonumber(fields.percent) or 0,
    downloaded = tonumber(fields.downloaded) or 0,
    total = tonumber(fields.total) or 0,
    eta = fields.eta ~= "" and fields.eta or nil,
    elapsed = fields.elapsed ~= "" and fields.elapsed or nil,
    speed = tonumber(fields.speed),
  }
end

---@param dir string
---@return table|nil
local function read_meta(dir)
  local text = read(file(dir, "meta"))
  if not text then
    return nil
  end

  local ok, meta = pcall(json.decode, text)
  if not ok or type(meta) ~= "table" then
    return nil
  end
  return meta
end

---Build one job out of its directory and the metadata already read from it.
---
---State is derived rather than stored, since the runner can die without getting
---to record anything: an exit code means finished, a held lock means running,
---and a lock nobody holds with no exit code means the runner died - deliberately
---if pause left its marker behind, otherwise not. A job that was never spawned
---at all is one still waiting its turn.
---
---A runner that vanished without an exit code is the case worth being careful
---about. Steam going away does not produce one: the runner is started in its own
---session, so it outlives the client and is still running next time we look. What
---does produce one is the machine going away - a reboot, an out-of-memory kill, a
---power cut - and the difference matters because the bytes it had already fetched
---are still on disk and the command resumes from them. So that is a job to pick
---up again rather than a failure to report, until it has been picked up enough
---times that something outside this plugin is clearly at fault.
---@param dir string
---@param meta table
---@return Job
local function build(dir, meta)
  local pid = tonumber(read(file(dir, "pid")) or "")
  local exit_code = tonumber(read(file(dir, "exit")) or "")
  local spawned_at = tonumber(read(file(dir, "spawned")) or "")
  local started_at = meta.started_at or 0
  local attempts = meta.attempts or 0

  ---@type JobState
  local state
  ---Whether a runner died without reporting, rather than reporting a failure.
  local interrupted = false

  if exit_code then
    state = exit_code == 0 and "done" or "failed"
  elseif fs.is_file(file(dir, "paused")) then
    -- Pausing is a kill, so this marker is the only evidence that the missing
    -- process was meant to be missing.
    state = "paused"
  elseif not spawned_at then
    state = "queued"
  elseif is_running(dir, pid, spawned_at) then
    state = "running"
  elseif attempts < MAX_ATTEMPTS then
    -- Nothing reported it a result, so it is queued again and `promote` starts
    -- it - which is what resuming is, for a command that knows how to.
    state = "queued"
    interrupted = true
  else
    state = "failed"
    interrupted = true
  end

  local error_line = utils.trim(read(file(dir, "error")) or "")
  if interrupted and error_line == "" then
    error_line = "Interrupted "
      .. attempts
      .. " times without finishing. Nothing was reported about why, which usually means the machine restarted or ran out of memory."
  end

  return {
    app_name = meta.app_name,
    kind = meta.kind or "install",
    state = state,
    attempts = attempts,
    interrupted = interrupted or nil,
    pid = pid,
    started_at = started_at,
    spawned_at = spawned_at,
    exit_code = exit_code,
    progress = read_progress(dir),
    error = state == "failed" and error_line or nil,
  }
end

---Read one game's job off disk, or nil if it has never had one.
---@param app_name string
---@return Job|nil
function jobs.get(app_name)
  local dir = job_dir(app_name)
  local meta = read_meta(dir)
  if not meta then
    return nil
  end

  meta.app_name = meta.app_name or app_name
  return build(dir, meta)
end

---Launch the runner a queued job has been waiting for, if it is that job's turn.
---
---Called off `jobs.list()`, which the frontend polls, so the queue moves on
---roughly a second after the job ahead of it ends. There is no timer behind
---this and nothing in memory holding the order: the oldest `started_at` with no
---runner goes next.
---@param entries { dir: string, meta: table, job: Job }[]
local function promote(entries)
  ---@type { dir: string, meta: table, job: Job }|nil
  local next_up

  for _, entry in ipairs(entries) do
    if entry.job.state == "running" then
      return
    end
    if
      entry.job.state == "queued"
      and (not next_up or entry.job.started_at < next_up.job.started_at)
    then
      next_up = entry
    end
  end

  if not next_up then
    return
  end

  -- Written by `jobs.start`, which is the only thing that knows what legendary
  -- call the job stands for. Without them there is nothing to run.
  local meta = next_up.meta
  if type(meta.exe) ~= "string" or type(meta.args) ~= "table" then
    logger:warn("Dropping a queued job with nothing to run: " .. tostring(meta.app_name))
    fs.remove_all(next_up.dir)
    return
  end

  -- Counted before the attempt rather than after it, so a runner that dies
  -- without reporting still costs an attempt - which is the only way the cap
  -- can stop a job that reliably gets itself killed.
  meta.attempts = (meta.attempts or 0) + 1
  utils.write_file(file(next_up.dir, "meta"), json.encode(meta))

  -- A retry is a new attempt at a job whose runner was killed, so its leftover
  -- pid and spawn marker are exactly what would make the new one look already
  -- dead. The progress file goes too: it belongs to the attempt that died, and
  -- leaving it there means the tile shows the old percentage until the first
  -- line of the new one arrives. The log is kept, because it is the record of
  -- what happened before.
  for _, key in ipairs({ "pid", "spawned", "status", "exit", "error" }) do
    local path = file(next_up.dir, key)
    if fs.is_file(path) then
      fs.remove(path)
    end
  end

  local started, err = spawn(next_up.dir, meta.exe, meta.args)
  if not started then
    logger:error("Could not start the queued " .. tostring(meta.kind) .. ": " .. tostring(err))
    return
  end

  -- Worth saying which of the two this is: a first attempt going out is the
  -- ordinary case, and one going out again means the last runner was killed
  -- rather than finishing - which the log is the only place to notice.
  if meta.attempts > 1 then
    logger:info(
      "Picking up the interrupted "
        .. tostring(meta.kind)
        .. " for "
        .. tostring(meta.app_name)
        .. " again, attempt "
        .. tostring(meta.attempts)
    )
  else
    logger:info("Started the queued " .. tostring(meta.kind) .. " for " .. tostring(meta.app_name))
  end

  next_up.job = build(next_up.dir, meta)
end

---Every job we know about, queued, running or finished.
---
---Also where the queue moves: reading the jobs is the only thing that happens
---often enough to notice one of them ending.
---@return Job[]
function jobs.list()
  local entries = {}
  if not fs.is_directory(ROOT) then
    return {}
  end

  for _, entry in ipairs(fs.list(ROOT) or {}) do
    -- The directory name is a slug, so the app name comes out of the metadata.
    local meta = entry.is_directory and read_meta(entry.path)
    if meta and meta.app_name then
      table.insert(entries, { dir = entry.path, meta = meta, job = build(entry.path, meta) })
    end
  end

  promote(entries)

  local result = {}
  for _, entry in ipairs(entries) do
    table.insert(result, entry.job)
  end
  return result
end

-- Starting and stopping -------------------------------------------------------

---Queue one job for a game, replacing whatever it last ran, and start it if
---nothing else is running.
---
---Nothing here spawns: writing the job down is enough, and `promote` picks it
---up on the same call. So a second install while the first is downloading takes
---exactly this path and simply waits.
---@param app_name string
---@param kind JobKind
---@param exe string
---@param args string[]
---@return Job|nil job
---@return string? error
function jobs.start(app_name, kind, exe, args)
  if type(app_name) ~= "string" or app_name == "" then
    return nil, "No app name provided"
  end

  local existing = jobs.get(app_name)
  if existing and (existing.state == "running" or existing.state == "queued") then
    return existing
  end

  -- Everything from a previous run goes, or a fresh install reports the
  -- percentage the old one stopped at until its first progress line.
  local dir = job_dir(app_name)
  if fs.is_directory(dir) then
    fs.remove_all(dir)
  end
  fs.create_directories(dir)

  -- The command goes in with the rest of it, since whatever eventually runs
  -- this job may be a poll minutes from now with no memory of the request.
  local ok, err = utils.write_file(
    file(dir, "meta"),
    json.encode({
      app_name = app_name,
      kind = kind,
      started_at = math.floor(utils.time()),
      -- Zero rather than absent, so a retry can tell a second attempt from a
      -- first one without having to treat a missing field as either.
      attempts = 0,
      exe = exe,
      args = args,
    })
  )
  if not ok then
    return nil, "Could not write the job: " .. tostring(err)
  end

  logger:info("Queued " .. kind .. " for " .. app_name)

  -- Starts it too, if its turn is now.
  jobs.list()
  return jobs.get(app_name)
end

---Kill the runner behind a job we have already read.
---
---legendary has no pause, so stopping is a kill: `/T` takes legendary down with
---the runner, `/F` because it won't respond to anything gentler mid-download.
---@param app_name string
---@param job Job
---@return boolean stopped
local function stop(app_name, job)
  if job.state ~= "running" and job.state ~= "queued" then
    return false
  end

  -- Before the kill: a read landing in the gap would otherwise see a runner
  -- that vanished on its own and call the job failed. For a queued job it is
  -- the whole of the work - the marker is what takes it out of the queue.
  utils.write_file(file(job_dir(app_name), "paused"), "1")

  if job.state == "running" and job.pid then
    if platform.IS_WINDOWS then
      shell.run("taskkill", { "/F", "/T", "/PID", tostring(job.pid) })
    else
      -- The runner owns its process group, so the negative PID takes legendary
      -- down with it rather than leaving an orphaned download writing into a
      -- directory nobody is watching. SIGTERM first so legendary closes the
      -- files it is writing, SIGKILL if it has not gone by the time the next
      -- read comes round.
      shell.run("kill", { "-TERM", "--", tostring(-job.pid) })
      shell.run("kill", { "-KILL", "--", tostring(-job.pid) })
    end
  end
  return true
end

---Stop a running job, keeping what has already been downloaded. Resuming is
---re-running the install.
---@param app_name string
---@return boolean stopped
function jobs.pause(app_name)
  local job = jobs.get(app_name)
  if not job or not stop(app_name, job) then
    return false
  end

  logger:info("Paused " .. app_name)
  return true
end

---Stop a job and forget it ever ran. What's on disk is left alone - removing a
---partial install is `uninstall`'s job.
---@param app_name string
---@return boolean cancelled
function jobs.cancel(app_name)
  local job = jobs.get(app_name)
  if not job then
    return false
  end

  stop(app_name, job)
  fs.remove_all(job_dir(app_name))
  logger:info("Cancelled " .. app_name)
  return true
end

return jobs
