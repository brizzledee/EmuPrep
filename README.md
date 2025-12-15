# EmuPrep: The Ultimate Multi-Disc Game Preparation Pipeline

A highly resilient Bash pipeline to automate multi-disc retro game conversion (CUE/BIN $\rightarrow$ CHD) and organization for clean front-end display (M3U).

## The Problem EmuPrep Solves

Manual setup leads to wasted space and emulation front-end clutter.

**EmuPrep** solves this by converting to highly compressed CHD, generating a single M3U entry, and crucially, hiding all the disc files in a dot-prefixed subdirectory.

**Before EmuPrep:**

```
/psx/
├── Final Fantasy VII (USA).zip
├── Xenogears (USA) Disc 1.cue
├── Xenogears (USA) Disc 2.bin
└── Metal Gear Solid Disc 1.bin
```

**After EmuPrep:**

```
/psx/
├── Final_Fantasy_VII.m3u
├── Xenogears.m3u
├── Metal_Gear_Solid.m3u
├── .Final_Fantasy_VII/  <-- Hidden CHD files are here
├── .Xenogears/
├── .Metal_Gear_Solid/
└── Trash/               <-- All original ZIPs, CUEs, BINs moved here
```

## Installation & Setup

To get the script, you will use `curl` to download the raw file, set the execute permission, and then run it directly.

> **Note:** We recommend placing the script in a directory you intend to process, or in a directory that is already in your `$PATH` (like `~/bin/`) if you want to run it globally.

### Step 1: Download the Script

```bash
curl -sSL https://raw.githubusercontent.com/brizzledee/emuprep/main/emuprep.sh -o emuprep
```

### Step 2: Set Execute Permission

```bash
chmod +x emuprep
```

### Step 3: Run the Script

You can now run the script from your terminal:

```bash
# Run in the current directory (default behavior)
./emuprep

# OR, run against a specific path
./emuprep /path/to/your/roms/
```

### Prerequisites

You must have the following tools installed and accessible in your system's `$PATH`:

  * `chdman` (from the MAME project, used for compression)
  * `7z` (p7zip or p7zip-full, used for 7z archives)
  * `unrar` (often available as `unrar` or `rar`)
  * Standard Linux tools (`find`, `tar`, `unzip`, `bash` 4.0+)

## Usage

**EmuPrep** is designed for maximum flexibility. If no path arguments are provided, **it defaults to processing the current directory (`.`)**. You can also specify an unlimited number of paths.

| Command | Description |
| :--- | :--- |
| `emuprep` | **Process the current directory (`.`)** |
| `emuprep /path/to/psx` | Process a single, specific directory. |
| `emuprep /path/to/psx /path/to/saturn` | Process multiple directories in sequence. |

### Optional Flags

| Flag | Description |
| :--- | :--- |
| `--dry-run` | **Highly Recommended\!** Prevents any files from being moved, deleted, or converted. It only prints the commands that *would* be executed. |
| `--auto-clean` | Enables the removal of the final `Trash/` folder. By default, this will ask for confirmation (`y/N`). |
| `--yes` or `--force` | Forces the `--auto-clean` process to proceed without asking for confirmation. |

-----

## The EmuPrep 4-Phase Pipeline

The `emuprep` script runs four highly resilient phases in order:

1.  **Bulk Extraction & Aggregation:** Extracts all archive formats (`.zip`, `.7z`, etc.), flattens deep directory structures, and moves original archives to **`Trash/`**.
2.  **Batch CHD Conversion:** Converts all discovered CUE/BIN sets to compressed `.chd` files using `chdman`. It logs errors but continues to the next game on failure.
3.  **M3U Playlist Organization:** Groups multi-disc CHDs, moves them to a hidden subdirectory (e.g., `.Final_Fantasy_VII/`), and creates the single M3U playlist pointing to the new location.
4.  **Final Inventory and Reporting:** Generates a timestamped `game_inventory.txt` file listing every successfully processed game and reports any warnings/errors to the console and the timestamped log file.

## Safety and Troubleshooting

  * **Trash Folder:** All original and temporary files are moved to a `Trash/` subdirectory, never permanently deleted, unless you use the `--auto-clean` flag.
  * **Logging:** A timestamped log file (`emuprep_YYYYMMDD_HHMMSS.log`) is created for every run, detailing every extraction, conversion, and file move for full auditability.

## License

This project is licensed under the **MIT License**.
