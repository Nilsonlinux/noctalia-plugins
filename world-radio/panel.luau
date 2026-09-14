-- panel.luau
-- World Radio: dashboard of countries with flags and station counts, a per-country
-- station list, and local playback through mpv (falls back to ffplay).

local COUNTRIES_CACHE_AGE = 4 * 3600
local STATIONS_PAGE = 100
local API_BASE = "https://de1.api.radio-browser.info"
local USER_AGENT = "nilsonlinux/world-radio/1.0.0"

local dataDir
local function getDataDir()
  if dataDir == nil then
    local ok, dir = pcall(noctalia.pluginDataDir)
    dataDir = (ok and type(dir) == "string" and dir ~= "") and dir or nil
  end
  if dataDir == nil then
    local ok, dir = pcall(noctalia.pluginDir)
    dataDir = (ok and dir) or "."
  end
  return dataDir
end

local view = "dashboard"
local countries = nil
local stats = nil
local query = ""
local queryKey = 0
local stationQuery = ""
local stationQueryKey = 0

local selectedCode = nil
local selectedName = ""
local stations = nil
local stationsOffset = 0
local stationsDone = false
local stationsErr = false

local loading = false
local errorMessage = ""

local playingUuid = nil
local playingName = ""
local playingUrl = ""
local favorites = {}
local thumbs = {}
local thumbPending = {}
local customStations = {}
local customFormName = ""
local customFormUrl = ""

local render
local renderDashboard
local renderCountry
local renderFavorites
local renderCustom
local renderAddCustom

local function tr(key, subst)
  if subst == nil then
    return noctalia.tr(key)
  end
  return noctalia.tr(key, subst)
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local playerName = noctalia.commandExists("mpv") and "mpv" or "ffplay"
local playerArgs = playerName == "mpv" and "--no-video --no-terminal --volume=85" or "-nodisp -loglevel quiet -autoexit -volume 85"

local FLAG_EMOJIS = {}
do
  local letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  for i = 1, #letters do
    local letter = letters:sub(i, i)
    local cp = 127397 + letter:byte()
    local b0 = 0xF0 + math.floor(cp / 0x40000)
    local b1 = 0x80 + math.floor(math.floor(cp / 0x1000) % 0x40)
    local b2 = 0x80 + math.floor(math.floor(cp / 0x40) % 0x40)
    local b3 = 0x80 + (cp % 0x40)
    FLAG_EMOJIS[letter] = string.char(b0, b1, b2, b3)
  end
end

local function flagEmoji(code)
  code = code or ""
  local e1, e2 = FLAG_EMOJIS[code:sub(1, 1)], FLAG_EMOJIS[code:sub(2, 2)]
  if e1 == nil or e2 == nil then
    return ""
  end
  return e1 .. e2
end

local function readCachedJson(name, maxAge)
  local path = getDataDir() .. "/" .. name
  local info = noctalia.fileInfo(path)
  if info == nil or info.mtime == nil then
    return nil
  end
  if os.time() - info.mtime > maxAge then
    return nil
  end
  local raw = noctalia.readFile(path)
  if raw == nil then
    return nil
  end
  local ok, val = pcall(noctalia.json.decode, raw)
  if ok then
    return val
  end
  return nil
end

local function writeCachedJson(name, value)
  local ok, encoded = pcall(noctalia.json.encode, value)
  if ok and encoded ~= nil then
    noctalia.writeFile(getDataDir() .. "/" .. name, encoded)
  end
end

local function httpJson(url, cb)
  noctalia.http({
    url = url,
    headers = { "Accept: application/json", "User-Agent: " .. USER_AGENT },
  }, function(res)
    if res == nil or res.ok ~= true then
      cb(nil)
      return
    end
    local ok, decoded = pcall(noctalia.json.decode, res.body)
    if ok then
      cb(decoded)
    else
      cb(nil)
    end
  end)
end

local function fetchStats()
  httpJson(API_BASE .. "/json/stats", function(data)
    if data ~= nil then
      stats = {
        stations = tonumber(data.stations) or 0,
        countries = tonumber(data.countries) or 0,
      }
      writeCachedJson("stats.json", stats)
    end
    render()
  end)
end

