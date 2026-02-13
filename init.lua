-- obs-loom: OBS recording watcher with instant GCS sharing + optional source capture
-- Watches a directory for new .mp4 files from OBS, uploads to GCS with instant URLs
-- Optionally captures raw screen/webcam/audio sources for post-production editing

local obsLoom = {}
obsLoom.watcher = nil
obsLoom.knownFiles = {}
obsLoom.activeFile = nil
obsLoom.lastSize = -1
obsLoom.pollTimer = nil
obsLoom.isUploading = false

-- Source capture state
obsLoom.isCapturing = false
obsLoom.screenTask = nil
obsLoom.webcamTask = nil
obsLoom.audioTask = nil
obsLoom.sourceFolder = nil

-- Configuration
local watchDirectory = os.getenv("HOME") .. "/OBSRecordings"
local configFile = os.getenv("HOME") .. "/.obs-loom-config.json"
local gcsBucket = ""
local sourceCaptureEnabled = false
local sourceOutputDirectory = os.getenv("HOME") .. "/OBSSourceFiles"

-- Device selection
local selectedScreenId = nil
local currentScreenName = "Main Display"
local availableScreens = {}
local selectedCameraDevice = nil
local currentCameraName = "No Camera"
local availableCameras = {}
local selectedAudioDevice = ":0"
local currentAudioName = "Built-in Microphone"
local availableAudioDevices = {}

-- File stability threshold (seconds of no size change)
local STABILITY_THRESHOLD = 2
local POLL_INTERVAL = 1

-- Menu bar
local menuBar = nil

-- Utility: Trim whitespace
function string:trim()
    return self:match("^%s*(.-)%s*$")
end

-- Find gsutil path
local function findGsutilPath()
    local paths = {
        "/opt/homebrew/bin/gsutil",
        "/usr/local/bin/gsutil",
        "/usr/bin/gsutil"
    }
    for _, path in ipairs(paths) do
        local check = hs.execute("test -f '" .. path .. "' && echo 'found' || echo 'notfound'")
        if check and check:match("found") then
            return path
        end
    end
    local whichOutput = hs.execute("which gsutil 2>&1")
    if whichOutput and not whichOutput:match("not found") then
        local path = whichOutput:match("^%s*(.-)%s*$")
        if path and path ~= "" then return path end
    end
    return "/opt/homebrew/bin/gsutil"
end

-- Find ffmpeg path (for source capture)
local function findFFmpegPath()
    local paths = {
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    }
    for _, path in ipairs(paths) do
        local check = hs.execute("test -f '" .. path .. "' && echo 'found' || echo 'notfound'")
        if check and check:match("found") then
            return path
        end
    end
    local whichOutput = hs.execute("which ffmpeg 2>&1")
    if whichOutput and not whichOutput:match("not found") then
        local path = whichOutput:match("^%s*(.-)%s*$")
        if path and path ~= "" then return path end
    end
    return "/opt/homebrew/bin/ffmpeg"
end

-- Find sox rec path (for source capture)
local function findRecPath()
    local paths = {
        "/opt/homebrew/bin/rec",
        "/usr/local/bin/rec",
        "/usr/bin/rec"
    }
    for _, path in ipairs(paths) do
        local check = hs.execute("test -f '" .. path .. "' && echo 'found' || echo 'notfound'")
        if check and check:match("found") then
            return path
        end
    end
    return "/opt/homebrew/bin/rec"
end

local gsutilPath = findGsutilPath()
local ffmpegPath = findFFmpegPath()
local recPath = findRecPath()

-- ============================================================
-- Configuration persistence
-- ============================================================

