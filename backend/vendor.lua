local fs = require("fs")
local logger = require("logger")
local platform = require("platform")
local shell = require("shell")
local utils = require("utils")

-- Fetches the legendary binary on first use, from a release pinned by tag *and*
-- by SHA-256: a download that doesn't hash to exactly the bytes recorded below
-- is thrown away, so a compromised release or a hijacked CDN can't put a
-- different executable on a user's machine.
--
-- One pin per platform and per architecture, since legendary ships a PyInstaller
-- build of itself for each: there is a Linux x64 and arm64 next to the Windows
-- one, and a machine that cannot run the build it was given is a machine whose
-- login and library commands fail in ways that read like Epic being down.
--
-- To upgrade, bump VERSION and replace SHA256 with the `digest` field GitHub
-- publishes for the asset:
--
--   curl -sL https://api.github.com/repos/legendary-gl/legendary/releases/latest
--
-- legendary is GPL-3.0, fetched unmodified and never redistributed by us.

local vendor = {}

local VERSION = "0.21.0"

---One release's asset for one machine, and the name it takes on disk here.
---@class Asset
---@field name string The name it is published under
---@field sha256 string Its published digest
---@field local_name string The name under `vendor/`, which every shortcut points at
local ASSETS = {
  windows = {
    ["x86_64"] = {
      name = "legendary_windows_x64.exe",
      sha256 = "4c01a14c0acb0c46069b197ae7212ea4ea6b861661126ca0593cdac31658fb01",
      local_name = "legendary.exe",
    },
    ["aarch64"] = {
      name = "legendary_windows_arm64.exe",
      sha256 = "839e0d2298f9126608b0c851b9231055e8fa907c624a8bce0a58278efb221068",
      local_name = "legendary.exe",
    },
  },
  linux = {
    ["x86_64"] = {
      name = "legendary_linux_x64",
      sha256 = "c83d1595a9e2cbae4e66b69ecaa1f8649da99b617a72f93312d342e6a5a799c7",
      local_name = "legendary",
    },
    ["aarch64"] = {
      name = "legendary_linux_arm64",
      sha256 = "ed0a523c7310aec590a0da9ecdada185fc3b02e75fa5148c0e7ef0680095dce5",
      local_name = "legendary",
    },
  },
}

---The release this machine's build comes from.
---@return Asset|nil asset
---@return string? error
local function asset()
  local releases = platform.IS_WINDOWS and ASSETS.windows or ASSETS.linux
  local architecture = platform.architecture()

  local found = releases[architecture]
  if not found then
    -- x86_64 is what Steam itself runs on everywhere else, including the
    -- machines nobody names. A miss here is a 32-bit Windows or an unusual
    -- Linux, and there is no build for either.
    return nil, "No legendary build for " .. platform.os_name() .. " " .. architecture
  end

  return found
end

---The URL the asset is fetched from.
---@param asset Asset
---@return string
local function url_for(asset)
  return "https://github.com/legendary-gl/legendary/releases/download/"
    .. VERSION
    .. "/"
    .. asset.name
end

--- Where the binary is kept. The name has no version in it because every Steam
--- shortcut points at this path: an upgrade replaces the file in place, which
--- the hash check notices on its own.
local DIR = utils.get_backend_path() .. "/vendor"

--- Where this machine's binary is, which depends on the platform and the CPU.
---@type string|nil
local path = nil

---The SHA-256 of a file, lowercase hex, or nil if it couldn't be hashed.
---certutil ships with Windows and sha256sum with Linux, so there's nothing to
---install on either.
---@param file string
---@return string|nil
local function digest(file)
  local program, arguments
  if platform.IS_WINDOWS then
    program = "certutil"
    arguments = { "-hashfile", platform.to_native(file), "SHA256" }
  else
    program = "sha256sum"
    arguments = { file }
  end

  local output, code = shell.run(program, arguments)
  if code ~= 0 then
    logger:warn(program .. " could not hash " .. file .. ", exited " .. code)
    return nil
  end

  -- Matched a line at a time, taking the run of hex digits the line starts
  -- with: certutil's banner carries the path and its trailer starts with hex
  -- letters of its own, so reading the whole line would glue those letters onto
  -- the digits this is after. sha256sum's line is `<hash>  <path>`, which the
  -- same pattern reads by ignoring everything after the hash.
  for line in output:gmatch("[^\r\n]+") do
    local hash = line:match("^(%x+)")
    if hash and #hash == 64 then
      return hash:lower()
    end
  end

  logger:warn("No hash found in " .. platform.os_name() .. " output from " .. program)
  return nil
end

---Is the file at `file` the executable we pinned?
---@param file string
---@param build Asset The release it is supposed to be
---@return boolean
local function verified(file, build)
  if not fs.is_file(file) then
    return false
  end
  return digest(file) == build.sha256
end

---Make a file executable, which a download from a web server never is.
---
---Only on Linux: a file that Steam cannot exec fails with a permission error
---rather than a missing binary, which reads like the wrong thing entirely. A
---hash of a file we already have is cheap, and so is this, but neither should run
---once a second for a command that isn't downloading anything.
---@param file string
local function make_executable(file)
  if platform.IS_WINDOWS then
    return
  end

  shell.run("chmod", { "+x", file })
end

---The downloader that worked last time, so a machine where curl cannot run
---under Steam does not pay for that discovery on every version bump.
---@type string|nil
local downloader = nil