local function fetchCountries()
  loading = true
  errorMessage = ""
  render()
  httpJson(API_BASE .. "/json/countries", function(data)
    if data == nil then
      if countries == nil then
        errorMessage = tr("panel.error_network")
      end
      loading = false
      render()
      return
    end
    local list = {}
    for _, c in ipairs(data) do
      local name = tostring(c.name or c.country or "")
      local iso = tostring(c.iso_3166_1 or c.countrycode or "")
      if name ~= "" and iso ~= "" then
        table.insert(list, {
          name = name,
          iso = iso,
          count = tonumber(c.stationcount) or 0,
        })
      end
    end
    table.sort(list, function(a, b) return a.count > b.count end)
    countries = list
    loading = false
    writeCachedJson("countries.json", list)
    render()
    fetchStats()
  end)
end

local function fetchStations(offset)
  loading = true
  errorMessage = ""
  render()
  local url = string.format(
    "%s/json/stations/search?countrycode=%s&order=votes&reverse=true&hidebroken=true&limit=%d&offset=%d",
    API_BASE, noctalia.string.urlEncode(selectedCode), STATIONS_PAGE, offset
  )
  httpJson(url, function(data)
    loading = false
    if data == nil then
      if stations == nil then
        stationsErr = true
      end
      render()
      return
    end
    stations = stations or {}
    for _, s in ipairs(data) do
      local playUrl = (s.url_resolved ~= nil and s.url_resolved ~= "") and s.url_resolved or (s.url or "")
      local name = tostring(s.name or "")
      if name ~= "" and playUrl ~= "" then
        table.insert(stations, {
          uuid = tostring(s.stationuuid or ("s" .. tostring(#stations + 1))),
          name = name,
          url = playUrl,
          favicon = tostring(s.favicon or ""),
          codec = tostring(s.codec or ""),
          bitrate = tonumber(s.bitrate) or 0,
          votes = tonumber(s.votes) or 0,
        })
      end
    end
    stationsOffset = offset + #data
    stationsDone = #data < STATIONS_PAGE
    render()
  end)
end

local function selectCountry(code, name)
  view = "country"
  selectedCode = code
  selectedName = name
  stations = nil
  stationsOffset = 0
  stationsDone = false
  stationsErr = false
  stationQuery = ""
  stationQueryKey = stationQueryKey + 1
  loading = false
  errorMessage = ""
  render()
  fetchStations(0)
end

local function publishPlaying()
  noctalia.state.set("playing", {
    name = playingName,
    uuid = playingUuid or "",
    url = playingUrl,
  })
end

local function stopPlayback()
  playingUuid = nil
  playingName = ""
  playingUrl = ""
  publishPlaying()
  noctalia.runAsync("kill $(cat " .. shellQuote(getDataDir() .. "/player.pid") .. " 2>/dev/null) 2>/dev/null")
  render()
end

local faviconJobs = {}

local function faviconDest(station)
  if station.favicon == "" then
    return nil
  end
  local ext = station.favicon:match("%.png$") and ".png" or ".jpg"
  return getDataDir() .. "/thumbs/" .. station.uuid .. ext
end

local function ensureFavicon(station, onDone)
  local dest = faviconDest(station)
  if dest == nil then
    onDone(nil)
    return
  end
  if noctalia.fileInfo(dest) ~= nil then
    thumbs[station.uuid] = thumbs[station.uuid] or dest
    onDone(dest)
    return
  end
  local list = faviconJobs[station.uuid]
  if list ~= nil then
    table.insert(list, onDone)
    return
  end
  list = { onDone }
  faviconJobs[station.uuid] = list
  thumbPending[station.uuid] = true
  noctalia.mkdirAll(getDataDir() .. "/thumbs")
  noctalia.download(station.favicon, dest, function(ok)
    thumbPending[station.uuid] = nil
    faviconJobs[station.uuid] = nil
    if ok then
      thumbs[station.uuid] = dest
    end
    render()
    for _, cb in ipairs(list) do
      cb(ok and dest or nil)
    end
  end)
end

local function loadFavicon(station)
  ensureFavicon(station, function() end)
end

local function playStation(station)
  local pidFile = getDataDir() .. "/player.pid"
  playingUuid = station.uuid
  playingName = station.name
  playingUrl = station.url
  publishPlaying()
  render()
  local cover = nil
  if playerName == "mpv" then
    local dest = faviconDest(station)
    if dest ~= nil and noctalia.fileInfo(dest) ~= nil then
      cover = dest
    end
  end
  local coverArg = ""
  if cover ~= nil then
    coverArg = " --cover-art-files=" .. shellQuote(cover)
  end
  local cmd = string.format(
    "kill $(cat %s 2>/dev/null) 2>/dev/null; %s %s%s %s >/dev/null 2>&1 & echo $! > %s",
    shellQuote(pidFile), playerName, playerArgs, coverArg, shellQuote(station.url), shellQuote(pidFile)
  )
  noctalia.runAsync(cmd)
  if cover == nil then
    loadFavicon(station)
  end
end

local function loadFavorites()
  local raw = noctalia.readFile(getDataDir() .. "/favorites.json")
  if raw == nil then
    return
  end
  local ok, val = pcall(noctalia.json.decode, raw)
  if ok and type(val) == "table" then
    favorites = val
  end
end

local function isFavorite(uuid)
  for i, f in ipairs(favorites) do
    if f.uuid == uuid then
      return true
    end
  end
  return false
end

local function saveFavorites()
  local ok, encoded = pcall(noctalia.json.encode, favorites)
  if ok and encoded ~= nil then
    noctalia.writeFile(getDataDir() .. "/favorites.json", encoded)
  end
end

local function toggleFavorite(station)
  for i, f in ipairs(favorites) do
    if f.uuid == station.uuid then
      table.remove(favorites, i)
      saveFavorites()
      render()
      return
    end
  end
  table.insert(favorites, station)
  saveFavorites()
  render()
end

loadFavorites()

local function loadCustomStations()
  local raw = noctalia.readFile(getDataDir() .. "/custom-stations.json")
  if raw == nil then
    return
  end
  local ok, val = pcall(noctalia.json.decode, raw)
  if ok and type(val) == "table" then
    customStations = val
  end
end

local function saveCustomStations()
  local ok, encoded = pcall(noctalia.json.encode, customStations)
  if ok and encoded ~= nil then
    noctalia.writeFile(getDataDir() .. "/custom-stations.json", encoded)
  end
end

local function openCustom()
  view = "custom"
  errorMessage = ""
  render()
end

local function openAddCustom()
  view = "add_custom"
  customFormName = ""
  customFormUrl = ""
  render()
end

local function saveCustomStation()
  local url = noctalia.string.trim(customFormUrl)
  if url == "" then
    return
  end
  local name = noctalia.string.trim(customFormName)
  if name == "" then
    name = url:match("^%a+://([^/:]+)") or url
  end
  table.insert(customStations, {
    uuid = "custom-" .. tostring(os.time()) .. "-" .. tostring(#customStations + 1),
    name = name,
    url = url,
    favicon = "",
    codec = "",
    bitrate = 0,
    votes = 0,
  })
  saveCustomStations()
  view = "custom"
  render()
end

local function removeCustomStation(index)
  table.remove(customStations, index)
  saveCustomStations()
  render()
end

loadCustomStations()

local function countryCount(code)
  if countries == nil then
    return 0
  end
  for _, c in ipairs(countries) do
    if c.iso == code then
      return c.count
    end
  end
  return 0
end

local function statCard(label, value)
  return ui.column({ flexGrow = 1, align = "stretch" }, {
    ui.column({ gap = 2, padding = 10, radius = 8, fill = "surface_variant/0.65", align = "center" }, {
      ui.label({ text = value, fontSize = 20, fontWeight = "bold", color = "primary" }),
      ui.label({ text = label, fontSize = 11, color = "outline" }),
    }),
  })
end

local function spinnerRow()
  return ui.row({ align = "center", justify = "center", gap = 8 }, {
    ui.glyph({ name = "loader-2", size = 18, color = "primary" }),
    ui.label({ text = tr("panel.loading"), fontSize = 12, color = "on_surface/0.7" }),
  })
end

local function centeredLabel(text, color)
  return ui.column({ flexGrow = 1, align = "center", justify = "center", padding = 32 }, {
    ui.label({ text = text, color = color or "outline", textAlign = "center" }),
  })
end

local function countryRow(c)
  local flag = flagEmoji(c.iso)
  local flagInner = (flag ~= "") and ui.label({ text = flag, fontSize = 12 }) or ui.glyph({ name = "world", size = 13, color = "outline" })
  local flagWidget = ui.column({ width = 24, height = 24, radius = 6, fill = "surface_variant/0.65", align = "center", justify = "center" }, { flagInner })
  return ui.row({ key = "country-" .. c.iso, gap = 8, align = "center", paddingV = 2, onClick = function() selectCountry(c.iso, c.name) end }, {
    flagWidget,
    ui.label({ text = c.name, fontSize = 12, flexGrow = 1, maxLines = 1 }),
    ui.label({ text = tostring(c.count), fontSize = 12, fontWeight = "bold", color = "outline" }),
    ui.glyph({ name = "chevron-right", size = 13, color = "outline" }),
  })
end

renderDashboard = function()
  local children = {}

  local totalStations
  if stats ~= nil and stats.stations ~= nil then
    totalStations = tostring(stats.stations)
  elseif countries ~= nil then
    local sum = 0
    for _, c in ipairs(countries) do
      sum = sum + c.count
    end
    totalStations = tostring(sum)
  else
    totalStations = "..."
  end

  local totalCountries = "..."
  if stats ~= nil and stats.countries ~= nil then
    totalCountries = tostring(stats.countries)
  elseif countries ~= nil then
    totalCountries = tostring(#countries)
  end

  table.insert(children, ui.row({ gap = 8 }, {
    statCard(tr("panel.total_stations"), totalStations),
    statCard(tr("panel.total_countries"), totalCountries),
  }))

  table.insert(children, ui.input({
    key         = "country-search-" .. queryKey,
    value       = query,
    controlSize = "sm",
    placeholder = tr("panel.search_countries_placeholder"),
    onChange    = "onSearchCountries",
  }))

  if countries == nil and errorMessage ~= "" then
    table.insert(children, centeredLabel(errorMessage, "on_surface/0.6"))
  elseif countries == nil and loading then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center" }, { spinnerRow() }))
  elseif countries ~= nil then
    local q = noctalia.string.trim(query):lower()
    local matches = {}
    for _, c in ipairs(countries) do
      if q == "" or c.name:lower():find(q, 1, true) ~= nil then
        table.insert(matches, c)
      end
    end
    if #matches == 0 then
      table.insert(children, centeredLabel(tr("panel.countries_empty")))
    else
      local rows = {}
      for _, c in ipairs(matches) do
        table.insert(rows, countryRow(c))
      end
      table.insert(children, ui.scroll({ gap = 2, flexGrow = 1 }, rows))
    end
  end

  return children
end

local function stationRow(s)
  loadFavicon(s)
  local isPlaying = playingUuid == s.uuid
  local thumb = thumbs[s.uuid]
  local meta = {}
  if s.codec ~= "" then
    table.insert(meta, s.codec)
  end
  if s.bitrate > 0 then
    table.insert(meta, tostring(s.bitrate))
  end
  local metaText = table.concat(meta, " · ")

  local parts = {}
  if thumb ~= nil then
    table.insert(parts, ui.image({ path = thumb, width = 26, height = 26, radius = 4 }))
  else
    table.insert(parts, ui.glyph({ name = "radio", size = 15, color = "outline" }))
  end

  local labels = { ui.label({ text = s.name, fontSize = 12, maxLines = 1 }) }
  if metaText ~= "" then
    table.insert(labels, ui.label({ text = metaText, fontSize = 11, color = "outline" }))
  end
  table.insert(parts, ui.column({ flexGrow = 1, gap = 0 }, labels))

  if s.votes > 0 then
    table.insert(parts, ui.label({ text = tostring(s.votes), fontSize = 11, color = "on_surface/0.45" }))
  end

  local faved = isFavorite(s.uuid)
  table.insert(parts, ui.button({
    glyph       = faved and "star-filled" or "star",
    variant     = "ghost",
    controlSize = "sm",
    tooltip     = faved and tr("panel.unfavorite_tooltip") or tr("panel.favorite_tooltip"),
    onClick     = function() toggleFavorite(s) end,
  }))

  table.insert(parts, ui.button({
    glyph       = isPlaying and "square" or "player-play",
    variant     = isPlaying and "primary" or "ghost",
    controlSize = "sm",
    tooltip     = isPlaying and tr("panel.stop_tooltip") or tr("panel.play_tooltip"),
    onClick     = function()
      if isPlaying then
        stopPlayback()
      else
        playStation(s)
      end
    end,
  }))

  return ui.row({ key = "station-" .. s.uuid, gap = 6, align = "center", paddingV = 1 }, parts)
end

renderCountry = function()
  local children = {}

  local headerParts = {}
  local countryFlag = flagEmoji(selectedCode)
  if countryFlag ~= "" then
    table.insert(headerParts, ui.label({ text = countryFlag, fontSize = 20 }))
  end
  table.insert(headerParts, ui.column({ flexGrow = 1, gap = 0 }, {
    ui.label({ text = selectedName, fontSize = 15, fontWeight = "bold", maxLines = 1 }),
    ui.label({ text = tr("panel.station_count", { count = tostring(countryCount(selectedCode)) }), fontSize = 11, color = "outline" }),
  }))
  table.insert(children, ui.row({ gap = 8, align = "center" }, headerParts))

  if stations == nil and loading then
    table.insert(children, ui.column({ flexGrow = 1, align = "center", justify = "center" }, { spinnerRow() }))
  elseif stations == nil and stationsErr then
    table.insert(children, centeredLabel(tr("panel.error_network"), "on_surface/0.6"))
  elseif stations ~= nil then
    table.insert(children, ui.input({
      key         = "station-search-" .. stationQueryKey,
      value       = stationQuery,
      controlSize = "sm",
      placeholder = tr("panel.search_stations_placeholder"),
      onChange    = "onStationSearch",
    }))
    local q = noctalia.string.trim(stationQuery):lower()
    local visible = {}
    for _, s in ipairs(stations) do
      if q == "" or s.name:lower():find(q, 1, true) ~= nil then
        table.insert(visible, s)
      end
    end
    if #visible == 0 and #stations == 0 then
      table.insert(children, centeredLabel(tr("panel.stations_empty")))
    elseif #visible == 0 then
      table.insert(children, centeredLabel(tr("panel.stations_none_match")))
    else
      local rows = {}
      for _, s in ipairs(visible) do
        table.insert(rows, stationRow(s))
      end
      table.insert(children, ui.scroll({ gap = 2, flexGrow = 1 }, rows))
      if not stationsDone then
        table.insert(children, ui.button({
          text         = tr("panel.load_more"),
          variant      = "secondary",
          controlSize  = "md",
          contentAlign = "center",
          enabled      = not loading,
          onClick      = "onLoadMore",
        }))
      end
    end
  end

  return children
end

renderFavorites = function()
  local children = {}

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "star-filled", size = 16, color = "warning" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = tr("panel.favorites_title"), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = tr("panel.favorites_count", { count = tostring(#favorites) }), fontSize = 11, color = "outline" }),
    }),
  }))

  if #favorites == 0 then
    table.insert(children, centeredLabel(tr("panel.favorites_empty")))
  else
    local rows = {}
    for _, s in ipairs(favorites) do
      table.insert(rows, stationRow(s))
    end
    table.insert(children, ui.scroll({ gap = 2, flexGrow = 1 }, rows))
  end

  return children
end

local function customRow(s, index)
  local isPlaying = playingUuid == s.uuid
  local labels = { ui.label({ text = s.name, fontSize = 12, maxLines = 1 }) }
  local parts = {
    ui.glyph({ name = "radio", size = 15, color = "outline" }),
    ui.column({ flexGrow = 1, gap = 0 }, labels),
  }
  table.insert(parts, ui.button({
    glyph       = "trash",
    variant     = "ghost",
    controlSize = "sm",
    tooltip     = tr("panel.remove_custom_tooltip"),
    onClick     = function() removeCustomStation(index) end,
  }))
  table.insert(parts, ui.button({
    glyph       = isPlaying and "square" or "player-play",
    variant     = isPlaying and "primary" or "ghost",
    controlSize = "sm",
    tooltip     = isPlaying and tr("panel.stop_tooltip") or tr("panel.play_tooltip"),
    onClick     = function()
      if isPlaying then
        stopPlayback()
      else
        playStation(s)
      end
    end,
  }))
  return ui.row({ key = "custom-" .. s.uuid, gap = 6, align = "center", paddingV = 1 }, parts)
end

renderCustom = function()
  local children = {}

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "broadcast", size = 16, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = tr("panel.custom_title"), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = tr("panel.custom_count", { count = tostring(#customStations) }), fontSize = 11, color = "outline" }),
    }),
    ui.button({
      glyph       = "plus",
      variant     = "secondary",
      controlSize = "md",
      tooltip     = tr("panel.add_custom_tooltip"),
      onClick     = openAddCustom,
    }),
  }))

  if #customStations == 0 then
    table.insert(children, ui.column({ gap = 10, align = "center", padding = 32, flexGrow = 1, justify = "center" }, {
      ui.glyph({ name = "broadcast", size = 32, color = "outline" }),
      ui.label({ text = tr("panel.custom_empty"), color = "outline", textAlign = "center" }),
    }))
  else
    local rows = {}
    for i, s in ipairs(customStations) do
      table.insert(rows, customRow(s, i))
    end
    table.insert(children, ui.scroll({ gap = 2, flexGrow = 1 }, rows))
  end

  return children
end

renderAddCustom = function()
  local children = {}

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = "plus", size = 16, color = "primary" }),
    ui.column({ flexGrow = 1, gap = 0 }, {
      ui.label({ text = tr("panel.add_custom_title"), fontSize = 15, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = tr("panel.add_custom_subtitle"), fontSize = 11, color = "outline" }),
    }),
  }))

  table.insert(children, ui.input({
    key         = "custom-name-input",
    value       = customFormName,
    controlSize = "md",
    placeholder = tr("panel.add_custom_name_placeholder"),
    onChange    = function(value) customFormName = value or "" end,
  }))

  table.insert(children, ui.input({
    key         = "custom-url-input",
    value       = customFormUrl,
    controlSize = "md",
    placeholder = tr("panel.add_custom_url_placeholder"),
    onChange    = function(value) customFormUrl = value or "" end,
  }))

  table.insert(children, ui.row({ gap = 8, align = "center" }, {
    ui.button({
      text         = tr("panel.add_custom_save"),
      variant      = "primary",
      controlSize  = "md",
      contentAlign = "center",
      onClick      = saveCustomStation,
    }),
    ui.button({
      text         = tr("panel.add_custom_cancel"),
      variant      = "ghost",
      controlSize  = "md",
      contentAlign = "center",
      onClick      = openCustom,
    }),
  }))

  return children
