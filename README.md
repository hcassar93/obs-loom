# obs-loom

An OBS recording watcher for macOS built with Hammerspoon. Automatically uploads OBS recordings to Google Cloud Storage with instant shareable URLs. Optionally captures raw source files (screen, webcam, audio) for post-production editing.

## Features

- 👁️ **Watch Directory**: Monitors a folder for new OBS recordings
- 🚀 **Instant URLs**: Get a shareable link the moment OBS starts recording (HTML placeholder while processing)
- ⬆️ **Auto-upload to GCS**: Automatically upload finished recordings to your Google Cloud Storage bucket
- 🔗 **Public URLs**: Shareable links anyone can access (no login required)
- 📹 **Source Capture** (optional): Independently record screen, webcam, and audio while OBS records
- 🎛️ **Menu Bar Interface**: All settings accessible from the menu bar
- 📺 **Device Selection**: Choose screen, camera, and microphone for source capture

## How It Works

1. **OBS records** → saves `.mp4` to the watch directory
2. **obs-loom detects** the new file immediately
3. **Placeholder uploaded** → HTML loading page uploaded to GCS, URL copied to clipboard
4. **Share instantly** → paste the URL anywhere, viewers see "processing..." page
5. **Recording finishes** → obs-loom detects file has stopped growing
6. **Real video uploaded** → replaces the placeholder, viewers see the video

### Source Capture (Optional)

When enabled, obs-loom also captures raw source files alongside OBS:
- `screen.mp4` — raw screen recording (FFmpeg)
- `webcam.mp4` — raw webcam recording (FFmpeg)
- `audio.wav` — raw audio recording (sox, Core Audio for quality)

These stay local for post-production editing — only the OBS composite is uploaded to GCS.

## Quick Start

### 1. Install Dependencies

```bash
# Install Hammerspoon
brew install --cask hammerspoon

# Install Google Cloud SDK (for uploads)
brew install --cask google-cloud-sdk

# Optional: For source capture feature
brew install ffmpeg
brew install sox
```

### 2. Set Up obs-loom

```bash
cd ~/Code
git clone <repository-url> obs-loom
```

Add to `~/.hammerspoon/init.lua`:
```lua
dofile(os.getenv("HOME") .. "/Code/obs-loom/init.lua")
```

Reload Hammerspoon: Menu bar → Hammerspoon → Reload Config

### 3. Configure

In menu bar: 🎬 → "☁️ GCS Bucket" → Enter your bucket name
In menu bar: 🎬 → "📂 Watch Directory" → Set to your OBS recording output folder

### 4. Configure OBS

Set OBS recording output to your watch directory:
- OBS → Settings → Output → Recording Path → Set to your watch directory
- OBS → Settings → Output → Recording Format → MP4

### 5. Set Up GCS (if not already done)

```bash
# Authenticate
gcloud auth login

# Create bucket
gsutil mb -l us-central1 gs://your-recordings

# Make bucket public for easy sharing
gsutil iam ch allUsers:objectViewer gs://your-recordings
```

## Usage

### Basic Workflow

1. Set your watch directory and GCS bucket in the menu bar
2. Start recording in OBS
3. obs-loom detects the new file and uploads a placeholder → URL in clipboard
4. Stop recording in OBS
5. obs-loom uploads the real video, replacing the placeholder

### Menu Bar (🎬)

- **Status**: Shows current state (Watching / Recording detected / Uploading)
- **📂 Watch Directory**: Set where OBS saves recordings
- **☁️ GCS Bucket**: Set your GCS bucket name
- **📹 Source Capture**: Toggle raw source file capture on/off
  - **📂 Source Output**: Where source files are saved
  - **📺 Screen**: Select which display to capture
  - **📷 Camera**: Select webcam (or "No Camera")
  - **🎤 Audio**: Select microphone
- **📁 Open Watch Directory**: Open in Finder
- **📁 Open Source Files**: Open source output in Finder
- **🔄 Refresh Devices**: Re-scan screens, cameras, mics
- **🔄 Restart Watcher**: Restart the file watcher

### Source Capture

When source capture is enabled:
- Raw screen, webcam, and audio are captured **automatically** when OBS starts recording
- Captures stop automatically when OBS finishes
- Files saved to a timestamped subfolder in the source output directory:
  ```
  ~/OBSSourceFiles/sources_2026-02-13_14-30-25/
  ├── screen.mp4
  ├── webcam.mp4
  └── audio.wav
  ```

## Requirements

- macOS 12.0+
- [Hammerspoon](https://www.hammerspoon.org/)
- [Google Cloud SDK](https://cloud.google.com/sdk/) (`brew install --cask google-cloud-sdk`) — for uploads
- [OBS Studio](https://obsproject.com/) — for recording
- FFmpeg (`brew install ffmpeg`) — only if using source capture
- sox (`brew install sox`) — only if using source capture

### Permissions (if using source capture)

- **System Settings → Privacy & Security → Screen Recording** → Enable Hammerspoon
- **System Settings → Privacy & Security → Camera** → Enable Hammerspoon
- **System Settings → Privacy & Security → Microphone** → Enable Hammerspoon

## Troubleshooting

### No Files Detected

- Verify OBS is saving to the watch directory configured in obs-loom
- Verify OBS output format is set to MP4
- Try "🔄 Restart Watcher" from the menu bar

### Upload Fails

```bash
# Authenticate with Google Cloud
gcloud auth login
gcloud config set project YOUR_PROJECT_ID

# Verify bucket exists
gsutil ls gs://your-bucket-name

# Test upload
echo "test" > test.txt
gsutil cp test.txt gs://your-bucket-name/
```

### Source Capture Not Working

- Ensure FFmpeg and sox are installed: `which ffmpeg && which rec`
- Grant Hammerspoon permissions for Screen Recording, Camera, Microphone
- Check Hammerspoon Console for error messages

## Privacy & Security

- All recordings stored locally first
- GCS upload requires your own bucket
- Public URLs are optional (depends on bucket configuration)
- Source files never leave your machine

⚠️ **Warning**: If your bucket is public, anyone with the URL can view recordings.

## License

MIT License
