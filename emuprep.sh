#!/bin/bash

################################################################################
# EmuPrep Master Script
################################################################################
#
# DESCRIPTION:
#   A comprehensive automation tool for managing game ROM files and converting
#   disc-based games to CHD (Compressed Hunks of Data) format. This script
#   orchestrates three main stages:
#     1. Bulk extraction of game archives (zip, tar, 7z, rar, etc.)
#     2. Batch conversion of CUE/BIN files to CHD format using chdman
#     3. Organization of multi-disc CHD games into subdirectories with M3U playlists
#
#   The script is designed to be resilient, logging all operations to timestamped
#   files while continuing on non-fatal errors. It also generates a game inventory
#   file and supports running from any directory with a target path argument.
#
# USAGE:
#   ./emuprep.sh                    # Process current directory
#   ./emuprep.sh /path/to/games     # Process specified directory
#   ./emuprep.sh ~/Games/ROMs       # Process using relative paths
#
# OUTPUT FILES:
#   - emuprep_YYYYMMDD_HHMMSS.log  # Detailed execution log with timestamps
#   - game_inventory_YYYYMMDD_HHMMSS.txt  # List of all games and disc counts
#   - Trash/                        # Directory containing moved files
#   - .game_name/                   # Hidden directories for multi-disc games
#   - game_name.m3u                 # M3U playlists for multi-disc games
#
# DEPENDENCIES:
#   - bash 4.0+
#   - Standard tools: find, grep, sed, awk, tar, unzip, date
#   - 7z (for 7zip archives)
#   - unrar (for RAR archives)
#   - chdman (from MAME project, local or via Flatpak)
#
# ERROR HANDLING:
#   The script continues on non-fatal errors and logs them. Fatal errors only
#   occur for: invalid target directory, permission issues, or missing chdman
#   when .cue files are present.
#
################################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# Supports optional flags before the target directory:
#   --auto-clean      : remove the Trash folder at the end (interactive by default)
#   --yes             : non-interactive confirmation for auto-clean
# Any trailing positional argument is treated as the TARGET_DIR (defaults to .)
# ---------------------------------------------------------------------------
AUTO_CLEAN=0
AUTO_CLEAN_YES=0
DRY_RUN=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-clean)
            AUTO_CLEAN=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --yes|--force)
            AUTO_CLEAN=1
            AUTO_CLEAN_YES=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}"
TARGET_DIR="${1:-.}"

# Arrays to track warnings and errors encountered during execution
declare -a WARNINGS=()
declare -a ERRORS=()

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: Target directory '$TARGET_DIR' does not exist"
    exit 1
fi

# VALIDATION: Check directory permissions and availability
if [[ ! -r "$TARGET_DIR" ]]; then
    echo "Error: Target directory '$TARGET_DIR' is not readable"
    exit 1
fi

if [[ ! -w "$TARGET_DIR" ]]; then
    echo "Error: Target directory '$TARGET_DIR' is not writable"
    exit 1
fi

# VALIDATION: Resolve any symlinks to get the real path
TARGET_DIR=$(cd "$TARGET_DIR" && pwd -P)

# VALIDATION: Check available disk space (warn if less than 100MB)
AVAIL_SPACE=$(df "$TARGET_DIR" | awk 'NR==2 {print $4}')
if [[ $AVAIL_SPACE -lt 102400 ]]; then
    echo "Warning: Less than 100MB available disk space in target directory"
fi

# SETUP: Enter target directory and initialize logging
pushd "$TARGET_DIR" >/dev/null || (echo "Failed to enter target dir" && exit 1)

# LOGGING: Initialize timestamped log file for this execution
LOG_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="emuprep_${LOG_TIMESTAMP}.log"

# TRASH: central folder name used to hold files moved during processing
# (left for manual review; NOT auto-deleted)
TRASH_DIR="Trash"

# LOGGING FUNCTIONS: All messages are logged to file with timestamps and displayed on stdout
log_message() {
    local message="$1"
    local log_entry="[$(date '+%Y-%m-%d %H:%M:%S')] $message"
    echo "$log_entry" | tee -a "$LOG_FILE"
}