end

render = function()
  local children = {}

  local headerParts = {
    ui.glyph({ name = "radio", size = 18, color = "primary" }),
    ui.label({ text = tr("panel.title"), fontSize = 15, fontWeight = "bold", color = "on_surface", flexGrow = 1 }),
  }
  if view ~= "dashboard" then
    table.insert(headerParts, 2, ui.button({
      glyph       = "chevron-left",
      variant     = "ghost",
      controlSize = "md",
      tooltip     = tr("panel.back_tooltip"),
      onClick     = "onBack",
    }))
  end
  table.insert(headerParts, ui.button({
    glyph       = (#favorites > 0) and "star-filled" or "star",
    variant     = "ghost",
    controlSize = "md",
    tooltip     = tr("panel.favorites_title"),
    onClick     = "onOpenFavorites",
  }))
  table.insert(headerParts, ui.button({
    glyph       = "broadcast",
    variant     = "ghost",
    controlSize = "md",
    tooltip     = tr("panel.custom_title"),
    onClick     = openCustom,
  }))
  if playingUuid ~= nil then
    table.insert(headerParts, ui.button({
      glyph       = "square",
      variant     = "outline",
      controlSize = "md",
      tooltip     = tr("panel.stop_tooltip"),
      onClick     = "onStop",
    }))
  end

  table.insert(children, ui.row({ gap = 6, align = "center" }, headerParts))
  table.insert(children, ui.separator({}))

  local body
  if view == "country" then
    body = renderCountry()
  elseif view == "favorites" then
    body = renderFavorites()
  elseif view == "custom" then
    body = renderCustom()
  elseif view == "add_custom" then
    body = renderAddCustom()
  else
    body = renderDashboard()
  end
  for _, el in ipairs(body) do
    table.insert(children, el)
  end

  panel.render(ui.column({ gap = 10, padding = 12, flexGrow = 1, align = "stretch" }, children))
end

function onOpen(_context)
  local cachedCountries = readCachedJson("countries.json", COUNTRIES_CACHE_AGE)
  if cachedCountries ~= nil then
    countries = cachedCountries
  end
  local cachedStats = readCachedJson("stats.json", COUNTRIES_CACHE_AGE)
  if cachedStats ~= nil then
    stats = cachedStats
  end
  view = "dashboard"
  render()
  fetchCountries()
end

function onBack()
  if view == "add_custom" then
    view = "custom"
  else
    view = "dashboard"
  end
  stations = nil
  errorMessage = ""
  render()
end

function onStop()
  stopPlayback()
end

function onOpenFavorites()
  view = "favorites"
  errorMessage = ""
  render()
end

function onSearchCountries(value)
  query = value or ""
  render()
end

function onStationSearch(value)
  stationQuery = value or ""
  render()
end

function onLoadMore()
  if stationsOffset > 0 then
    fetchStations(stationsOffset)
  end
end

function onConfigChanged()
  render()
end