local function loadConfig()
    local file = io.open(configFile, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local success, config = pcall(function()
            return hs.json.decode(content)
        end)
        if success and config then
            gcsBucket = config.gcsBucket or ""
            watchDirectory = config.watchDirectory or watchDirectory
            sourceCaptureEnabled = config.sourceCaptureEnabled or false
            sourceOutputDirectory = config.sourceOutputDirectory or sourceOutputDirectory
            selectedScreenId = config.selectedScreenId
            selectedCameraDevice = config.selectedCameraDevice
            selectedAudioDevice = config.selectedAudioDevice or ":0"
            print("obs-loom: Config loaded — bucket=" .. gcsBucket .. ", watch=" .. watchDirectory .. ", sourceCapture=" .. tostring(sourceCaptureEnabled))
            return true
        end
    end
    print("obs-loom: No config file found, using defaults")
    return false
end

local function saveConfig()
    local config = {
        gcsBucket = gcsBucket,
        watchDirectory = watchDirectory,
        sourceCaptureEnabled = sourceCaptureEnabled,
        sourceOutputDirectory = sourceOutputDirectory,
        selectedScreenId = selectedScreenId,
        selectedCameraDevice = selectedCameraDevice,
        selectedAudioDevice = selectedAudioDevice
    }
    local content = hs.json.encode(config)
    local file = io.open(configFile, "w")
    if file then
        file:write(content)
        file:close()
        print("obs-loom: Config saved")
        return true
    else
        print("obs-loom: Failed to save config")
        return false
    end
end

-- ============================================================
-- Device enumeration (for source capture)
-- ============================================================

function obsLoom.enumerateScreens()
    availableScreens = {}
    local screens = hs.screen.allScreens()
    for i, screen in ipairs(screens) do
        local screenName = screen:name() or ("Display " .. i)
        table.insert(availableScreens, {
            id = screen:id(),
            name = screenName,
            screen = screen
        })
    end
    if #availableScreens > 0 and not selectedScreenId then
        selectedScreenId = availableScreens[1].id
        currentScreenName = availableScreens[1].name
    end
    return availableScreens
end

function obsLoom.enumerateCameras()
    availableCameras = {}
    availableAudioDevices = {}

    local output = hs.execute(ffmpegPath .. ' -f avfoundation -list_devices true -i "" 2>&1')
    if not output then
        print("obs-loom: No output from ffmpeg device enumeration")
        return availableCameras
    end

    local inVideoSection = false
    local inAudioSection = false

    for line in output:gmatch("[^\r\n]+") do
        if line:match("AVFoundation video devices:") then
            inVideoSection = true
            inAudioSection = false
        elseif line:match("AVFoundation audio devices:") then
            inVideoSection = false
            inAudioSection = true
        elseif inAudioSection and not line:match("%[AVFoundation") then
            break
        end

        if line:match("%[AVFoundation") and line:match("%]") then
            local deviceNum, deviceName = line:match("%[(%d+)%] (.+)")
            if deviceNum and deviceName then
                if inVideoSection then
                    if not deviceName:match("Capture screen") then
                        table.insert(availableCameras, {
                            index = deviceNum,
                            name = deviceName
                        })
                    end
                elseif inAudioSection then
                    table.insert(availableAudioDevices, {
                        index = deviceNum,
                        name = deviceName
                    })
                end
            end
        end
    end

    if #availableCameras == 0 then
        table.insert(availableCameras, {index = nil, name = "No Camera"})
    end

    -- Set default camera
    if not selectedCameraDevice and #availableCameras > 0 then
        for _, cam in ipairs(availableCameras) do
            if cam.index ~= nil then
                selectedCameraDevice = cam.index
                currentCameraName = cam.name
                break
            end
        end
    end

    -- Update current camera name from saved config
    if selectedCameraDevice then
        for _, cam in ipairs(availableCameras) do
            if cam.index == selectedCameraDevice then
                currentCameraName = cam.name
                break
            end
        end
    end

    return availableCameras
end

function obsLoom.enumerateAudioDevices()
    if #availableAudioDevices == 0 then
        table.insert(availableAudioDevices, {index = "1", name = "Built-in Microphone"})
    end
    -- Update current audio name from saved config
    local audioIndex = selectedAudioDevice:match(":(%d+)")
    if audioIndex then
        for _, aud in ipairs(availableAudioDevices) do
            if aud.index == audioIndex then
                currentAudioName = aud.name
                break
            end
        end
    end
    return availableAudioDevices
end

-- Update current screen name from saved config
local function updateScreenName()
    if selectedScreenId then
        for _, scr in ipairs(availableScreens) do
            if scr.id == selectedScreenId then
                currentScreenName = scr.name
                break
            end
        end
    end
end

-- ============================================================
-- Source capture (FFmpeg screen/webcam + sox audio)
-- ============================================================

function obsLoom.startSourceCapture(recordingFileName)
    if obsLoom.isCapturing then
        print("obs-loom: Source capture already running")
        return
    end
    if not sourceCaptureEnabled then
        return
    end

    print("\n=== obs-loom: STARTING SOURCE CAPTURE ===")

    -- Create subfolder based on exact recording filename
    local baseName = recordingFileName:match("(.+)%.mp4$") or recordingFileName
    obsLoom.sourceFolder = sourceOutputDirectory .. "/" .. baseName .. "_sources"
    os.execute("mkdir -p '" .. obsLoom.sourceFolder .. "'")
    print("Source folder: " .. obsLoom.sourceFolder)

    local screenFile = obsLoom.sourceFolder .. "/screen.mp4"
    local webcamFile = obsLoom.sourceFolder .. "/webcam.mp4"
    local audioFile = obsLoom.sourceFolder .. "/audio.wav"

    -- Start screen recording (video only)
    local screenIndex = 0
    for i, scr in ipairs(availableScreens) do
        if scr.id == selectedScreenId then
            screenIndex = i - 1
            break
        end
    end
    local screenCaptureIndex = screenIndex + #availableCameras

    local screenArgs = {
        "-f", "avfoundation",
        "-framerate", "30",
        "-capture_cursor", "1",
        "-capture_mouse_clicks", "1",
        "-i", tostring(screenCaptureIndex) .. ":none",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-tune", "zerolatency",
        "-crf", "23",
        "-pix_fmt", "yuv420p",
        "-y",
        screenFile
    }

    obsLoom.screenTask = hs.task.new(ffmpegPath,
        function(exitCode, stdOut, stdErr)
            print("obs-loom: Screen capture stopped (exit: " .. tostring(exitCode) .. ")")
        end,
        screenArgs
    )
    obsLoom.screenTask:setStreamingCallback(function(task, stdOut, stdErr)
        return true
    end)

    -- Start webcam recording
    if selectedCameraDevice and selectedCameraDevice ~= "nil" then
        local webcamArgs = {
            "-f", "avfoundation",
            "-framerate", "30",
            "-video_size", "1280x720",
            "-i", selectedCameraDevice .. ":",
            "-c:v", "libx264",
            "-preset", "ultrafast",
            "-crf", "23",
            "-pix_fmt", "yuv420p",
            "-y",
            webcamFile
        }

        obsLoom.webcamTask = hs.task.new(ffmpegPath,
            function(exitCode, stdOut, stdErr)
                print("obs-loom: Webcam capture stopped (exit: " .. tostring(exitCode) .. ")")
            end,
            webcamArgs
        )
        obsLoom.webcamTask:setStreamingCallback(function(task, stdOut, stdErr)
            return true
        end)
    end

    -- Start audio recording with sox
    local audioArgs = {
        "-c", "2",
        "-r", "48000",
        "-b", "16",
        audioFile
    }

    obsLoom.audioTask = hs.task.new(recPath,
        function(exitCode, stdOut, stdErr)
            print("obs-loom: Audio capture stopped (exit: " .. tostring(exitCode) .. ")")
        end,
        audioArgs
    )
    obsLoom.audioTask:setStreamingCallback(function(task, stdOut, stdErr)
        return true
    end)

    -- Start all tasks simultaneously
    local screenStarted = obsLoom.screenTask:start()
    local audioStarted = obsLoom.audioTask:start()
    print("obs-loom: Screen task started: " .. tostring(screenStarted))
    print("obs-loom: Audio task started: " .. tostring(audioStarted))

    if obsLoom.webcamTask then
        local webcamStarted = obsLoom.webcamTask:start()
        print("obs-loom: Webcam task started: " .. tostring(webcamStarted))
    end

    obsLoom.isCapturing = true
    print("=== obs-loom: SOURCE CAPTURE RUNNING ===\n")
end

function obsLoom.stopSourceCapture()
    if not obsLoom.isCapturing then
        return
    end

    print("\n=== obs-loom: STOPPING SOURCE CAPTURE ===")

    -- Send stop signals (same pattern as loom-go)
    if obsLoom.screenTask then
        local pid = obsLoom.screenTask:pid()
        if pid then
            print("obs-loom: Sending SIGTERM to screen (PID: " .. tostring(pid) .. ")")
            os.execute("kill -15 " .. pid)
        end
    end

    if obsLoom.audioTask then
        print("obs-loom: Sending SIGINT to audio")
        obsLoom.audioTask:interrupt()
    end

    if obsLoom.webcamTask then
        print("obs-loom: Sending SIGINT to webcam")
        obsLoom.webcamTask:interrupt()
    end

    -- Force kill after 3s if still running
    hs.timer.doAfter(3, function()
        local tasks = {
            {task = obsLoom.audioTask, name = "audio"},
            {task = obsLoom.webcamTask, name = "webcam"},
            {task = obsLoom.screenTask, name = "screen"}
        }
        for _, t in ipairs(tasks) do
            if t.task and t.task:isRunning() then
                local pid = t.task:pid()
                if pid then
                    print("obs-loom: Force killing " .. t.name .. " (PID: " .. tostring(pid) .. ")")
                    os.execute("kill -9 " .. pid)
                end
            end
        end
        print("obs-loom: All source capture tasks stopped")
    end)

    obsLoom.screenTask = nil
    obsLoom.webcamTask = nil
    obsLoom.audioTask = nil
    obsLoom.isCapturing = false

    hs.alert.show("📹 Source capture saved")
    print("obs-loom: Source files in: " .. tostring(obsLoom.sourceFolder))
    print("=== obs-loom: SOURCE CAPTURE STOPPED ===\n")
end

-- ============================================================
-- Placeholder HTML (same as loom-go)
-- ============================================================

local function generatePlaceholderHTML()
    return [[<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Video Processing...</title>
    <style>
        body {
            margin: 0;
            padding: 0;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        }
        .container {
            text-align: center;
            padding: 40px;
            background: white;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            max-width: 500px;
        }
        h1 { color: #333; margin: 0 0 20px 0; font-size: 28px; }
        p { color: #666; line-height: 1.6; font-size: 16px; margin: 15px 0; }
        .spinner {
            width: 50px;
            height: 50px;
            margin: 30px auto;
            border: 5px solid #f3f3f3;
            border-top: 5px solid #667eea;
            border-radius: 50%;
            animation: spin 1s linear infinite;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        .reload-btn {
            margin-top: 30px;
            padding: 12px 30px;
            background: #667eea;
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            cursor: pointer;
            transition: background 0.3s;
        }
        .reload-btn:hover { background: #5568d3; }
    </style>
    <script>
        setTimeout(function() { location.reload(); }, 5000);
    </script>
</head>
<body>
    <div class="container">
        <div class="spinner"></div>
        <h1>🎬 Video Processing</h1>
        <p>Your recording is being uploaded...</p>
        <p><strong>This page will auto-refresh</strong> when the video is ready.</p>
        <p style="font-size: 14px; color: #999;">Or click the button below to reload manually.</p>
        <button class="reload-btn" onclick="location.reload()">Reload Now</button>
    </div>
</body>
</html>]]
end

-- ============================================================
-- GCS Upload pipeline
-- ============================================================

local function uploadPlaceholder(fileName)
    if gcsBucket == "" then
        print("obs-loom: No GCS bucket configured, skipping placeholder")
        return
    end

    local baseName = fileName:match("(.+)%.mp4$") or fileName
    local gcsPath = baseName .. ".mp4"
    local publicUrl = string.format("https://storage.googleapis.com/%s/%s", gcsBucket, gcsPath)

    print("obs-loom: Uploading placeholder for " .. gcsPath)

    -- Write placeholder HTML to temp file
    local placeholderFile = watchDirectory .. "/.obs-loom-placeholder.html"
    local ph = io.open(placeholderFile, "w")
    if ph then
        ph:write(generatePlaceholderHTML())
        ph:close()

        local placeholderCmd = string.format(
            "%s -h 'Content-Type:text/html' -h 'Cache-Control:no-cache, no-store, must-revalidate' cp '%s' 'gs://%s/%s' && %s acl ch -u AllUsers:R 'gs://%s/%s'",
            gsutilPath, placeholderFile, gcsBucket, gcsPath,
            gsutilPath, gcsBucket, gcsPath
        )

        hs.task.new("/bin/sh", function(exitCode, stdout, stderr)
            if exitCode == 0 then
                hs.pasteboard.setContents(publicUrl)
                hs.alert.show("🔗 URL copied to clipboard!")
                print("obs-loom: ✅ Placeholder uploaded, URL in clipboard: " .. publicUrl)
            else
                print("obs-loom: ❌ Placeholder upload failed: " .. tostring(stderr))
            end
            os.remove(placeholderFile)
        end, {"-c", placeholderCmd}):start()
    end
end

local function uploadRealVideo(filePath, fileName)
    if gcsBucket == "" then
        print("obs-loom: No GCS bucket configured, skipping upload")
        return
    end

    local baseName = fileName:match("(.+)%.mp4$") or fileName
    local gcsPath = baseName .. ".mp4"

    print("obs-loom: Uploading real video: " .. filePath .. " → gs://" .. gcsBucket .. "/" .. gcsPath)
    obsLoom.isUploading = true
    obsLoom.updateMenuBar()

    -- Delete placeholder, upload real video, set ACL
    local uploadCmd = string.format(
        "%s rm 'gs://%s/%s' 2>&1 || echo 'No placeholder to delete'; " ..
        "%s -h 'Content-Type:video/mp4' -h 'Cache-Control:no-cache, no-store, must-revalidate' cp '%s' 'gs://%s/%s' && " ..
        "%s acl ch -u AllUsers:R 'gs://%s/%s'",
        gsutilPath, gcsBucket, gcsPath,
        gsutilPath, filePath, gcsBucket, gcsPath,
        gsutilPath, gcsBucket, gcsPath
    )

    hs.task.new("/bin/sh", function(exitCode, stdout, stderr)
        obsLoom.isUploading = false
        if exitCode == 0 then
            hs.alert.show("✅ Video uploaded!")
            print("obs-loom: ✅ Real video uploaded successfully")
        else
            hs.alert.show("❌ Upload failed")
            print("obs-loom: ❌ Upload failed: " .. tostring(stderr))
        end
        obsLoom.updateMenuBar()
    end, {"-c", uploadCmd}):start()
end

-- ============================================================
-- File watching + size polling
-- ============================================================

local function getFileSize(path)
    local output = hs.execute("stat -f '%z' '" .. path .. "' 2>/dev/null")
    if output then
        return tonumber(output:trim())
    end
    return nil
end

local function scanExistingFiles()
    obsLoom.knownFiles = {}
    local output = hs.execute("ls -1 '" .. watchDirectory .. "'/*.mp4 2>/dev/null")
    if output then
        for line in output:gmatch("[^\r\n]+") do
            local fileName = line:match("([^/]+)$")
            if fileName then
                obsLoom.knownFiles[fileName] = true
            end
        end
    end
    print("obs-loom: Scanned " .. (function()
        local count = 0
        for _ in pairs(obsLoom.knownFiles) do count = count + 1 end
        return count
    end)() .. " existing .mp4 files")
end

local function onNewFileDetected(filePath, fileName)
    print("obs-loom: 🆕 New recording detected: " .. fileName)

    obsLoom.activeFile = filePath
    obsLoom.lastSize = -1
    local stableCount = 0

    -- Upload placeholder immediately
    uploadPlaceholder(fileName)

    -- Start source capture if enabled (pass the recording filename)
    obsLoom.startSourceCapture(fileName)

    obsLoom.updateMenuBar()

    -- Start polling file size
    if obsLoom.pollTimer then
        obsLoom.pollTimer:stop()
    end

    obsLoom.pollTimer = hs.timer.doEvery(POLL_INTERVAL, function()
        local currentSize = getFileSize(filePath)
        if not currentSize then
            -- File might have been moved/deleted
            print("obs-loom: File no longer accessible, stopping poll")
            obsLoom.pollTimer:stop()
            obsLoom.pollTimer = nil
            obsLoom.activeFile = nil
            obsLoom.stopSourceCapture()
            obsLoom.updateMenuBar()
            return
        end

        if currentSize == obsLoom.lastSize then
            stableCount = stableCount + 1
            if stableCount >= STABILITY_THRESHOLD then
                -- File is stable — recording is done
                print("obs-loom: ✅ File stable at " .. currentSize .. " bytes — recording complete")
                obsLoom.pollTimer:stop()
                obsLoom.pollTimer = nil

                -- Stop source capture
                obsLoom.stopSourceCapture()

                -- Upload real video
                hs.alert.show("⬆️ Uploading video...")
                uploadRealVideo(filePath, fileName)

                obsLoom.activeFile = nil
                obsLoom.updateMenuBar()
            end
        else
            stableCount = 0
            obsLoom.lastSize = currentSize
        end
    end)
end

local function onPathChanged(paths, flagTables)
    for i, path in ipairs(paths) do
        -- Only care about .mp4 files
        if path:match("%.mp4$") then
            local fileName = path:match("([^/]+)$")
            if fileName and not obsLoom.knownFiles[fileName] and not obsLoom.activeFile then
                -- Check file actually exists (not a delete event)
                local exists = hs.execute("test -f '" .. path .. "' && echo 'yes' || echo 'no'")
                if exists and exists:trim() == "yes" then
                    obsLoom.knownFiles[fileName] = true
                    onNewFileDetected(path, fileName)
                end
            end
        end
    end
end

function obsLoom.startWatcher()
    if obsLoom.watcher then
        obsLoom.watcher:stop()
    end

    -- Ensure watch directory exists
    os.execute("mkdir -p '" .. watchDirectory .. "'")

    -- Scan existing files so we don't re-process them
    scanExistingFiles()

    obsLoom.watcher = hs.pathwatcher.new(watchDirectory, onPathChanged)
    obsLoom.watcher:start()
    print("obs-loom: 👁️ Watching: " .. watchDirectory)
end

function obsLoom.stopWatcher()
    if obsLoom.watcher then
        obsLoom.watcher:stop()
        obsLoom.watcher = nil
    end
    if obsLoom.pollTimer then
        obsLoom.pollTimer:stop()
        obsLoom.pollTimer = nil
    end
    print("obs-loom: Watcher stopped")
end

function obsLoom.restartWatcher()
    obsLoom.stopWatcher()
    obsLoom.startWatcher()
    hs.alert.show("🔄 Watcher restarted")
    obsLoom.updateMenuBar()
end

-- ============================================================
-- Menu bar
-- ============================================================

function obsLoom.updateMenuBar()
    local menuItems = {}

    -- Status
    local status = "👁️ Watching"
    if obsLoom.isUploading then
        status = "⬆️ Uploading..."
    elseif obsLoom.activeFile then
        status = "⏺️ Recording detected"
    elseif not obsLoom.watcher then
        status = "⏸️ Stopped"
    end

    table.insert(menuItems, {
        title = status,
        disabled = true
    })

    table.insert(menuItems, {title = "-"})

    -- Watch directory
    table.insert(menuItems, {
        title = "📂 Watch Directory: " .. watchDirectory,
        fn = function()
            local button, text = hs.dialog.textPrompt(
                "Watch Directory",
                "Enter the directory where OBS saves recordings:",
                watchDirectory,
                "OK",
                "Cancel"
            )
            if button == "OK" and text then
                watchDirectory = text:trim()
                -- Expand ~ if present
                if watchDirectory:sub(1, 1) == "~" then
                    watchDirectory = os.getenv("HOME") .. watchDirectory:sub(2)
                end
                saveConfig()
                obsLoom.restartWatcher()
            end
        end
    })

    -- GCS bucket
    table.insert(menuItems, {
        title = "☁️ GCS Bucket: " .. (gcsBucket ~= "" and gcsBucket or "Not configured"),
        fn = function()
            local button, text = hs.dialog.textPrompt(
                "Google Cloud Storage Bucket",
                "Enter your GCS bucket name:",
                gcsBucket,
                "OK",
                "Cancel"
            )
            if button == "OK" and text then
                gcsBucket = text:trim()
                saveConfig()
                obsLoom.updateMenuBar()
            end
        end
    })

    table.insert(menuItems, {title = "-"})

    -- Source capture toggle
    table.insert(menuItems, {
        title = (sourceCaptureEnabled and "✓" or "  ") .. " 📹 Source Capture",
        fn = function()
            sourceCaptureEnabled = not sourceCaptureEnabled
            saveConfig()
            obsLoom.updateMenuBar()
            if sourceCaptureEnabled then
                hs.alert.show("📹 Source capture enabled")
            else
                hs.alert.show("📹 Source capture disabled")
            end
        end
    })

    -- Source capture settings (only shown when enabled)
    if sourceCaptureEnabled then
        -- Source output directory
        table.insert(menuItems, {
            title = "   📂 Source Output: " .. sourceOutputDirectory,
            fn = function()
                local button, text = hs.dialog.textPrompt(
                    "Source Output Directory",
                    "Enter where source files (screen, webcam, audio) should be saved:",
                    sourceOutputDirectory,
                    "OK",
                    "Cancel"
                )
                if button == "OK" and text then
                    sourceOutputDirectory = text:trim()
                    if sourceOutputDirectory:sub(1, 1) == "~" then
                        sourceOutputDirectory = os.getenv("HOME") .. sourceOutputDirectory:sub(2)
                    end
                    os.execute("mkdir -p '" .. sourceOutputDirectory .. "'")
                    saveConfig()
                    obsLoom.updateMenuBar()
                end
            end
        })

        -- Screen selection
        local screenMenu = {}
        for _, screen in ipairs(availableScreens) do
            local isSelected = screen.id == selectedScreenId
            table.insert(screenMenu, {
                title = (isSelected and "✓ " or "   ") .. screen.name,
                fn = function()
                    selectedScreenId = screen.id
                    currentScreenName = screen.name
                    saveConfig()
                    obsLoom.updateMenuBar()
                end
            })
        end
        table.insert(menuItems, {
            title = "   📺 Screen: " .. currentScreenName,
            menu = screenMenu
        })

        -- Camera selection
        local cameraMenu = {}
        -- Add "No Camera" option
        table.insert(cameraMenu, {
            title = (selectedCameraDevice == nil and "✓ " or "   ") .. "No Camera",
            fn = function()
                selectedCameraDevice = nil
                currentCameraName = "No Camera"
                saveConfig()
                obsLoom.updateMenuBar()
            end
        })
        for _, camera in ipairs(availableCameras) do
            if camera.index ~= nil then
                local isSelected = camera.index == selectedCameraDevice
                table.insert(cameraMenu, {
                    title = (isSelected and "✓ " or "   ") .. camera.name,
                    fn = function()
                        selectedCameraDevice = camera.index
                        currentCameraName = camera.name
                        saveConfig()
                        obsLoom.updateMenuBar()
                    end
                })
            end
        end
        table.insert(menuItems, {
            title = "   📷 Camera: " .. currentCameraName,
            menu = cameraMenu
        })

        -- Audio device selection
        local audioMenu = {}
        for _, audio in ipairs(availableAudioDevices) do
            local isSelected = (":" .. audio.index) == selectedAudioDevice
            table.insert(audioMenu, {
                title = (isSelected and "✓ " or "   ") .. audio.name,
                fn = function()
                    selectedAudioDevice = ":" .. audio.index
                    currentAudioName = audio.name
                    saveConfig()
                    obsLoom.updateMenuBar()
                end
            })
        end
        table.insert(menuItems, {
            title = "   🎤 Audio: " .. currentAudioName,
            menu = audioMenu
        })
    end

    table.insert(menuItems, {title = "-"})

    -- Open folders
    table.insert(menuItems, {
        title = "📁 Open Watch Directory",
        fn = function()
            os.execute("open '" .. watchDirectory .. "'")
        end
    })

    if sourceCaptureEnabled then
        table.insert(menuItems, {
            title = "📁 Open Source Files",
            fn = function()
                os.execute("mkdir -p '" .. sourceOutputDirectory .. "'")
                os.execute("open '" .. sourceOutputDirectory .. "'")
            end
        })
    end

    -- Refresh devices
    table.insert(menuItems, {
        title = "🔄 Refresh Devices",
        fn = function()
            obsLoom.enumerateScreens()
            obsLoom.enumerateCameras()
            obsLoom.enumerateAudioDevices()
            updateScreenName()
            obsLoom.updateMenuBar()
            hs.alert.show("Devices refreshed")
        end
    })

    -- Restart watcher
    table.insert(menuItems, {
        title = "🔄 Restart Watcher",
        fn = function()
            obsLoom.restartWatcher()
        end
    })

    menuBar:setMenu(menuItems)
end

-- ============================================================
-- Initialization
-- ============================================================

function obsLoom.init()
    -- Ensure directories exist
    os.execute("mkdir -p '" .. watchDirectory .. "'")

    -- Load saved configuration
    loadConfig()

    -- Ensure directories exist after config load
    os.execute("mkdir -p '" .. watchDirectory .. "'")
    if sourceCaptureEnabled then
        os.execute("mkdir -p '" .. sourceOutputDirectory .. "'")
    end

    -- Enumerate devices
    obsLoom.enumerateScreens()
    obsLoom.enumerateCameras()
    obsLoom.enumerateAudioDevices()
    updateScreenName()

    -- Create menu bar
    menuBar = hs.menubar.new()
    menuBar:setTitle("🎬")
    menuBar:setTooltip("obs-loom")

    obsLoom.updateMenuBar()

    -- Start watching
    obsLoom.startWatcher()

    print("obs-loom: Loaded successfully")
    print("obs-loom: Watching: " .. watchDirectory)
    print("obs-loom: GCS bucket: " .. (gcsBucket ~= "" and gcsBucket or "not configured"))
    print("obs-loom: Source capture: " .. (sourceCaptureEnabled and "enabled" or "disabled"))
end

-- Start
obsLoom.init()

return obsLoom