# Log warnings - tracked separately for summary report
log_warning() {
    local message="$1"
    local log_entry="[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: $message"
    echo "$log_entry" | tee -a "$LOG_FILE"
    WARNINGS+=("$message")
}

# Log errors - tracked separately for summary report
log_error() {
    local message="$1"
    local log_entry="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $message"
    echo "$log_entry" | tee -a "$LOG_FILE"
    ERRORS+=("$message")
}

# Handle fatal errors and exit gracefully
handle_error() {
    local message="$1"
    log_error "$message"
    exit 1
}

# Helper wrappers to centralize side-effecting operations and support dry-run
do_mkdir() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] mkdir -p $*"
    else
        mkdir -p "$@"
    fi
}

do_mv() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] mv $*"
    else
        mv -- "$@"
    fi
}

do_rm() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] rm $*"
    else
        rm -rf -- "$@"
    fi
}

do_rmdir() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] rmdir $*"
    else
        rmdir "$@" 2>/dev/null || true
    fi
}

do_chdman() {
    # Run chdman command (CHDC_EXE array) with provided args
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY-RUN] ${CHDC_EXE[*]} $*"
        return 0
    else
        "${CHDC_EXE[@]}" "$@"
        return $?
    fi
}

do_extract() {
    # $1 = archive file
    archive="$1"
    case "$archive" in
        *.zip)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY-RUN] unzip -q '$archive'"
            else
                unzip -q "$archive"
            fi
            ;;
        *.tar)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY-RUN] tar -xf '$archive'"
            else
                tar -xf "$archive"
            fi
            ;;
        *.tar.gz|*.tgz)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY-RUN] tar -xzf '$archive'"
            else
                tar -xzf "$archive"
            fi
            ;;
        *.tar.bz2)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY-RUN] tar -xjf '$archive'"
            else
                tar -xjf "$archive"
            fi
            ;;
        *.tar.xz)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY-RUN] tar -xJf '$archive'"
            else
                tar -xJf "$archive"
            fi
            ;;
        *.7z)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY-RUN] 7z x '$archive'"
            else
                7z x "$archive" > /dev/null 2>&1
            fi
            ;;
        *.rar)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY-RUN] unrar x '$archive'"
            else
                unrar x "$archive" > /dev/null 2>&1
            fi
            ;;
        *)
            if [ "$DRY_RUN" -eq 1 ]; then
                echo "[DRY-RUN] unknown-archive '$archive'"
            fi
            ;;
    esac
}

echo "=== EmuPrep Master Script ==="
echo "Processing: $TARGET_DIR"
echo ""

log_message "=== EmuPrep Master Script Started ==="
log_message "Processing: $TARGET_DIR"

# ============================================================================
# STAGE 1: BULK EXTRACTION AND AGGREGATION
# ============================================================================
# This stage:
#   1. Detects and extracts all archive files (zip, tar, 7z, rar, etc.)
#   2. Flattens directory structures by moving deeply nested files to root
#   3. Moves extracted archives and empty directories to Trash
# ============================================================================
log_message "[1/3] Starting bulk extraction and aggregation..."

# Check if any archive files exist before attempting extraction
if ! find . -maxdepth 1 \( -iname "*.zip" -o -iname "*.tar" -o -iname "*.tar.gz" -o -iname "*.tar.bz2" -o -iname "*.tar.xz" -o -iname "*.7z" -o -iname "*.rar" \) -print -quit | grep -q .; then
    log_message "No archive files found. Skipping bulk extraction."
else
    # EXTRACTION PHASE: Initialize trash directory and begin archive extraction
    TRASH_DIR="Trash"

    echo "Step 1: Extracting archives..."
for archive in *.zip *.tar *.tar.gz *.tar.bz2 *.tar.xz *.7z *.rar; do
    if [ -f "$archive" ]; then
        echo "  Extracting: $archive"
        do_extract "$archive"
    fi
done

