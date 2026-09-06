--!strict
-- Speedtest Meter — panel entry point.
--
-- Distro-independent by design: it works with either backend it finds on
-- PATH, in this order of preference:
--   1. "ookla"  -> the official Ookla CLI (binary `speedtest`). Streams
--      progress line by line, so the gauge is truly live.
--   2. "legacy" -> the Python `speedtest-cli` package (binary
--      `speedtest-cli`), packaged in Arch's official repos (pacman -S
--      speedtest-cli), Debian/Ubuntu, Fedora, openSUSE and Alpine. No
--      incremental progress is available from this tool, so the gauge
--      pulses instead of tracking a real-time value while it runs.
-- If neither is found, the error screen shows an install command for the
-- detected package manager (pacman/apt/dnf/zypper/apk) instead of a single
-- hardcoded distro's instructions.
--
-- All user-facing strings come from noctalia.tr(...), backed by
-- translations/en.json and translations/pt-BR.json next to this file.

-- ── State ─────────────────────────────────────────────────────────────────

local state = "idle" -- "idle" | "running" | "done" | "error"
local phase = "" -- "ping" | "download" | "upload" (ookla backend only)
local backendInUse: string? = nil -- "ookla" | "legacy"
local liveMbps = 0
local gaugeMax = 100 -- dynamic upper bound for the speedometer scale
local runningElapsed = 0 -- seconds since the current test started (drives the pulse + watchdog)
local errorMessage: string? = nil
local result: any = nil -- normalized result table (see normalizeOokla/normalizeLegacy)
local clientInfo: any = nil -- decoded geolocation JSON for the local client
local panelActive = false

local widgetIconDraft = "SPD"

local DATA_FILE = "/last-result.json"
local OOKLA_CMD = "speedtest --accept-license --accept-gdpr --format=json --progress=yes"
local LEGACY_CMD = "speedtest-cli --json --secure"
local LEGACY_TIMEOUT_MS = 60000 -- runAsync's hard ceiling; slow links may not finish in time

-- Best-effort per-distro install command for the (widely packaged) legacy
-- Python speedtest-cli, keyed by the package manager binary that's present.
local INSTALL_COMMANDS = {
	pacman = "sudo pacman -S speedtest-cli",
	apt = "sudo apt install speedtest-cli",
	dnf = "sudo dnf install speedtest-cli",
	zypper = "sudo zypper install speedtest-cli",
	apk = "sudo apk add speedtest-cli",
	unknown = "pip install speedtest-cli",
}

-- Forward declarations so functions can reference each other regardless of
-- definition order below.
local render, renderIdle, renderRunning, renderDone, renderError
local renderSummaryCard, metricRow
local startTest, proceedWithLegacyOrError, runOoklaBackend, runLegacyBackend, onSpeedtestLine
local normalizeOokla, normalizeLegacy
local saveLastResult, loadLastResult, fetchClientInfo
local detectPackageManager, saveWidgetIcon

-- ── Helpers ───────────────────────────────────────────────────────────────

local function bandwidthBytesToMbps(bandwidthBytesPerSec: number?): number
	if not bandwidthBytesPerSec then
		return 0
	end
	return bandwidthBytesPerSec * 8 / 1000000
end

local function bitsToMbps(bitsPerSec: number?): number
	if not bitsPerSec then
		return 0
	end
	return bitsPerSec / 1000000
end

local function formatMetric(value: number?, fmt: string): string
	if value == nil then
		return "-"
	end
	return string.format(fmt, value)
end

metricRow = function(labelKey: string, value: string)
	return ui.row({ spacing = 8 }, {
		ui.label({ text = noctalia.tr(labelKey) .. ":", opacity = 0.7, width = 150 }),
		ui.label({ text = value, bold = true }),
	})
end

-- ── Package manager detection (for install instructions) ──────────────────

detectPackageManager = function(): string
	if noctalia.commandExists("pacman") then
		return "pacman"
	elseif noctalia.commandExists("apt") then
		return "apt"
	elseif noctalia.commandExists("dnf") then
		return "dnf"
	elseif noctalia.commandExists("zypper") then
		return "zypper"
	elseif noctalia.commandExists("apk") then
		return "apk"
	end
	return "unknown"
