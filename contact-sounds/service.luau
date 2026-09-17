-- service.luau
-- Headless service: runs monitor.sh (a dbus-monitor pipeline) and, for every
-- notification whose app_name/summary/body contains one of the configured
-- contact names, plays that contact's assigned OGG sound.
--
-- Contacts can be a single sound file or a folder of sounds:
--   * file   -> the sound is loaded and played as-is.
--   * folder -> folder_sounds["<name>"] picks one file; when empty a random
--               member plays, so a folder means "any of these sounds".
-- Every contact also has a kind (contact|group|app): "app" entries match the
-- notification's app name only, the others match summary/body/app-name like
-- before. contact_images only matters to the panel.
--
-- The sounds live in this runtime's sound bank (API 20). Contacts are loaded
-- one per update() tick so we stay under the 8-pending-loads cap, and the
-- "loaded" map is published to noctalia.state for the panel to render.
--
-- Override behavior: the host suppresses play() while the "same" loaded buffer
-- is still active (it compares buffer identity), so a second hit for a contact
-- whose sound is still playing would otherwise be dropped. To keep every
-- simultaneous message audible, a hit that lands while this contact's sound may
-- still be running re-loads one of the contact's ring slots: the re-load mints
-- a fresh buffer, whose play() is never suppressed and starts from the start,
-- overriding the still-playing stream.

--!nonstrict

local SEP = string.char(0x1e)
local FS = string.char(0x1f)

local SOUND_EXTS = { ogg = true, mp3 = true, wav = true }

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

-- ---------------------------------------------------------------------------
-- Override playback state
-- ---------------------------------------------------------------------------
-- The host (API 20) suppresses noctalia.sound.play() only while the *same*
-- buffer object is still active (compare by buffer identity), so a rapid second
-- hit for a contact with a still-playing sound is otherwise swallowed. We work
-- around it with a small ring of sound-bank names per contact: every play
-- re-loads one of the ring slots, minting a fresh buffer whose play() starts a
-- new stream from the beginning and overrides the previous one. (A stream
-- orphaned by the external-stop workaround stays "active" in the host forever,
-- which is why the warm same-buffer path was removed: it could be suppressed.)
--
-- OVERRIDE_SLOTS     distinct buffers kept per contact; once they are all busy
--                    decoding, extra simultaneous hits queue for the next tick
--                    instead of being lost.
local OVERRIDE_SLOTS = 3

local function newEntry(name, path)
  local s = slug(name)
  local slots = {}
  for i = 0, OVERRIDE_SLOTS - 1 do
    local slotName = s
    if i > 0 then
      slotName = s .. "~" .. i
    end
    slots[i + 1] = { name = slotName, pending = false }
  end
  return {
    loaded = false,
    name = name,
    path = path,
    lastPlayAt = 0,
    slots = slots,
    slotIdx = 0,
  }
end

-- ---------------------------------------------------------------------------
-- Config + sound resolution
-- ---------------------------------------------------------------------------

local function cfgMap(key)
  local v = noctalia.getConfig(key) or {}
  local out = {}
  for k, val in pairs(v) do
    out[tostring(k)] = tostring(val)
  end
  return out
end

