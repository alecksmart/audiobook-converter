# ab.sh

A simple Bash script to concatenate audio files into `.m4b` audiobooks with chapters, automatically splitting parts at a maximum duration (12 hours by default), and displaying real-time encoding progress using `pv`.

## Features

- Scans a source directory for MP3, WAV, FLAC, and M4A audio files
- Validates input files and computes durations via `ffprobe`
- Splits into multiple parts if total duration exceeds 12 hours
- Prompts for Author/Artist and Title metadata
- Encodes raw AAC with live progress bar (via `pv`)
- Packages into `.m4b` with chapters using `ffmpeg` metadata
- Supports `--dry-run` mode to preview actions

## Requirements

- **bash**
- **ffprobe** (from FFmpeg)
- **ffmpeg** (with `libfdk_aac` for highest quality)
- **pv** (Pipe Viewer)

### Install Dependencies

#### macOS (Homebrew)
```bash
brew update
brew install ffmpeg pv
```

#### Debian / Ubuntu
```bash
sudo apt update
sudo apt install ffmpeg pv
```

#### Fedora
```bash
sudo dnf install ffmpeg pv
```

#### Arch Linux
```bash
sudo pacman -S ffmpeg pv
```

#### Windows (using Chocolatey)
```powershell
choco install ffmpeg pv
```

## Usage

```bash
./ab.sh [--dry-run] <source_dir>
```

- `--dry-run`, `-n`  Show the steps without creating any files
- `<source_dir>`    Directory containing audio files to process

### Example

```bash
./ab.sh "AudioBookDir"
```

You will be prompted to enter the Author/Artist name and Title (defaults derived from the directory name if left blank).

Outputs are placed in the `output/` subdirectory under your source directory.

## License

MIT © alecksmart