end

-- ── Result normalization (both backends map into this common shape) ───────

normalizeOokla = function(data: any)
	local server = data.server or {}
	local iface = data.interface or {}
	local res = data.result or {}
	local ping = data.ping or {}
	return {
		downloadMbps = bandwidthBytesToMbps(data.download and data.download.bandwidth),
		uploadMbps = bandwidthBytesToMbps(data.upload and data.upload.bandwidth),
		pingMs = ping.latency,
		jitterMs = ping.jitter,
		packetLoss = data.packetLoss,
		serverName = server.name,
		serverHost = server.host,
		serverLocation = server.location,
		serverCountry = server.country,
		serverIp = server.ip,
		isp = data.isp,
		externalIp = iface.externalIp,
		resultUrl = res.url,
	}
end

-- Python speedtest-cli's --json output: download/upload are already in
-- bits/sec (not bytes/sec like Ookla's), and it has no jitter/packetLoss.
normalizeLegacy = function(data: any)
	local server = data.server or {}
	local client = data.client or {}
	return {
		downloadMbps = bitsToMbps(data.download),
		uploadMbps = bitsToMbps(data.upload),
		pingMs = data.ping,
		jitterMs = nil,
		packetLoss = nil,
		serverName = server.sponsor,
		serverHost = server.host,
		serverLocation = server.name,
		serverCountry = server.country,
		serverIp = nil,
		isp = client.isp,
		externalIp = client.ip,
		resultUrl = data.share,
	}
end

-- ── Persistence (so the last result survives closing the panel) ────────────

saveLastResult = function(data: any)
	local dir = noctalia.pluginDataDir()
	if not dir then
		return
	end
	local encoded = noctalia.json.encode(data, false)
	if encoded then
		noctalia.writeFile(dir .. DATA_FILE, encoded)
	end
end

loadLastResult = function()
	local dir = noctalia.pluginDataDir()
	if not dir then
		return
	end
	local contents = noctalia.readFile(dir .. DATA_FILE)
	if not contents then
		return
	end
	local data = noctalia.json.decode(contents)
	if data then
		result = data
	end
end

-- Optional enrichment: adds the client's own public IP geolocation
-- (city/region/country/ISP org) alongside whatever the backend reported.
fetchClientInfo = function()
	noctalia.http({ url = "https://ipapi.co/json/" }, function(response)
		if not panelActive then
			return
		end
		if response.ok and response.status == 200 then
			local data = noctalia.json.decode(response.body)
			if data then
				clientInfo = data
				render()
			end
		end
	end)
end

-- ── Widget icon (shared with widget.luau via noctalia.state) ──────────────

saveWidgetIcon = function(value: string)
	local trimmed = noctalia.string.trim(value)
	if trimmed == "" then
		return
	end
	noctalia.state.set("widgetIcon", trimmed)
	noctalia.notify(noctalia.tr("app_name"), noctalia.tr("notify_icon_saved"))
end

-- ── Speedtest run ────────────────────────────────────────────────────────

startTest = function()
	if state == "running" then
		return
	end

	errorMessage = nil
	result = nil
	clientInfo = nil
	phase = ""
	liveMbps = 0
	gaugeMax = 100
	runningElapsed = 0
	backendInUse = nil
	state = "running"
	render()

	-- A binary named `speedtest` isn't proof it's the Ookla CLI: on Arch (and
	-- possibly elsewhere), the official `speedtest-cli` package installs
	-- BOTH `speedtest-cli` and a `speedtest` entry point pointing at the
	-- same Python tool, which doesn't understand Ookla's
	-- `--format=json --progress=yes` flags. So `speedtest` is verified by
	-- its --version output before being trusted, with `speedtest-cli`
	-- (unambiguous) as the fallback either way.
	if noctalia.commandExists("speedtest") then
		local started = noctalia.runAsync("speedtest --version", function(res)
			if not panelActive then
				return
			end
			local versionText = string.lower(res.stdout or "")
			if not res.timedOut and string.find(versionText, "ookla", 1, true) then
				backendInUse = "ookla"
				render()
				runOoklaBackend()
			else
				proceedWithLegacyOrError()
			end
		end, 5000)

		if not started then
			proceedWithLegacyOrError()
		end
	else
		proceedWithLegacyOrError()
	end
end

proceedWithLegacyOrError = function()
	if not panelActive then
		return
	end

	if noctalia.commandExists("speedtest-cli") then
		backendInUse = "legacy"
		render()
		runLegacyBackend()
	else
		state = "error"
		errorMessage = noctalia.tr("error_cli_not_found")
		render()
	end
end

runOoklaBackend = function()
	-- Frame tick drives the "stuck?" watchdog hint below, not just the
	-- legacy backend's pulse.
	panel.setNeedsFrameTick(true)

	-- Many CLI tools fully buffer stdout (instead of line-buffering) once
	-- it's a pipe rather than a real terminal, so `speedtest`'s JSON lines
	-- may not reach onLine until the process exits, or at all if the panel
	-- closes first. `stdbuf -oL` forces line buffering regardless. `stdbuf`
	-- ships in coreutils and is present on effectively every Linux system.
	local cmd = OOKLA_CMD
	if noctalia.commandExists("stdbuf") then
		cmd = "stdbuf -oL " .. OOKLA_CMD
	end

	local started = noctalia.runStream(cmd, onSpeedtestLine)
	if not started then
		state = "error"
		errorMessage = noctalia.tr("error_could_not_start")
		render()
	end
end

runLegacyBackend = function()
	-- No incremental progress from this tool, so pulse the gauge instead.
	panel.setNeedsFrameTick(true)
	local started = noctalia.runAsync(LEGACY_CMD, function(cmdResult)
		if not panelActive then
			return
		end
		panel.setNeedsFrameTick(false)

		if cmdResult.timedOut then
			state = "error"
			errorMessage = noctalia.tr("error_timeout")
			render()
			return
		end

		if cmdResult.exitCode ~= 0 then
			state = "error"
			errorMessage = noctalia.tr("error_cli_reported")
			render()
			return
		end

		local data = noctalia.json.decode(cmdResult.stdout)
		if not data then
			state = "error"
			errorMessage = noctalia.tr("error_cli_reported")
			render()
			return
		end

		result = normalizeLegacy(data)
		state = "done"
		saveLastResult(result)
		fetchClientInfo()
		render()
	end, LEGACY_TIMEOUT_MS)

	if not started then
		panel.setNeedsFrameTick(false)
		state = "error"
		errorMessage = noctalia.tr("error_could_not_start")
		render()
	end
end

onSpeedtestLine = function(line: string)
	if not panelActive then
		return -- panel closed mid-test; drop late updates
	end

	local trimmed = noctalia.string.trim(line)
	if trimmed == "" then
		return
	end

	local data = noctalia.json.decode(trimmed)
	if not data then
		return -- ignore partial / malformed lines
	end

	local t = data.type

	if t == "ping" then
		phase = "ping"
		render()
	elseif t == "download" then
		phase = "download"
		liveMbps = bandwidthBytesToMbps(data.download and data.download.bandwidth)
		render()
	elseif t == "upload" then
		phase = "upload"
		liveMbps = bandwidthBytesToMbps(data.upload and data.upload.bandwidth)
		render()
	elseif t == "result" then
		result = normalizeOokla(data)
		state = "done"
		phase = ""
		saveLastResult(result)
		fetchClientInfo()
		render()
	elseif t == "error" then
		state = "error"
		errorMessage = data.message or noctalia.tr("error_cli_reported")
		render()
	end
end

-- ── Rendering ────────────────────────────────────────────────────────────

render = function()
	if not panelActive then
		return
	end

	local tree
	if state == "running" then
		tree = renderRunning()
	elseif state == "done" then
		tree = renderDone()
	elseif state == "error" then
		tree = renderError()
	else
		tree = renderIdle()
	end

	panel.render(tree)
end

renderSummaryCard = function(r: any)
	return ui.column({ spacing = 4 }, {
		ui.label({ text = noctalia.tr("last_result"), fontSize = 12, opacity = 0.6 }),
		ui.row({ spacing = 12 }, {
			ui.label({ text = string.format("\u{2193} %.1f Mbps", r.downloadMbps or 0) }),
			ui.label({ text = string.format("\u{2191} %.1f Mbps", r.uploadMbps or 0) }),
			ui.label({ text = formatMetric(r.pingMs, "%.0f ms") }),
		}),
	})
end

renderIdle = function()
	local children = {
		ui.label({ text = noctalia.tr("app_name"), fontSize = 20, bold = true }),
		ui.label({ text = noctalia.tr("idle_subtitle"), opacity = 0.7 }),
		ui.spacer({ size = 12 }),
	}

	if result then
		table.insert(children, renderSummaryCard(result))
		table.insert(children, ui.spacer({ size = 12 }))
	end

	table.insert(children, ui.button({ text = noctalia.tr("start_test"), onClick = startTest }))

	-- Widget icon setting. Type any text or a single glyph (e.g. a Nerd Font
	-- character) — it's passed straight to barWidget.setText in widget.luau.
	table.insert(children, ui.separator({}))
	table.insert(children, ui.label({ text = noctalia.tr("widget_icon_label"), fontSize = 13, bold = true }))
	table.insert(
		children,
		ui.row({ spacing = 8 }, {
			ui.input({
				value = widgetIconDraft,
				placeholder = "SPD",
				onChange = function(newValue: string)
					widgetIconDraft = newValue
				end,
			}),
			ui.button({
				text = noctalia.tr("save"),
				onClick = function()
					saveWidgetIcon(widgetIconDraft)
				end,
			}),
		})
	)

	return ui.column({ spacing = 8, padding = 16 }, children)
end

renderRunning = function()
	local progressValue = 0

	if backendInUse == "legacy" then
		-- No real progress signal from this backend: pulse the gauge so it
		-- still reads as "alive" instead of a frozen bar.
		progressValue = 0.3 + 0.2 * math.sin(runningElapsed * 2)
	else
		if liveMbps > gaugeMax then
			gaugeMax = math.max(50, math.ceil(liveMbps / 50) * 50)
		end
		if gaugeMax > 0 then
			progressValue = math.min(1, liveMbps / gaugeMax)
		end
	end

	local phaseKey = "phase_preparing"
	if backendInUse == "legacy" then
		phaseKey = "phase_legacy_running"
	elseif phase == "ping" then
		phaseKey = "phase_ping"
	elseif phase == "download" then
		phaseKey = "phase_download"
	elseif phase == "upload" then
		phaseKey = "phase_upload"
	end

	local children = {
		ui.label({ text = noctalia.tr("app_name"), fontSize = 18, bold = true }),
		ui.label({ text = noctalia.tr(phaseKey), opacity = 0.75 }),
		ui.spacer({ size = 8 }),
		-- Speedometer gauge. NOTE: `orientation`/`thickness` are a best
		-- guess at ui.progress's prop schema — the supplied API doc doesn't
		-- list per-component props. Check ui.progress's actual props in
		-- your Noctalia version and adjust if needed.
		ui.progress({
			value = progressValue,
			orientation = "circular",
			thickness = 10,
		}),
	}

	if backendInUse ~= "legacy" then
		table.insert(children, ui.label({ text = string.format("%.1f Mbps", liveMbps), fontSize = 28, bold = true }))
		table.insert(
			children,
			ui.label({
				text = noctalia.tr("gauge_scale", { max = gaugeMax }),
				fontSize = 11,
				opacity = 0.6,
			})
		)
	end

	-- Watchdog: if the ookla backend has produced no phase update after 10s,
	-- something is likely wrong (e.g. the CLI is hanging) — say so instead
	-- of silently sitting at "Preparando...".
	if backendInUse == "ookla" and phase == "" and runningElapsed > 10 then
		table.insert(children, ui.spacer({ size = 8 }))
		table.insert(children, ui.label({ text = noctalia.tr("hint_stuck"), fontSize = 11, opacity = 0.6 }))
	end

	return ui.column({ spacing = 10, padding = 16, align = "center" }, children)
end

renderDone = function()
	local r = result or {}

	local children = {
		ui.label({ text = noctalia.tr("result_title"), fontSize = 18, bold = true }),
		ui.spacer({ size = 6 }),

		metricRow("metric_download", string.format("%.1f Mbps", r.downloadMbps or 0)),
		metricRow("metric_upload", string.format("%.1f Mbps", r.uploadMbps or 0)),
		metricRow("metric_ping", formatMetric(r.pingMs, "%.1f ms")),
		metricRow("metric_jitter", formatMetric(r.jitterMs, "%.1f ms")),
		metricRow("metric_packet_loss", formatMetric(r.packetLoss, "%.1f%%")),

		ui.separator({}),
		ui.label({ text = noctalia.tr("section_server"), fontSize = 14, bold = true }),
		metricRow("metric_name", tostring(r.serverName or "-")),
		metricRow("metric_host", tostring(r.serverHost or "-")),
		metricRow("metric_location", tostring(r.serverLocation or "-")),
		metricRow("metric_country", tostring(r.serverCountry or "-")),
		metricRow("metric_server_ip", tostring(r.serverIp or "-")),

		ui.separator({}),
		ui.label({ text = noctalia.tr("section_connection"), fontSize = 14, bold = true }),
		metricRow("metric_isp", tostring(r.isp or "-")),
		metricRow("metric_external_ip", tostring(r.externalIp or "-")),
	}

	if clientInfo then
		table.insert(children, metricRow("metric_city", tostring(clientInfo.city or "-")))
		table.insert(children, metricRow("metric_region", tostring(clientInfo.region or "-")))
		table.insert(children, metricRow("metric_country_ip", tostring(clientInfo.country_name or "-")))
		table.insert(children, metricRow("metric_org", tostring(clientInfo.org or "-")))
	end

	table.insert(children, ui.spacer({ size = 10 }))

	local buttons = { ui.button({ text = noctalia.tr("test_again"), onClick = startTest }) }
	if r.resultUrl then
		table.insert(
			buttons,
			ui.button({
				text = noctalia.tr("copy_result_link"),
				onClick = function()
					noctalia.copyToClipboard(r.resultUrl, "text/plain")
					noctalia.notify(noctalia.tr("app_name"), noctalia.tr("notify_link_copied"))
				end,
			})
		)
	end
	table.insert(children, ui.row({ spacing = 8 }, buttons))

	return ui.column({ spacing = 6, padding = 16 }, children)
end

renderError = function()
	local pkgManager = detectPackageManager()
	local installCmd = INSTALL_COMMANDS[pkgManager] or INSTALL_COMMANDS.unknown

	return ui.column({ spacing = 10, padding = 16 }, {
		ui.label({ text = noctalia.tr("error_title"), fontSize = 18, bold = true }),
		ui.label({ text = errorMessage or noctalia.tr("error_unknown"), opacity = 0.8 }),
		ui.spacer({ size = 8 }),
		ui.label({ text = noctalia.tr("error_missing_cli"), opacity = 0.7 }),
		ui.button({
			text = noctalia.tr("copy_install_command"),
			onClick = function()
				noctalia.copyToClipboard(installCmd, "text/plain")
				noctalia.notify(noctalia.tr("app_name"), noctalia.tr("notify_command_copied"))
			end,
		}),
		ui.label({ text = installCmd, fontSize = 11, opacity = 0.5 }),
		ui.spacer({ size = 4 }),
		ui.label({ text = noctalia.tr("error_ookla_hint"), fontSize = 11, opacity = 0.6 }),
		ui.spacer({ size = 8 }),
		ui.button({ text = noctalia.tr("try_again"), onClick = startTest }),
	})
end

-- ── Panel lifecycle ──────────────────────────────────────────────────────

function onOpen(context: any)
	panelActive = true
	local storedIcon = noctalia.state.get("widgetIcon")
	if storedIcon and storedIcon ~= "" then
		widgetIconDraft = storedIcon
	end
	if state == "idle" and result == nil then
		loadLastResult()
	end
	render()
end

function onClose()
	panelActive = false
	panel.setNeedsFrameTick(false)
end

function onFrameTick(deltaMs: number)
	if state ~= "running" then
		return
	end
	runningElapsed += deltaMs / 1000
	render()
end
