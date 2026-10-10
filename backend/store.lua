local cache = require("cache")
local logger = require("logger")
local shell = require("shell")
local utils = require("utils")

-- Which of a game's own pages on Epic's store to send someone to.
--
-- The honest answer is that Epic will not say: a product page is addressed by a
-- slug, and no manifest the plugin can read carries one. `legendary list` files
-- its entries under sixteen paths, and neither `customAttributes` nor
-- `metadata` holds an offer id, a catalogue namespace or a slug - it has been
-- checked against the cache a real library is read from, and the only Epic
-- fields there are a title, an install path and a version.
--
-- So this guesses the slug from the title - which Epic derives from the title
-- for the large majority of its catalogue - and then **asks the store whether
-- that guess is a page**, with one HTTP request, for a game whose page someone
-- actually opens. Two things follow that guessing alone would not give:
--
--   - the address is right rather than plausible, because a 404 is a 404 and not
--     a page with an error on it;
--   - it cannot be worse than what it replaces, because every path out of here
--     ends at a URL that works. A guess that fails lands on Epic's own search for
--     the title, which is where this was already going.
--
-- One request per game, remembered: `data/cache/store.json`. Never more than one
-- in flight for a game, and a request that could not be made at all - no
---- downloader, no network, a rate limit - is not remembered, so the next click
---- tries again rather than being told for ever that the page does not exist.

local store = {}

---Where the answers are kept between runs.
local CACHE_PATH = utils.get_backend_path() .. "/data/cache/store.json"

---Epic's store, and the one page of it that can be built from a title alone.
local STORE = "https://store.epicgames.com"
local SEARCH = STORE .. "/browse"

---The downloader that answered last time, tried first next time.
---
---curl then wget, and the choice remembered, exactly as `vendor` does it: curl is
---what Steam's own runtime ships, so the machine running Steam is the machine
---that has it, and wget is the fallback for a distribution with neither.
local downloader = "curl"

---@class StorePage
---@field kind "product"|"search" Whether Epic's slug for this title is right
---@field url string Where to send someone
---@field language string The store locale it was settled in

---@type table<string, StorePage>|nil
local known = nil

local function load()
  known = cache.read(CACHE_PATH, "store") or {}
  return known
end

local function save()
  cache.write(CACHE_PATH, known, "store")
end

---The store's own path segment for a title, as Epic derives it.
---
---Lowercased, with everything that is not a letter or a digit turned into one
---hyphen and no hyphen left at either end. Guessing is the whole of this
---function and its output is not trusted until `status` has said so - see the
---notes at the top of the file.
---@param title any
---@return string
function store.slug(title)
  local slug = tostring(title or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")

  return slug ~= "" and slug or "unknown"
end

---The store's locale, which is the language's primary subtag and nothing else.
---
---`fr-FR`, `fr` and `fr-CA` are all `fr` to the store; a full tag is not a path
---it has.
---@param language any
---@return string
function store.language(language)
  local tag = tostring(language or ""):lower():match("^([a-z]+)") or "en"

  return tag ~= "" and tag or "en"
end

---@param value string
---@return string
local function url_encode(value)
  return (tostring(value):gsub("[^%w%-%._~]", function(character)
    return string.format("%%%02X", string.byte(character))
  end))
end

---Epic's own search for one game: the answer that is always available.
---@param title string
---@return string
function store.search_url(title)
  return SEARCH .. "?q=" .. url_encode(title)
end

---The product page a title would have, before anybody has checked it.
---@param title string
---@param language any
---@return string
function store.product_url(title, language)
  return STORE .. "/" .. store.language(language) .. "/p/" .. store.slug(title)
end

---The HTTP status of one address, or nil when nobody could be asked.
---
---curl's `-w` because the answer decides two different things: a 404 means the
---slug is wrong and that is worth remembering, while a rate limit or a network
---that is not there means nothing at all and must not be.
---
---`--max-time` because this runs while somebody is waiting for a link: a store
---that never answers has to become the search rather than a page that hangs.
---@param url string
---@return integer|nil status
local function status(url)
  if downloader == "wget" then
    -- wget has no way to print a status code, only to fail: `--spider` asks
    -- without downloading, and a non-zero exit is a 404 as far as this is
    -- concerned. It cannot tell a 404 from a rate limit, so that case remembers
    -- the search - which is the answer a wrong guess gets anyway.
    local _, code = shell.run("wget", { "-q", "--spider", "--tries=1", "--timeout=8", url }, { timeout = 12 })
    if code == 0 then
      return 200
    end

    return 404
  end

  local output = shell.run(
    "curl",
    { "-s", "-o", "/dev/null", "-w", "%{http_code}", "-L", "--max-time", "8", url },
    { timeout = 12 }
  )

  return tonumber(utils.trim(output or "")) or nil
end

---Where one game's store page is, settled once and remembered.
---
---Answered from the cache when it is there, asked of the store when it is not,
---and answered with the search either way - so this function cannot hand back
---nothing, and the caller has no fallback of its own to write.
---@param app_name string Epic's own id, which is what the answer is keyed on
---@param title string The game's name, which is all Epic's page can be guessed from
---@param language any The store locale, normally the client's own language
---@return StorePage page
function store.page(app_name, title, language)
  known = known or load()

  local remembered = known[app_name]
  if remembered and remembered.language == store.language(language) then
    return remembered
  end

  local search = { kind = "search", url = store.search_url(title), language = store.language(language) }
  local product = store.product_url(title, language)

  local code = status(product)

  if code == 200 then
    local page = { kind = "product", url = product, language = search.language }
    known[app_name] = page
    save()

    logger:info("Epic's page for " .. tostring(title) .. " is " .. product)

    return page
  end

  if code == 404 then
    -- Settled: the store was asked and the guess was wrong. Remembered, so the
    -- next click is instant rather than another request.
    known[app_name] = search
    save()

    logger:info("Epic has no page at the guessed address for " .. tostring(title) .. ", searching instead")

    return search
  end

  -- 429, 503, a downloader that would not start, a store that did not answer:
  -- nothing was learned, so nothing is remembered and the search is used for now.
  logger:warn("Could not ask Epic's store about " .. tostring(title) .. ": " .. tostring(code))

  return search
end

return store