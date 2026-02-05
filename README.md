# ab.sh

A robust Bash script to concatenate audio files into `.m4b` audiobooks with chapters, automatically splitting parts at a maximum duration (12 hours by default), with real-time encoding progress and comprehensive error handling.

## Features

### Core Functionality

- Scans a source directory for MP3, WAV, FLAC, M4A, and Opus audio files
- Validates input files and computes durations via `ffprobe`
- Detects and corrects corrupt bitrate metadata using median bitrate analysis
- Automatically splits into multiple parts if total duration exceeds 12 hours
- Handles oversized files (>12h) by placing them in dedicated parts
- Encodes to AAC using libfdk_aac with automatic VBR quality selection
- Real-time encoding progress display via FFmpeg
- Packages into `.m4b` with embedded chapters, metadata, and optional cover art
- Optional narrator metadata field
- Output verification to ensure encoded duration matches expected length (with small tolerance)
- `--validate` mode to check inputs before encoding
- Dry-run summary with estimated output sizes

### Robustness & Security

- Validates `libfdk_aac` encoder availability at startup
- Path traversal protection for input files
- Secure temporary file creation with automatic cleanup
- Output directory write permission validation
- Output file integrity verification (existence, size, format validity)
- Enhanced error context when ffprobe fails
- Metadata sanitization to prevent FFMETADATA format breaking

### User Experience

- Interactive prompts for Author/Artist and Title metadata
- `--yes` flag to skip prompts for automation
- `--dry-run` mode to preview actions without encoding
- `--help` and `--version` flags for quick reference
- Progress capping to handle corrupt input timestamps

## Requirements

- **bash** 3.2+ (macOS default supported, with pipefail support)
- **ffprobe** (from FFmpeg)
- **ffmpeg** (with `libfdk_aac` for highest quality AAC encoding)

### Install Dependencies

#### macOS (Homebrew)

```bash
brew update
brew install ffmpeg
```

**Note:** Ensure FFmpeg is compiled with `libfdk_aac` support. If not, reinstall with:

```bash
brew reinstall ffmpeg
```

#### Debian / Ubuntu

```bash
sudo apt update
sudo apt install ffmpeg
```

#### Fedora

```bash
sudo dnf install ffmpeg
```

#### Arch Linux

```bash
sudo pacman -S ffmpeg
```

#### Windows (using Chocolatey)

```powershell
choco install ffmpeg
```

## Usage

```bash
./ab.sh [OPTIONS] <source_dir>
```

### Options

- `--dry-run`, `-n`  Show actions without creating any files
- `--validate`       Validate inputs and exit without encoding
- `--self-test`      Run dependency checks and exit
- `--yes`, `-y`      Skip interactive prompts (use defaults for automation)
- `--verbose`        More detailed logging
- `--quiet`          Minimal output (errors only)
- `--help`, `-h`     Show help message
- `--version`, `-v`  Show version information
- `<source_dir>`     Directory containing audio files to process

### Examples

**Basic usage with interactive prompts:**

```bash
./ab.sh "AudioBookDir"
```

**Automated mode (no prompts):**

```bash
./ab.sh --yes "AudioBookDir"
```

**Preview mode (dry-run):**

```bash
./ab.sh --dry-run "AudioBookDir"
```

**Automated dry-run:**

```bash
./ab.sh --yes --dry-run "AudioBookDir"
```

You will be prompted to enter the Author/Artist name and Title (unless `--yes` is used, which defaults to the directory name).

Outputs are placed in the `output/` subdirectory under your source directory.

If `cover.jpg`, `cover.jpeg`, or `cover.png` exists in the source directory, it is embedded as the audiobook cover art.

## Install / Link into PATH

If `ab.sh` is on your `$PATH`, you can manage a symlink with the provided Makefile (default install dir: `~/bin`):

```bash
make link
make unlink
make relink
make deps
```

To override install location:

```bash
make link PREFIX=/custom/prefix
```

## ToDo

Nothing at the moment

## License

MIT © alecksmart