---Run a downloader with an environment it was not handed by Steam.
---
---Steam exports `OPENSSL_CONF=/dev/null` and puts pressure-vessel's override
---directories on `LD_LIBRARY_PATH` for every process it starts, plugin
---included. A tool that insists on a readable OpenSSL config, or that picks up
---a library out of one of those alias directories, fails to start at all -
---before it has written a byte, which is exactly the shape of "the download
---did not produce a file". Unsetting is not the same as pointing at /dev/null,
---so the variable is removed rather than emptied.
---@param program string
---@param arguments string[]
---@return string output
---@return integer code
local function run_clean(program, arguments)
  if platform.IS_WINDOWS then
    return shell.run(program, arguments, { timeout = 300000 })
  end

  -- `env` is coreutils and takes `-u NAME` to drop a variable from the
  -- environment it then execs, so the downloader sees Steam's PATH but not
  -- Steam's OpenSSL configuration. Built as a table rather than spliced,
  -- which also keeps it clear that the program is the one argument `env` runs.
  local wrapped = { "-u", "OPENSSL_CONF", program }
  for _, argument in ipairs(arguments) do
    wrapped[#wrapped + 1] = argument
  end

  return shell.run("env", wrapped, { timeout = 300000 })
end

---Fetch a URL to a file, blocking until it's there.
---
---The downloader's own message and exit code are logged when it produces no
---file. Without them the log says only that a file is missing, which is the
---one thing it already knew, and the next person to hit it has nothing to go
---on but the guess that it was the network.
---@param file string
---@param from string
---@return boolean ok
function vendor.fetch(file, from)
  ---Try one downloader, and say why it did not work.
  ---@param label string
  ---@param program string
  ---@param arguments string[]
  ---@return boolean ok
  local function attempt(label, program, arguments)
    if fs.is_file(file) then
      return true
    end

    local output, code = run_clean(program, arguments)
    if fs.is_file(file) then
      downloader = program
      return true
    end

    -- Trimmed to one line: a downloader that printed a progress bar otherwise
    -- buries the reason under a screenful of carriage returns.
    local reason = utils.trim(output):gsub("[\r\n]+", " | ")
    if reason == "" then
      reason = "no output"
    end

    logger:warn(
      label .. " did not produce a file (exit " .. tostring(code) .. "): " .. reason
    )
    return false
  end

  if platform.IS_WINDOWS then
    -- The PowerShell fallback is for a Windows old enough to be missing
    -- curl.exe.
    if attempt("curl", "curl.exe", { "-fsSL", "--retry", "2", "-o", platform.to_native(file), from }) then
      return true
    end

    logger:info("curl did not produce a file, falling back to PowerShell")
    shell.run("powershell", {
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-Command",
      "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri '"
        .. from
        .. "' -OutFile '"
        .. platform.to_native(file)
        .. "'",
    }, { timeout = 300000 })

    return fs.is_file(file)
  end

  -- curl rather than wget: it is what Steam's own runtime already ships, so the
  -- machine running Steam is the machine that has it. wget is the fallback for
  -- a distribution that somehow has neither. Whichever of the two answered
  -- last time goes first, since the order only matters for the one machine that
  -- needs the other one.
  local preferred, fallback
  if downloader == "wget" then
    preferred, fallback = "wget", "curl"
  else
    preferred, fallback = "curl", "wget"
  end

  local arguments = preferred == "wget"
    and { "-q", "-O", file, from }
    or { "-fsSL", "--retry", "2", "-o", file, from }

  if attempt(preferred, preferred, arguments) then
    return true
  end

  logger:info(preferred .. " did not produce a file, falling back to " .. fallback)
  local fallback_arguments = fallback == "wget"
    and { "-q", "-O", file, from }
    or { "-fsSL", "--retry", "2", "-o", file, from }

  return attempt(fallback, fallback, fallback_arguments)
end

---The legendary binary, downloading it if this machine hasn't got it yet.
---
---Blocks, since nothing here can do anything useful until it's there, and it
---only happens once per version.
---@return string|nil path
---@return string? error
function vendor.ensure()
  if path and fs.is_file(path) then
    return path
  end

  local build, err = asset()
  if not build then
    return nil, err
  end

  local file = DIR .. "/" .. build.local_name

  if verified(file, build) then
    path = file
    make_executable(file)
    return file
  end

  if fs.is_file(file) then
    logger:warn("Vendored legendary does not match the pin, refetching")
    fs.remove(file)
  end

  fs.create_directories(DIR)

  -- Downloaded under a temporary name and moved into place once verified, so an
  -- interrupted download is never mistaken for a usable binary.
  local partial = file .. ".part"
  if fs.is_file(partial) then
    fs.remove(partial)
  end

  logger:info("Downloading legendary " .. VERSION .. " for " .. platform.os_name())
  if not vendor.fetch(partial, url_for(build)) then
    return nil, "Could not download legendary from " .. url_for(build)
  end

  local hash = digest(partial)
  if hash ~= build.sha256 then
    logger:error(
      "Downloaded legendary hashed " .. tostring(hash) .. ", not the pinned " .. build.sha256
    )
    fs.remove(partial)
    return nil, "Downloaded legendary does not match its pinned hash, discarding it"
  end

  if not fs.rename(partial, file) then
    fs.remove(partial)
    return nil, "Could not put the legendary binary in place at " .. file
  end

  make_executable(file)

  logger:info("Installed legendary " .. VERSION .. " at " .. file)
  path = file
  return file
end

return vendor