echo "Step 2: Flattening directory structure..."
for dir in */; do
    # Skip if it's the Trash directory
    if [ "$dir" = "$TRASH_DIR/" ]; then
        continue
    fi

    # Count items in the directory
    item_count=$(find "$dir" -maxdepth 1 -not -name "." 2>/dev/null | wc -l)

    # If there's exactly one subdirectory and nothing else, flatten it
            if [ "$item_count" -eq 1 ] && [ -d "$dir"* ] 2>/dev/null; then
        subdirs=$(find "$dir" -maxdepth 1 -type d -not -name "." | wc -l)

        # If the only item is a single subdirectory, move its contents up
            if [ "$subdirs" -eq 2 ]; then
                subdir=$(find "$dir" -maxdepth 1 -type d -not -name ".")
                echo "  Flattening: $subdir"
                do_mv "$subdir"/* "$dir" || true
                do_rmdir "$subdir" || true
            fi
        fi
done

echo "Step 3: Moving empty directories and archives to Trash..."
mkdir -p "$TRASH_DIR"

# Move empty directories
while IFS= read -r -d $'\0' emptydir; do
    # skip Trash dir itself
    bn=$(basename "$emptydir")
    if [ "$bn" != "$TRASH_DIR" ]; then
        echo "  Moving to Trash: $emptydir"
        do_mv "$emptydir" "$TRASH_DIR/"
    fi
done < <(find . -maxdepth 1 -type d -empty -print0)

# Move archive files
for archive in *.zip *.tar *.tar.gz *.tar.bz2 *.tar.xz *.7z *.rar *.tgz; do
    if [ -f "$archive" ]; then
        echo "  Moving to Trash: $archive"
        do_mv "$archive" "$TRASH_DIR/"
    fi
done

    log_message "[1/3] Extraction complete"
fi
log_message ""

# ============================================================================
# STAGE 2: BATCH CHD CONVERSION
# ============================================================================
# This stage:
#   1. Detects CUE files (disc image descriptions)
#   2. Converts CUE/BIN disc images to CHD format using chdman
#   3. Deletes original CUE and BIN files after successful conversion
#   4. Moves deleted files to Trash for safety
# ============================================================================
log_message "[2/3] Starting CHD conversion..."

# Check if any .cue or .bin files exist
if ! find . -maxdepth 1 \( -iname "*.cue" -o -iname "*.bin" \) -print -quit | grep -q .; then
    log_message "No .cue or .bin files found. Skipping CHD conversion."
else
    # Batch CHD Conversion logic (from batch_chd_conversion.sh)

    # Determine how to invoke chdman. Prefer PATH, then known flatpak or bundled paths.
    CHD_AVAILABLE=1
    if command -v chdman >/dev/null 2>&1; then
        CHDC_EXE=(chdman)
    elif [ -x "/app/bin/chdman" ]; then
        CHDC_EXE=(/app/bin/chdman)
    elif command -v flatpak >/dev/null 2>&1 && flatpak run --command=chdman org.mamedev.MAME --help >/dev/null 2>&1; then
        CHDC_EXE=(flatpak run --command=chdman org.mamedev.MAME)
    else
        CHD_AVAILABLE=0
    fi

# Quick check: exit early if there are no .cue files in current directory
if ! find . -maxdepth 1 -iname "*.cue" -print -quit | grep -q .; then
    log_message "No .cue files found in the current directory. Nothing to do."
else
    # Safety Check: ensure chdman is accessible either directly or via Flatpak
    if [ "$CHD_AVAILABLE" -ne 1 ] || ! do_chdman --help > /dev/null 2>&1; then
        log_error "chdman is not accessible locally or via the org.mamedev.MAME flatpak."
        log_warning "Skipping CHD conversion - chdman not available."
        log_message "If you intend to run this script inside the MAME Flatpak, invoke a shell like:"
        log_message "  flatpak run --command=/bin/sh org.mamedev.MAME -c 'cd /path/to/dir && ./emuprep.sh'"
    else

    # Loop through all .cue files found in the current directory
    while IFS= read -r -d $'\0' CUE_FILE_PATH; do

        # Get the base filename (e.g., "Deathtrap Dungeon (USA)")
        FILENAME=$(basename "$CUE_FILE_PATH")
        BASE_NAME="${FILENAME%.*}" # Removes the .cue extension

        # Define the output CHD filename
        OUTPUT_CHD_FILE="$BASE_NAME.chd"

        echo -e "\nProcessing: $FILENAME"
        echo "Output will be: $OUTPUT_CHD_FILE"

        # --- Run the Conversion ---
        do_chdman createcd -i "$CUE_FILE_PATH" -o "$OUTPUT_CHD_FILE"
        CONVERSION_EXIT_CODE=$?

        # --- Check for Success and Clean Up ---
        if [ $CONVERSION_EXIT_CODE -eq 0 ] && [ -f "$OUTPUT_CHD_FILE" ]; then
            echo "Conversion successful. Cleaning up original files."

            CUE_DIR=$(dirname "$CUE_FILE_PATH")

            # Get all related data files from the CUE content
            mkdir -p "$TRASH_DIR"
            while IFS= read -r LINE; do
                if RELATED_FILE=$(echo "$LINE" | sed -E 's/FILE\s+"?([^"]+)"?.*/\1/' | awk '{print $1}'); then
                    if [ -n "$RELATED_FILE" ] && [ -f "$CUE_DIR/$RELATED_FILE" ]; then
                        echo "  -> Moving to Trash: $RELATED_FILE"
                        do_mv "$CUE_DIR/$RELATED_FILE" "$TRASH_DIR/"
                    fi
                fi
            done < <(grep -iE 'FILE.*\.(BIN|IMG|ISO|WAV)' "$CUE_FILE_PATH")

            # Move the CUE file itself to trash
            echo "  -> Moving to Trash: $FILENAME"
            do_mv "$CUE_FILE_PATH" "$TRASH_DIR/"
        else
            echo "Conversion failed or CHD file was not created. Keeping original files."
        fi

    done < <(find . -maxdepth 1 -iname "*.cue" -print0)
    fi
