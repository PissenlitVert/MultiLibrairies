local utils = require("utils")

-- A reader for one part of Steam's text `config.vdf`: the `CompatToolMapping`
-- table, which says "run this appid through that tool".
--
-- It is here because it is the single thing that stops an Epic game from
-- starting with no error anywhere. A non-Steam shortcut mapped to Proton is
-- launched *inside* that Proton; the plugin's shortcut is a Linux shell script,
-- a shell script cannot execute under Wine, and Steam's log records only that a
-- process appeared and went away. Nothing the plugin does can report it, because
-- by the time anything of ours runs, the failure has already happened.
--
-- Written by Steam when its own Properties dialog is used, and read back through
-- no API the plugin has. So the only way to tell a user why their game does
-- nothing is to read what Steam wrote down.
--
-- Text, not binary: the file is indented with tabs and Valve's writer is
-- consistent about it, so a block runs from its key to the next line at the same
-- indentation. That is a deliberate choice over a real parser - a real one would
-- be more code to maintain, and this has to be right about one table in one
-- file, not about VDF.

local config_vdf = {}

---The name of the table, as it appears quoted.
local MAPPING_KEY = '"CompatToolMapping"'---Escape a Lua pattern so a literal string can be searched for.
---@param value string
---@return string
local function plain(value)
  return (value:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

---The text of the `CompatToolMapping` block, or nil when there isn't one.
---
---Bounded by indentation rather than by brace counting: braces nest for a reason,
---and the entries are one level deep, so the next line at the block's own
---indentation is the end of it and everything before is inside.
---@param content string
---@return string|nil block
local function mapping_block(content)
  local at = content:find(MAPPING_KEY, 1, true)
  if not at then
    return nil
  end

  -- The indentation of the line the key is on, which is the block's depth. Lua's
  -- `.` matches a newline as readily as anything else, so the indent is taken
  -- from after the *last* newline rather than with a pattern that would run to
  -- the end of the file.
  local before = content:sub(1, at - 1)
  local line_break = before:find("\n[^\n]*$")
  local indent = line_break and before:sub(line_break + 1) or ""

  local after = content:sub(at)
  local first_newline = after:find("\n")

  if not first_newline then
    return nil
  end

  local body = after:sub(first_newline + 1)
  local stop = indent ~= "" and body:find("\n" .. plain(indent) .. '"', 1) or nil

  if stop then
    return body:sub(1, stop - 1)
  end

  return body
end

---Every appid Steam has mapped to a compatibility tool, and to which.
---
---Keys are the appid as decimal text - the same text the frontend holds - so the
---caller can look its own appids up without converting anything.
---
---Line by line rather than with one big pattern, because Valve writes this file
---one key per line and that is the shape it can be read in without guessing: an
---appid on a line of its own, then a `name` on a line of its own. A single
---pattern over brace-balanced text would be shorter and would break on the first
---`}` inside a quoted value.
---@param content string
---@return table<string, string> mapping appid -> tool name
function config_vdf.compat_tool_mapping(content)
  local mapping = {}
  local block = mapping_block(content)

  if not block then
    return mapping
  end

  ---@type string|nil
  local pending = nil

  for line in (block .. "\n"):gmatch("(.-)\n") do
    local app_id = line:match('^%s*"(%d+)"%s*$')

    if app_id then
      pending = app_id
    else
      local name = line:match('^%s*"name"%s*"([^"]*)"%s*$')

      if name and pending then
        -- First match wins: Steam rewrites rather than appends, and a second
        -- entry for the same appid would be a leftover, not a newer answer.
        if mapping[pending] == nil then
          mapping[pending] = name
        end
        pending = nil
      elseif line:match("^%s*}%s*$") then
        -- The end of this appid's entry, with no name in it: one Steam wrote
        -- but had nothing to record.
        pending = nil
      end
    end
  end

  return mapping
end

---Steam's own path to `config.vdf`, where every mapping lives.
---@return string
local function config_path()
  return require("millennium").steam_path() .. "/config/config.vdf"
end

---The compatibility tool Steam applies to *everything*, or nil when there is none.
---
---Appid `0` in the mapping is not an app: it is Steam's own default, the one set
---in Settings and applied to every game with no mapping of its own. It is worth
---naming separately because it is the one entry that breaks this plugin on every
---game at once, rather than one, and because it is the only one a user sets
---without opening a game's Properties.
---
---Read out of the same table rather than by a second pattern, so the two answers
---cannot disagree about what Steam has on disk.
---@param content string
---@return string|nil
function config_vdf.global_compat_tool(content)
  local tool = config_vdf.compat_tool_mapping(content)["0"]

  -- An empty name is Steam recording "no tool" rather than a tool called "".
  if not tool or tool == "" then
    return nil
  end

  return tool
end

---Rewrite the global mapping so Steam's own default is "no tool".
---
---An empty `name` is how Steam itself records "the user chose No tool": the
---entry stays, with `name` empty and `priority` kept. Rewritten by hand rather
---than through an API because there is no API for it - `SpecifyCompatTool(0, "")`
---targets an app, not Steam's default, and no other call reaches this table.
---
---Surgical on purpose: only the appid `0` entry's name line is touched, so
---Steam's own per-game mappings, the file's ordering and everything else in it
---survive byte for byte. Steam re-reads the file when it builds its own
---Settings page, so the panel and Steam agree without a restart.
---
---The cache is dropped rather than updated, so the next read answers from the
---file: what Steam wrote is the truth, not what we assumed we wrote.
---@return boolean changed Whether the file was written at all
---@return string|nil error
function config_vdf.clear_global_compat_tool()
  local path = config_path()
  local content = utils.read_file(path)

  if not content then
    return false, "could not read " .. path
  end

  local block = mapping_block(content)
  local at = block and content:find(block, 1, true) or nil

  if not at then
    -- No mapping at all: there is nothing to clear, and that is success.
    return false
  end

  -- The entry: appid `0` opening a block, then the name line Steam wrote in it.
  local entry = block:match('\n%s*"0"%s*\n%s*{%s*\n%s*"name"%s*"([^"]-)"')

  if not entry or entry == "" then
    -- Either there is no global entry or it already says No tool. Both are
    -- "nothing to do", and neither is worth a write.
    return false
  end

  -- The name line inside appid `0`'s own block, blanked in place. Anchored on
  -- the lines Steam actually writes - appid, opening brace, then name - rather
  -- than on `%b{}`, which is greedy across entries and would catch a later
  -- block's name when the global one has no name of its own.
  local updated = content:gsub(
    '("0"\n[\t ]*{\n[\t ]*)"name"\t\t"[^"]-"',
    '%1"name"\t\t""',
    1
  )

  if updated == content then
    return false, "the global entry did not match the shape Steam writes"
  end

  if not utils.write_file(path, updated) then
    return false, "could not write " .. path
  end

  return true
end

return config_vdf