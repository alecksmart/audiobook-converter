# ab.sh

A Bash script to concatenate audio files into `.m4b` audiobooks with chapters, automatically splitting into parts no longer than 12 hours.

## Features

- Scans a directory for audio files (`mp3`, `wav`, `flac`)
- Calculates the duration of each file with `ffprobe`
- Splits into parts so that no part exceeds 12 hours
- Generates chapter metadata from existing tags (or filenames)
- Encodes output as `.m4b` (AAC) with selectable sample rate and bitrate
- Prompts interactively for author/artist and title metadata

## Requirements

- [bash](https://www.gnu.org/software/bash/)
- [ffmpeg](https://ffmpeg.org/) (includes `ffprobe`)
- [ffprobe](https://ffmpeg.org/ffprobe.html)

## Installation

```bash
git clone https://github.com/alecksmart/audiobook-converter
cd audiobook-converter
chmod +x ab.sh
```

## Usage

```bash
./ab.sh <source_dir>
```

- `<source_dir>`: directory containing your audio files.
- The script creates an `output/` subdirectory in `<source_dir>` and writes one or more `.m4b` parts there.

```text
$ ./ab.sh ~/audiobooks/source
Author/Artist name [default: source]: J. Doe
Title [default: source]: My Audiobook
Found 10 files.
Estimated parts: 1
Per-part durations:
  Part 1: 4 h: 30 m: 0 s
Detected sample rates: 44100
Detected bitrates: 128 kbps
Choose output format (no upscaling beyond inputs):
  1) 48000 Hz @ 128k
  2) 48000 Hz @ 64k
  3) 44100 Hz @ 128k
  4) 44100 Hz @ 64k
Enter choice [1-4]: 3
Selected: 44100 Hz @ 128k
-- Creating Part 1 (4 h: 30 m: 0 s) --
  track1.mp3
  track2.mp3
Creating: ~/audiobooks/source/output/J. Doe — My Audiobook — Part 1.m4b
Done. Outputs in ~/audiobooks/source/output
```

## Configuration

- **MAX_DURATION**: maximum part length in seconds (default is 12 hours).
  You can edit the `MAX_DURATION` variable at the top of the script to change this.

## Contributing

Pull requests and issues are welcome! Please open an issue first to discuss major changes.

## License

This project is released under the [MIT License](LICENSE).
```