local function cfgList(key)
  local v = noctalia.getConfig(key) or {}
  if type(v) ~= "table" then
    return {}
  end
  local out = {}
  for _, s in ipairs(v) do
    out[#out + 1] = tostring(s)
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Authoritative contact data (owned by this runtime).
-- ---------------------------------------------------------------------------
-- Contacts are edited from the panel; everything that used to live in
-- [plugin_settings] and needed a config-reload (which closes every plugin
-- panel) now lives in the plugin's own data file and is synced to the panel
-- through noctalia.state, so the panel can mutate the list and reorder it
-- while staying open, exactly like inventory-manager.
local contacts = {}        -- map name -> sound path (file or folder)
local contactKinds = {}    -- map name -> "contact" | "group" | "app"
local contactImages = {}   -- map name -> image path
local folderSounds = {}    -- map name -> picked folder member ("" = random)
local contactOrder = {}    -- ordered array of names (display order)
local soundFolders = {}    -- registry of folders added through the panel
local dataPath = nil

local function seedFromConfig()
  contacts = cfgMap("contacts")
  contactKinds = cfgMap("contact_kinds")
  contactImages = cfgMap("contact_images")
  folderSounds = cfgMap("folder_sounds")
  contactOrder = cfgList("contact_order")
  soundFolders = cfgList("sound_folders")
end

local function saveData()
  if not dataPath then
    return false
  end
  local ok, encoded = pcall(noctalia.json.encode, {
    contacts = contacts,
    kinds = contactKinds,
    images = contactImages,
    folder_sounds = folderSounds,
    order = contactOrder,
    sound_folders = soundFolders,
  })
  if ok and type(encoded) == "string" then
    return pcall(noctalia.writeFile, dataPath, encoded) and true or false
  end
  return false
end

local function loadData()
  local dir = noctalia.pluginDataDir()
  if not dir then
    return
  end
  dataPath = dir .. "/state.json"
  local raw = noctalia.readFile(dataPath)
  if raw then
    local ok, decoded = pcall(noctalia.json.decode, raw)
    if ok and type(decoded) == "table" then
      if type(decoded.contacts) == "table" then contacts = decoded.contacts end
      if type(decoded.kinds) == "table" then contactKinds = decoded.kinds end
      if type(decoded.images) == "table" then contactImages = decoded.images end
      if type(decoded.folder_sounds) == "table" then folderSounds = decoded.folder_sounds end
      if type(decoded.order) == "table" then contactOrder = decoded.order end
      if type(decoded.sound_folders) == "table" then soundFolders = decoded.sound_folders end
      return
    end
  end
  -- First run (or incompatible file): seed from the app-managed settings and
  -- move the data under our own control from here on.
  seedFromConfig()
  saveData()
end

local function publishData()
  noctalia.state.set("contacts.data", {
    contacts = contacts,
    kinds = contactKinds,
    images = contactImages,
    folder_sounds = folderSounds,
    order = contactOrder,
    sound_folders = soundFolders,
  })
end

local function expandPath(p)
  if p:sub(1, 1) == "~" then
    return noctalia.expandPath(p)
  end
  return p
end

local function fileExt(p)
  local ext = p:match("%.([^./]+)$")
  return ext and ext:lower() or ""
end

local function listSounds(dir)
  local out = {}
  local names = noctalia.listDir(dir)
  if names then
    for _, n in ipairs(names) do
      if SOUND_EXTS[fileExt(n)] then
        out[#out + 1] = n
      end
    end
  end
  table.sort(out)
  return out
end

-- The sound file that should play for `name` right now. A folder entry
-- resolves to the chosen sound (folder_sounds), or a random member so a
-- folder means "any of these sounds".
local function resolveSoundFile(name)
  local raw = contacts[name]
  if not raw then
    return nil
  end
  local p = expandPath(tostring(raw))
  local info = noctalia.fileInfo(p)
  if info and info.isDir then
    local files = listSounds(p)
    if #files == 0 then
      return nil
    end
    local chosen = folderSounds[name]
    if chosen and chosen ~= "" then
      for _, f in ipairs(files) do
        if f == chosen then
          return p .. "/" .. f
        end
      end
    end
    return p .. "/" .. files[math.random(#files)]
  end
  return p
end

-- ---------------------------------------------------------------------------
-- Publishing loaded state
-- ---------------------------------------------------------------------------

-- Publishes every contact so the panel always has a row: warm/loaded entries
-- come from `sounds`, everything else is a not-loaded placeholder (the panel
-- turns that into its spinner/error glyph instead of dropping the row).
local function publishLoaded()
  local merged = {}
  for s, entry in pairs(sounds) do
    if contacts[entry.name] ~= nil then
      -- Publish only the fields the panel consumes; ring-slot bookkeeping stays
      -- private to this runtime.
      merged[s] = { loaded = entry.loaded, name = entry.name, path = entry.path }
    end
  end
  for name, rawPath in pairs(contacts) do
    local n = tostring(name)
    if n ~= "" then
      local s = slug(n)
      if not merged[s] then
        merged[s] = { loaded = false, name = n, path = tostring(rawPath) }
      end
    end
  end
  local ok, encoded = pcall(noctalia.json.encode, merged)
  if ok and type(encoded) == "string" then
    noctalia.state.set("loaded", encoded)
  end
  requestFilterSync()
end

-- Fires an audible playback for this hit, overriding a still-playing identical
-- sound instead of being suppressed by the host. Every play goes through the
-- ring: there is no warm fast path because the host suppresses play() while
-- the *same* buffer's stream is still tracked as active, and a stream orphaned
-- by an external stop stays "active" for good, so a warm play could silently
-- do nothing. Re-loading a ring slot always mints a fresh buffer, whose play()
-- is never suppressed and starts from the beginning. Returns true when a load
-- was accepted (its callback plays); false when every ring slot is still
-- decoding and the caller should queue a retry.
local function firePlay(s, resolved, entry)
  local slots = entry.slots
  local idx = entry.slotIdx or 0
  for _ = 1, #slots do
    idx = idx % #slots + 1
    local slot = slots[idx]
    if not slot.pending then
      slot.pending = true
      entry.slotIdx = idx
      local accepted = noctalia.sound.load(slot.name, resolved, function(ok, err)
        slot.pending = false
        entry.lastPlayAt = noctalia.nowMs()
        if ok then
          if slot.name == s then
            entry.loaded = true
            entry.path = resolved
            publishLoaded()
          end
          noctalia.sound.play(slot.name)
        else
          noctalia.log(string.format(
            "contact-sounds: override load of %s failed: %s", resolved, tostring(err)
          ))
        end
      end)
      if accepted then
        return true
      end
      slot.pending = false
    end
  end
  return false
end

-- Re-reads the contacts map into the pending queue (sorted, deterministic)
-- and drops warm entries that stopped resolving (deleted or empty folder).
local function queueContacts()
  pending = {}
  local resolvable = {}
  for name, rawPath in pairs(contacts) do
    local n = tostring(name)
    if n ~= "" and noctalia.string.trim(tostring(rawPath)) ~= "" then
      local s = slug(n)
      local resolved = resolveSoundFile(n)
      if resolved then
        resolvable[s] = true
        local entry = sounds[s]
        if not entry then
          entry = newEntry(n, resolved)
          sounds[s] = entry
        end
        if not (entry.loaded and entry.path == resolved) then
          table.insert(pending, { name = n, path = resolved, slug = s })
        end
      end
    end
  end
  for s in pairs(sounds) do
    if not resolvable[s] then
      sounds[s] = nil
    end
  end
  table.sort(pending, function(a, b)
    return a.name < b.name
  end)
  publishLoaded()
end

-- Loads one contact's sound. Sound names are scoped to this runtime, and
-- requesting a name that already has a pending load is rejected, so the queue
-- is drained serially (one per update() tick). Retry jobs are plays that could
-- not start because every ring slot was mid-decode; they are re-fired once a
-- slot frees up so no simultaneous hit is silently dropped.
local function pumpLoads()
  if loading then
    return
  end
  local job = table.remove(pending, 1)
  if not job then
    return
  end
  if job.retry then
    local entry = sounds[job.slug]
    if not entry then
      entry = newEntry(job.name, job.path)
      sounds[job.slug] = entry
    end
    if not firePlay(job.slug, job.path, entry) then
      -- every ring slot is still decoding; try again on a later tick
      table.insert(pending, 1, job)
    end
    return
  end

  loading = true
  local entry = sounds[job.slug] or newEntry(job.name, job.path)
  local accepted = noctalia.sound.load(job.slug, job.path, function(ok, err)
    local merged = entry
    merged.loaded = ok
    merged.name = job.name
    merged.path = job.path
    sounds[job.slug] = merged
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

-- Plays a contact's sound on demand (panel test / IPC). Re-resolves the file
-- so a folder contact always plays its currently-selected (or fresh random)
-- member, and reuses the override ring so a repeated test never gets dropped
-- while one copy is still playing.
local function playNamed(name)
  local resolved = resolveSoundFile(name)
  if not resolved then
    return
  end
  local s = slug(name)
  local entry = sounds[s]
  if not entry then
    entry = newEntry(name, resolved)
    sounds[s] = entry
  end
  if not firePlay(s, resolved, entry) then
    table.insert(pending, { retry = true, name = name, path = resolved, slug = s })
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

-- "app" contacts match the notification's app name only (they exist for
-- "this app made a sound"), while contacts/groups match summary + body + app
-- name like before.
local function matchContact(appName, title, body)
  local sensitive = noctalia.getConfig("match_case_sensitive") == true

  for name, _ in pairs(contacts) do
    local n = tostring(name)
    local needle = sensitive and n or lower(n)
    if needle ~= "" then
      local kind = contactKinds[n] or "contact"
      local hay
      if kind == "app" then
        hay = appName
      else
        hay = title .. " " .. body .. " " .. appName
      end
      local search = sensitive and hay or lower(hay)
      if search:find(needle, 1, true) then
        return n
      end
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

  local contact = matchContact(appName, title, body)
  if not contact then
    return
  end

  local resolved = resolveSoundFile(contact)
  if not resolved then
    return
  end
  local s = slug(contact)
  local entry = sounds[s]
  if not entry then
    entry = newEntry(contact, resolved)
    sounds[s] = entry
  end

  if firePlay(s, resolved, entry) then
    noctalia.log("contact-sounds: playing " .. contact .. " (from " .. appName .. ")")
    noctalia.state.set("last_hit", contact)
    noctalia.state.set("last_hit_at", noctalia.nowMs() / 1000)
  else
    -- Every ring slot is still decoding (rapid simultaneous hits): play it once
    -- a slot frees up, so no incoming message is silently swallowed.
    noctalia.log("contact-sounds: hit for " .. contact .. " while overriding; queued for next tick")
    table.insert(pending, { retry = true, name = contact, path = resolved, slug = s })
  end
end

-- ---------------------------------------------------------------------------
-- System sound suppression
-- ---------------------------------------------------------------------------

local function escapeRegex(s)
  return s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

local function loadedContactNames()
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

requestFilterSync = function()
  filterDirty = true
end

-- ---------------------------------------------------------------------------
-- Panel -> service command bus
-- ---------------------------------------------------------------------------
-- The panel sends the full authoritative data tables after every mutation and
-- this runtime applies them, persists them to state.json and re-syncs the
-- sound matching / system-sound filter — all without a config-reload, so the
-- panel never closes.
local function applyData(d)
  if type(d) ~= "table" then
    return false
  end
  if type(d.contacts) == "table" then contacts = d.contacts end
  if type(d.kinds) == "table" then contactKinds = d.kinds end
  if type(d.images) == "table" then contactImages = d.images end
  if type(d.folder_sounds) == "table" then folderSounds = d.folder_sounds end
  if type(d.order) == "table" then contactOrder = d.order end
  if type(d.sound_folders) == "table" then soundFolders = d.sound_folders end
  return true
end

noctalia.state.watch("contacts.cmd", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  if cmd.op == "mutate" then
    if applyData(cmd.data) then
      if not saveData() then
        noctalia.log("contact-sounds: failed to persist state.json")
      end
      noctalia.notify(tr("panel.title"), tr("panel.saved"))
      queueContacts()
      publishData()
    end
  elseif cmd.op == "reload" then
    loadData()
    queueContacts()
    publishData()
  end
  noctalia.state.set("contacts.cmd", nil)
end)

-- ---------------------------------------------------------------------------
-- Monitor lifecycle
-- ---------------------------------------------------------------------------

local function startMonitor()
  local dir = noctalia.pluginDir()
  if not dir then
    return false
  end
  local script = dir .. "/scripts/monitor.sh"
  noctalia.runAsync("chmod +x " .. shellQuote(script))

  return noctalia.runStream(shellQuote(script), handleLine)
end

-- Stops any currently-playing sound. There is no runtime API to stop playback,
-- so the panel's stop button asks us to destroy the active "noctalia-sound"
-- PipeWire nodes (see scripts/stop_sounds.py).
--
-- The host still tracks the destroyed stream's buffer as "active" afterwards
-- and silently swallows a later play() of that same buffer (no new PipeWire
-- node is created), which left the panel's test muted after a stop. Fix: once
-- the nodes are gone, invalidate every contact so the next play re-loads and
-- mints a fresh buffer that is never suppressed.
local function stopSounds()
  local dir = noctalia.pluginDir()
  if not dir then
    return
  end
  local script = dir .. "/scripts/stop_sounds.py"
  noctalia.runAsync("python3 " .. shellQuote(script), function(result)
    if result and result.exitCode ~= 0 then
      noctalia.log("contact-sounds: stop_sounds.py failed: " .. tostring(result.stderr))
    end
    for _, entry in pairs(sounds) do
      entry.loaded = false
      entry.lastPlayAt = 0
    end
    publishLoaded()
  end)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

loadData()
queueContacts()
publishData()
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
  loadData()
  queueContacts()
  publishData()
  requestFilterSync()
end

function onIpc(_event, payload)
  if _event == "play" and payload then
    playNamed(payload)
  elseif _event == "stop" then
    stopSounds()
  elseif _event == "reload" then
    queueContacts()
  end
end

-- Removes the helper filter file when the plugin is disabled or uninstalled.
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