fi

    log_message "[2/3] CHD conversion complete"
fi
log_message ""

# ============================================================================
# STAGE 3: M3U PLAYLIST ORGANIZATION
# ============================================================================
# This stage:
#   1. Detects multi-disc CHD files (identified by '(disc X)' in filename)
#   2. Groups multi-disc games together
#   3. Creates hidden subdirectories (.game_name) for each multi-disc game
#   4. Generates M3U playlist files with references to the CHD files
#   5. Moves any existing M3U files to Trash before creating new ones
# ============================================================================
log_message "[3/3] Organizing M3U playlists and CHD files..."

# Check if any .chd files exist
if ! find . -maxdepth 1 -iname "*.chd" -type f -print -quit | grep -q .; then
    log_message "No .chd files found. Skipping M3U organization."
else
    echo "--- Starting Highly Optimized M3U Generator Script (Parenthesis-Only) ---"
    
    # Move existing .m3u files to trash
    TRASH_DIR="Trash"
    do_mkdir "$TRASH_DIR"
    for m3u_file in *.m3u; do
        if [ -f "$m3u_file" ]; then
            echo "Moving existing M3U to trash: $m3u_file"
            do_mv "$m3u_file" "$TRASH_DIR/"
        fi
    done

# Default move options (empty). Set to '-n' for no-clobber when requested.
MV_OPTS=""

# Use an associative array (map) to group files by Game Name
declare -A GAME_FILES
declare -a TEMP_FILES=()

# Ensure temporary files are moved to trash on exit
trap 'do_mkdir "$TRASH_DIR"; for t in "${TEMP_FILES[@]}"; do [ -f "$t" ] && do_mv "$t" "$TRASH_DIR/"; done' EXIT

echo -e "\n1. Identifying and Grouping multi-disc CHD files..."

