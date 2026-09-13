-- service.luau
-- Headless service: runs monitor.sh (a dbus-monitor pipeline) and, for every
-- notification whose app_name/summary/body contains one of the configured
-- contact names, plays that contact's assigned OGG sound.
--
-- The sounds live in this runtime's sound bank (API 20). Contacts are loaded
-- one per update() tick so we stay under the 8-pending-loads cap, and the
-- "loaded" map is published to noctalia.state for the panel to render.

--!nonstrict

local SEP = string.char(0x1e)
local FS = string.char(0x1f)

local sounds = {}   -- [slug] = { loaded = bool, name = string, path = string }
local pending = {}  -- queue of { name, path, slug } drained one per tick
local loading = false

-- Suppression-filter re-sync bookkeeping. requestFilterSync is assigned below
-- (after the suppression helpers) and publishLoaded already needs it, so it is
-- declared up here; by the time queueContacts() runs at the end of this module
-- the assignment has happened.
local filterDirty = false
local requestFilterSync

local function tr(key)
  return noctalia.tr(key)
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Stable sound-bank name per contact: survives reloads and avoids collisions.
local function slug(name)
  local s = name:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if s == "" then
    s = "contact"
  end
  if #s > 40 then
    s = s:sub(1, 40)
  end
  return "contact_" .. s
end

local function publishLoaded()
  local ok, encoded = pcall(noctalia.json.encode, sounds)
  if ok and type(encoded) == "string" then
    noctalia.state.set("loaded", encoded)
  end
  requestFilterSync()
end

-- Re-reads the contacts map into the pending queue (sorted, deterministic).
local function queueContacts()
  pending = {}
  for name, path in pairs(noctalia.getConfig("contacts") or {}) do
    local n, p = tostring(name), tostring(path)
    if n ~= "" and noctalia.string.trim(p) ~= "" then
      table.insert(pending, { name = n, path = p, slug = slug(n) })
    end
  end
  table.sort(pending, function(a, b)
    return a.name < b.name
  end)
  publishLoaded()
end

