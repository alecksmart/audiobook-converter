# ab.sh

A Bash script to concatenate audio files into `.m4b` audiobooks with chapters, automatically splitting into parts no longer than 12 hours.

This README covers the new `--dry-run` mode and validation pass added in recent updates.

## Features

- Scans a directory for audio files (`mp3`, `wav`, `flac`)
- Validates each file can be read by `ffprobe`
- Calculates the duration of each file with `ffprobe`
- Splits into parts so that no part exceeds 12 hours
- Generates chapter metadata from existing tags (or filenames)
- Encodes output as `.m4b` (AAC) with selectable sample rate and bitrate
- Prompts interactively for author/artist and title metadata
- **Dry-run mode** to preview all actions without creating or modifying files

## Requirements

- [bash](https://www.gnu.org/software/bash/)
- [ffmpeg](https://ffmpeg.org/) (includes `ffprobe`)
- [ffprobe](https://ffmpeg.org/ffprobe.html)

## Installation

```bash
git clone https://github.com/<username>/<repository>.git
cd <repository>
chmod +x ab.sh
```

## Usage

```bash
./ab.sh [--dry-run|-n] <source_dir>
```

- `--dry-run`, `-n`: Preview actions (creating output directory, validating files, estimating splits) without writing any files
- `<source_dir>`: Directory containing your audio files

### Dry-run Example

```text
$ ./ab.sh --dry-run ~/audiobooks/source
Author/Artist name [default: source]: J. Doe
Title [default: source]: My Audiobook
[DRY-RUN] Would create output directory: ~/audiobooks/source/output
Found 10 files.
Validating input files with ffprobe...
[DRY-RUN] Validated: track01.mp3 (duration: 0 h: 5 m: 12 s)
... (other validations)
Estimated parts: 1
  Part 1 (0 h: 52 m: 30 s): files 0-9
[DRY-RUN] Completed. No files were created.
```

### Normal Run Example

```text
$ ./ab.sh ~/audiobooks/source
Author/Artist name [default: source]: J. Doe
Title [default: source]: My Audiobook
Found 10 files.
Estimated parts: 1
Per-part durations:
  Part 1: 0 h: 52 m: 30 s
Detected sample rates: 44100
Detected bitrates: 128 kbps
Choose output format (no upscaling beyond inputs):
  1) 48000 Hz @ 128k
  2) 48000 Hz @ 64k
  3) 44100 Hz @ 128k
  4) 44100 Hz @ 64k
Enter choice [1-4]: 3
Selected: 44100 Hz @ 128k
-- Creating Part 1 (0 h: 52 m: 30 s) --
  track01.mp3
  ...
Creating: ~/audiobooks/source/output/J. Doe — My Audiobook.m4b
Done. Outputs in ~/audiobooks/source/output
```

## Configuration

- **MAX_DURATION**: Maximum part length in seconds (default is 12 hours). Edit the `MAX_DURATION` variable at the top of `ab.sh` to change this.

## Contributing

Pull requests and issues are welcome! Please open an issue first to discuss major changes.

## License

This project is released under the [MIT License](LICENSE).