# Use -print0 to safely handle filenames with spaces/newlines
while IFS= read -r -d '' CHD_FILE_PATH; do
    FILENAME=$(basename "$CHD_FILE_PATH")
    shopt -s nocasematch
    if [[ "$FILENAME" =~ ^(.*)[[:space:]]*\(disc ]]; then
        shopt -u nocasematch
        GAME_NAME=$(echo "${BASH_REMATCH[1]}" | xargs)
        # Safe check for associative array key existence under set -u
        if ! [[ -v GAME_FILES["$GAME_NAME"] ]]; then
            tmpf=$(mktemp)
            GAME_FILES["$GAME_NAME"]="$tmpf"
            TEMP_FILES+=("$tmpf")
        fi
        printf '%s\0' "$CHD_FILE_PATH" >> "${GAME_FILES[$GAME_NAME]}"
    else
        shopt -u nocasematch
    fi
done < <(find . -maxdepth 1 -iname "*.chd" -type f -print0)

echo -e "\n2. Moving CHDs and generating new M3U files."

# Iterate games in sorted order for deterministic output
mapfile -t GAMES < <(printf '%s\n' "${!GAME_FILES[@]}" | sort -V)
for GAME_NAME in "${GAMES[@]}"; do
    echo "  -> Processing game: $GAME_NAME"
    TMP_LIST_FILE="${GAME_FILES[$GAME_NAME]}"
    CLEAN_FOLDER_NAME=$(echo "$GAME_NAME" | sed 's/ /_/g' | sed 's/[^a-zA-Z0-9_-]/_/g')
    UNIQUE_CHD_SUBDIR=".$CLEAN_FOLDER_NAME" # Prepending the dot
    SANITIZED_M3U_NAME=$(echo "$GAME_NAME" | sed 's/ /_/g' | sed 's/[^a-zA-Z0-9._-]/_/g')
    M3U_FILENAME="$SANITIZED_M3U_NAME.m3u"
    do_mkdir "$UNIQUE_CHD_SUBDIR" || log_warning "Failed to create directory: $UNIQUE_CHD_SUBDIR"
    echo "     -> Folder created: $UNIQUE_CHD_SUBDIR"
    M3U_CONTENT=""
    while IFS= read -r -d '' CHD_PATH; do
        CHD_PATH=$(echo "$CHD_PATH" | xargs)
        if [ -n "$CHD_PATH" ]; then
            FILENAME=$(basename "$CHD_PATH")
            echo "     -> Moving CHD: $FILENAME"
            do_mv $MV_OPTS "$CHD_PATH" "$UNIQUE_CHD_SUBDIR/" || log_warning "Failed to move CHD: $FILENAME"
            NEW_LINE="./$UNIQUE_CHD_SUBDIR/$FILENAME"
            M3U_CONTENT+="$NEW_LINE"$'\n'
        fi
    done < <(sort -z -V "$TMP_LIST_FILE")
    do_rm "$TMP_LIST_FILE"
    if [ -n "$M3U_CONTENT" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[DRY-RUN] Would create M3U: $M3U_FILENAME with content:" 
            printf '%s' "$M3U_CONTENT"
        else
            printf '%s' "$M3U_CONTENT" > "$M3U_FILENAME" || log_warning "Failed to create M3U: $M3U_FILENAME"
            log_message "Created new M3U: $M3U_FILENAME"
        fi
    fi
done

    echo -e "\n--- Organization complete. ---"
    echo "New .m3u files and hidden subfolders created for multi-disc games."
fi

# Return to original directory
popd >/dev/null || true

# ============================================================================
# FINAL STAGE: INVENTORY GENERATION
# ============================================================================
# Creates a timestamped inventory file listing all games with disc counts
# ============================================================================
pushd "$TARGET_DIR" >/dev/null || exit 1

INVENTORY_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
INVENTORY_FILE="game_inventory_${INVENTORY_TIMESTAMP}.txt"

log_message "Generating game inventory..."

# Build inventory mapping: NAME -> disc_count (1 if unknown/single)
declare -A INVENTORY=()

# Process .m3u files first to capture multi-disc info
while IFS= read -r -d $'\0' M3U; do
    fname=$(basename "$M3U")
    name="${fname%.*}"
    # Count non-empty lines as entries
    disc_count=$(awk 'NF{c++}END{print c+0}' "$M3U")
    if [ "$disc_count" -gt 1 ]; then
        INVENTORY["$name"]=$disc_count
    else
        # ensure at least 1 if not already set
        : ${INVENTORY["$name"]:=1}
    fi
done < <(find . -maxdepth 1 -iname "*.m3u" -type f -print0)

# Process single .chd files in the current directory (skip files inside subdirectories)
while IFS= read -r -d $'\0' CHD; do
    fname=$(basename "$CHD")
    name="${fname%.*}"
    # If not already set by an .m3u, set to 1
    if [ -z "${INVENTORY["$name"]+x}" ]; then
        INVENTORY["$name"]=1
    fi
done < <(find . -maxdepth 1 -iname "*.chd" -type f -print0)

# Output inventory sorted by name
{
    echo "=== EmuPrep Game Inventory ==="
    echo "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    mapfile -t INVENTORY_NAMES < <(printf '%s\n' "${!INVENTORY[@]}" | sort -V)
    for nm in "${INVENTORY_NAMES[@]}"; do
        count=${INVENTORY["$nm"]}
        if [ "$count" -gt 1 ]; then
            echo "$nm ($count discs)"
        else
            echo "$nm"
        fi
    done
} > "$INVENTORY_FILE"

log_message "Game inventory created: $INVENTORY_FILE"

popd >/dev/null || true

echo ""
log_message "=== EmuPrep Complete ==="
log_message "All files processed and organized in: $TARGET_DIR"

# ERROR REPORTING: Display summary of warnings and errors encountered during execution
if [ ${#WARNINGS[@]} -gt 0 ]; then
    echo ""
    log_message "--- WARNINGS ---"
    for warning in "${WARNINGS[@]}"; do
        log_message "  • $warning"
    done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    log_message "--- ERRORS ---"
    for error in "${ERRORS[@]}"; do
        log_message "  • $error"
    done
fi

if [ ${#WARNINGS[@]} -eq 0 ] && [ ${#ERRORS[@]} -eq 0 ]; then
    log_message "No errors or warnings encountered."
fi

# TRASH SUMMARY: inform the user about the Trash folder and recommend manual review
TRASH_PATH="${TARGET_DIR%/}/$TRASH_DIR"
if [ -d "$TRASH_PATH" ]; then
    trash_count=$(find "$TRASH_PATH" -type f | wc -l)
    trash_size=$(du -sh "$TRASH_PATH" 2>/dev/null | cut -f1 || echo "unknown")
    if [ "$trash_count" -gt 0 ]; then
        log_message "Note: files moved during processing are in: $TRASH_PATH"
        log_message "Please review the Trash folder before permanently deleting. Files: $trash_count, Size: $trash_size"
    else
        log_message "Trash folder exists but is empty: $TRASH_PATH"
    fi
else
    log_message "No Trash folder was created during this run."
fi

# AUTO-CLEAN: optionally remove the Trash folder when requested
if [ "$AUTO_CLEAN" -eq 1 ]; then
    if [ -d "$TRASH_PATH" ]; then
        # only proceed if there are files in Trash
        if [ "$(find "$TRASH_PATH" -type f | wc -l)" -gt 0 ]; then
            if [ "$AUTO_CLEAN_YES" -eq 1 ]; then
                log_message "Auto-clean enabled; removing Trash: $TRASH_PATH"
                do_rm "$TRASH_PATH" && log_message "Trash removed: $TRASH_PATH" || log_warning "Failed to remove Trash: $TRASH_PATH"
            else
                # interactive confirmation
                printf "Remove Trash folder and its contents at '%s'? (y/N): " "$TRASH_PATH"
                read -r _reply
                if [[ "$_reply" =~ ^[Yy]$ ]]; then
                    log_message "User confirmed removal; removing Trash: $TRASH_PATH"
                    do_rm "$TRASH_PATH" && log_message "Trash removed: $TRASH_PATH" || log_warning "Failed to remove Trash: $TRASH_PATH"
                else
                    log_message "Trash retained at: $TRASH_PATH"
                fi
            fi
        else
            log_message "Auto-clean requested but Trash is empty: $TRASH_PATH"
        fi
    else
        log_message "Auto-clean requested but no Trash folder exists."
    fi
fi