-- Loads one contact's sound. Sound names are scoped to this runtime, and
-- requesting a name that already has a pending load is rejected, so the queue
-- is drained serially (one per update() tick).
local function pumpLoads()
  if loading then
    return
  end
  local job = table.remove(pending, 1)
  if not job then
    return
  end
  loading = true
  local accepted = noctalia.sound.load(job.slug, job.path, function(ok, err)
    sounds[job.slug] = { loaded = ok, name = job.name, path = job.path }
    if not ok then
      noctalia.log(string.format("contact-sounds: failed to load %s (%s): %s", job.slug, job.path, tostring(err)))
    else
      noctalia.log("contact-sounds: loaded " .. job.name .. " (" .. job.path .. ")")
    end
    publishLoaded()
    loading = false
  end)
  if not accepted then
    -- rejected (shouldn't happen when draining serially) - retry next tick
    loading = false
  end
end

-- Loads a sound on demand (used by the panel "play" flow, and to re-test after
-- a failed load). startBusy is a function()/nil guard set by callers.
local function playNamed(name, startBusy, finishBusy)
  local contacts = noctalia.getConfig("contacts") or {}
  local path = contacts[name]
  if not path then
    return
  end
  local s = slug(name)
  local entry = sounds[s]

  local function fire(ok)
    if finishBusy then
      finishBusy()
    end
    if ok then
      noctalia.sound.play(s)
    end
  end

  if entry and entry.loaded then
    fire(true)
    return
  end

  if startBusy then
    startBusy()
  end
  local accepted = noctalia.sound.load(s, path, function(ok, err)
    sounds[s] = { loaded = ok, name = name, path = path }
    publishLoaded()
    if not ok then
      noctalia.log(string.format("contact-sounds: failed to load %s (%s): %s", s, path, tostring(err)))
    end
    fire(ok)
  end)
  if not accepted then
    fire(false)
  end
end

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

local function lower(s)
  if not s then
    return ""
  end
  return s:lower()
end

local function matchContact(text)
  local contacts = noctalia.getConfig("contacts") or {}
  local sensitive = noctalia.getConfig("match_case_sensitive") == true
  local hay = sensitive and text or lower(text)

  for name, _ in pairs(contacts) do
    local n = tostring(name)
    local needle = sensitive and n or lower(n)
    if needle ~= "" and hay:find(needle, 1, true) then
      return n
    end
  end
end

local function appAllowed(appName)
  local apps = noctalia.getConfig("only_apps") or {}
  if #apps == 0 then
    return true
  end
  for _, app in ipairs(apps) do
    if tostring(app) == appName then
      return true
    end
  end
  return false
end

local function handleLine(line)
  if not line or line == "" then
    return
  end
  local fields = {}
  for part in line:gmatch("[^" .. SEP .. "]+") do
    fields[#fields + 1] = part
  end
  local appName = fields[1] or ""
  local title = fields[2] or ""
  local body = fields[3] or ""

  if not appAllowed(appName) then
    return
  end

  local contact = matchContact(title .. " " .. body .. " " .. appName)
  if not contact then
    return
  end

  local s = slug(contact)
  local entry = sounds[s]
  if entry and entry.loaded then
    noctalia.log("contact-sounds: playing " .. contact .. " (from " .. appName .. ")")
    noctalia.sound.play(s)
    noctalia.state.set("last_hit", contact)
    noctalia.state.set("last_hit_at", noctalia.nowMs() / 1000)
  end
end

-- ---------------------------------------------------------------------------
-- System sound suppression
-- ---------------------------------------------------------------------------

-- Escapes a literal contact name so it can be used inside a regex.
local function escapeRegex(s)
  return s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

-- Names currently present in the config whose sound is loaded. The filter must
-- not list names that were deleted (their sound entry may still be warm) or
-- whose load failed: the plugin would not play for them, and suppressing the
-- system sound would leave those notifications silent.
local function loadedContactNames()
  local contacts = noctalia.getConfig("contacts") or {}
  local out = {}
  for _, entry in pairs(sounds) do
    if entry.loaded and contacts[entry.name] ~= nil then
      out[#out + 1] = entry.name
    end
  end
  table.sort(out)
  return out
end

local function buildContentRegex(names)
  local parts = {}
  for _, n in ipairs(names) do
    parts[#parts + 1] = escapeRegex(n)
  end
  if #parts == 0 then
    return ""
  end
  return "(?:" .. table.concat(parts, "|") .. ")"
end

-- Keeps scripts/sync_filter.sh's `[notification.filter.contact-sounds-*]`
-- rules aligned with what this plugin will actually play, so the system sound
-- is suppressed only when a replacement sound is guaranteed:
--   * matching must be case-insensitive (the system filter cannot mirror
--     match_case_sensitive and would mute case-mismatched hits);
--   * at least one contact sound must be loaded (no startup-silence window);
--   * only loaded contacts are listed (failed loads are not suppressed);
--   * with `only_apps`, each allowed app gets its own rule so an app outside
--     the allow-list that merely mentions a contact is not muted, and with no
--     app list, per-name `match` rules cover a contact that appears only in
--     the app name (mirroring the plugin's own matching).
-- Whenever the filter is disabled (`sync_filter.sh off`) the normal system
-- sound stays on. The rule file is removed on disable/uninstall via onExit so
-- it cannot keep muting the system sound after the service stops.
local function syncSystemSoundFilter()
  local sensitive = noctalia.getConfig("match_case_sensitive") == true
  local apps = noctalia.getConfig("only_apps") or {}
  local names = loadedContactNames()

  local dir = noctalia.pluginDir()
  if not dir then
    return
  end
  local script = dir .. "/scripts/sync_filter.sh"

  local function run(verb)
    noctalia.runAsync("bash " .. shellQuote(script) .. " " .. verb, function(result)
      if result and result.exitCode ~= 0 then
        noctalia.log("contact-sounds: sync_filter.sh failed: " .. tostring(result.stderr))
      end
    end)
    noctalia.runAsync("noctalia msg config-reload")
  end

  if sensitive or #names == 0 then
    run("off")
    return
  end

  local verb = "on " .. shellQuote(buildContentRegex(names))
  if #apps > 0 then
    local listed = {}
    for _, app in ipairs(apps) do
      local a = tostring(app)
      if a ~= "" then
        listed[#listed + 1] = a
      end
    end
    if #listed > 0 then
      verb = verb .. " --apps " .. shellQuote(table.concat(listed, FS))
    end
  else
    verb = verb .. " --names " .. shellQuote(table.concat(names, FS))
  end
  run(verb)
end

-- The filter is re-synced from the load callbacks and config changes; the next
-- update() tick applies the new rule set at most once per second instead of
-- bursting a bash call per load completion.
requestFilterSync = function()
  filterDirty = true
end

-- ---------------------------------------------------------------------------
-- Monitor lifecycle
-- ---------------------------------------------------------------------------

local function startMonitor()
  local dir = noctalia.pluginDir()
  if not dir then
    return false
  end
  local script = dir .. "/scripts/monitor.sh"
  -- make sure it is executable (fresh installs may not preserve the bit)
  noctalia.runAsync("chmod +x " .. shellQuote(script))

  return noctalia.runStream(shellQuote(script), handleLine)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

queueContacts()
local monitorStarted = startMonitor()
if not monitorStarted then
  noctalia.log("contact-sounds: could not start dbus-monitor stream")
end

function update()
  noctalia.setUpdateInterval(1000)
  pumpLoads()
  if filterDirty then
    filterDirty = false
    syncSystemSoundFilter()
  end
end

function onConfigChanged()
  queueContacts() -- new/removed contacts reload; already-loaded slugs stay warm
  requestFilterSync()
end

function onIpc(_event, payload)
  if _event == "play" and payload then
    playNamed(payload)
  elseif _event == "reload" then
    queueContacts()
  end
end

-- Removes the helper filter file when the plugin is disabled or uninstalled:
-- with `enabled = true` and `play_sound = false` still on disk, the system
-- notification sound would stay muted even though the service is no longer
-- running to replace it.
function onExit(_signal, reason)
  if reason == "disable" or reason == "uninstall" then
    local base = noctalia.getenv("NOCTALIA_CONFIG_HOME")
    if not base or base == "" then
      base = noctalia.getenv("XDG_CONFIG_HOME")
      if not base or base == "" then
        base = noctalia.expandPath("~/.config")
      end
    end
    noctalia.removeFile(base .. "/noctalia/contact-sounds.toml")
  end
end