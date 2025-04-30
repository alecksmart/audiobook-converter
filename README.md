# ab.sh

A simple Bash script to concatenate audio files into `.m4b` audiobooks with chapters, automatically splitting parts at a maximum duration (12 hours by default), and displaying real-time encoding progress using `pv`.

## Features

- Scans a source directory for MP3, WAV, and FLAC audio files
- Validates input files and computes durations via `ffprobe`
- Splits into multiple parts if total duration exceeds 12 hours
- Prompts for Author/Artist and Title metadata
- Encodes raw AAC with live progress bar (via `pv`)
- Packages into `.m4b` with chapters using `MP4Box` (GPAC)
- Supports `--dry-run` mode to preview actions

## Requirements

- **bash**
- **ffprobe** (from FFmpeg)
- **ffmpeg**
- **pv** (Pipe Viewer)
- **MP4Box** (part of GPAC)

### Install Dependencies

#### macOS (Homebrew)
```bash
brew update
brew install ffmpeg pv gpac
```

#### Debian / Ubuntu
```bash
sudo apt update
sudo apt install ffmpeg pv gpac
```

#### Fedora
```bash
sudo dnf install ffmpeg pv gpac
```

#### Arch Linux
```bash
sudo pacman -S ffmpeg pv gpac
```

#### Windows (using Chocolatey)
```powershell
choco install ffmpeg pv gpac
```

## Usage

```bash
./ab.sh [--dry-run] <source_dir>
```

- `--dry-run`, `-n`  Show the steps without creating any files
- `<source_dir>`    Directory containing audio files to process

### Example

```bash
./ab.sh "MyAudioCollection"
```

You will be prompted to enter the Author/Artist name and Title (defaults derived from the directory name if left blank).

Outputs are placed in `output/` subdirectory under your source directory.

## License

MIT © alecksmart


