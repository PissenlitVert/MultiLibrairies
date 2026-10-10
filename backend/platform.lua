local fs = require("fs")
local utils = require("utils")

-- Which machine this is running on.
--
-- The plugin was written for Windows, and several pieces of it lean on it: a
-- PowerShell daemon so no console window flashes once a second, certutil for
-- hashing a downloaded binary, wscript to start a process with no window at
-- all. None of that exists on Linux, where a shell starts a process silently
-- and there is no window to hide in the first place - so every one of those
-- pieces has a second implementation, and this module is what tells them which
-- half of themselves to be.
--
-- Asked once at load and answered from a constant after that: every caller is
-- on a hot path (once a second per running job), and `package.config` is a
-- read of a string the Lua runtime was built with, but still not worth
-- repeating in each of them.

local platform = {}

--- True on Windows, where the daemon, certutil and wscript paths are the ones
--- to take. False on Linux, and on anything else Unix-ish, which gets the same
--- treatment as Linux.
platform.IS_WINDOWS = package.config:sub(1, 1) == "\\"

--- A human name for the log line and the panel, so a bug report says which
--- half of the plugin ran.
---@return string
function platform.os_name()
  if platform.IS_WINDOWS then
    return "Windows"
  end

  -- SteamOS, Arch, Fedora and the rest all have /proc. macOS does not, and
  -- is not supported anyway - this is here to keep the log honest rather than
  -- to detect anything.
  if fs.is_directory("/proc") then
    return "Linux"
  end

  return "POSIX"
end

---@return string "path" on Windows, "path" everywhere else
function platform.separator()
  return platform.IS_WINDOWS and "\\" or "/"
end

---The machine's CPU architecture, as `uname -m` spells it on Linux and as
---`PROCESSOR_ARCHITECTURE` spells it on Windows.
---
---Only ever needed to pick which legendary build to download, so it costs a
---subprocess once, the first time it is asked, and the answer is kept: a wrong
---or missing one here means a binary that cannot run at all, so it falls back
---to the architecture Steam itself is overwhelmingly run on.
---@type string|nil
local architecture = nil

---@return string x86_64, aarch64, ...
function platform.architecture()
  if architecture then
    return architecture
  end

  if platform.IS_WINDOWS then
    -- AMD64 on an x64 CPU, ARM64 on an ARM one. `PROCESSOR_ARCHITEW6432` is the
    -- 32-bit process on 64-bit Windows reading its 64-bit sibling's name, and
    -- is only set in that case.
    local value = utils.getenv("PROCESSOR_ARCHITECTURE")
    if value == "AMD64" and utils.getenv("PROCESSOR_ARCHITEW6432") then
      value = "ARM64"
    end
    architecture = value or "AMD64"
  else
    local output = utils.exec("uname -m 2>/dev/null")
    architecture = utils.trim(output or "")
    if architecture == "" then
      architecture = "x86_64"
    end
  end

  return architecture
end

---Turn a path written for one platform into one the local filesystem takes.
---
---Windows tools that accept a path (`certutil -hashfile`, cmd's own parser)
---want backslashes, and legendary is handed them the same way. On Linux the
---path is already right and rewriting it would break it: a backslash is a
---legal character in a Linux filename.
---@param path string
---@return string
function platform.to_native(path)
  if not platform.IS_WINDOWS then
    return path
  end
  return (path:gsub("/", "\\"))
end

---Quote one argument for a Steam launch-options string.
---
---Not the same question as quoting for a shell, and not the same answer. A
---shortcut's launch options are parsed by Steam itself, which splits on
---whitespace and honours double quotes - and nothing else, so a POSIX
---single-quoted path would reach the program wrapped in its own quotes, which on
---Linux is a path that does not exist. Only what needs quoting is quoted: the
---usual case is a path with a space in it, and most have none.
---@param value string
---@return string
function platform.quote_argument(value)
  if value:find('[ \t"\\]') then
    return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
  end
  return value
end

---Where this user's config files live, as XDG says and as Windows spells it.
---
---It belongs here rather than beside whoever needs it first because the answer
---has to be the *same* answer in every module: legendary reads its session from
---one directory and the plugin backs that directory up around a sign in, and
---two copies of this lookup are two chances to disagree about which directory
---that is.
---@return string
function platform.config_path()
  local override = utils.getenv("LEGENDARY_CONFIG_PATH")
  if override and override ~= "" then
    return override
  end

  local xdg = utils.getenv("XDG_CONFIG_HOME")
  if xdg and xdg ~= "" then
    return xdg
  end

  -- Windows has no XDG, and USERPROFILE is its equivalent; HOME is there for
  -- the Unix case where XDG_CONFIG_HOME is simply unset, which is a supported
  -- way of saying "use the default" rather than a broken environment.
  local home = utils.getenv("USERPROFILE")
  if not home or home == "" then
    home = utils.getenv("HOME") or ""
  end

  return home .. "/.config"
end

return platform
