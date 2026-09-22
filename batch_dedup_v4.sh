#!/bin/bash
# =============================================================================
# Batch Dedup v4 — scales to 100GB+ individual files - Used to dedup large lists
# for password cracking
#
# Architecture:
#   Phase 1: For each source file:
#     - Small files (< 1GB): direct sort -u
#     - Large files: split → sort each chunk → delete raw chunk → hierarchical merge
#   Phase 2: Hierarchical merge of all sorted outputs
#
# Scaling strategy:
#   - Chunks are sorted and raw chunks deleted immediately (not all at once)
#   - Hierarchical merge: groups of MERGE_BATCH files at a time
#   - Peak disk per large file: original + ~2 chunks + growing sorted output
#   - Never exceeds OS file descriptor limits
#
# Usage:
#   screen -S dedup
#   bash ./batch_dedup_v4.sh /media/data/wordlists
#
# Options:
#   SORT_BUFFER=16G ./batch_dedup_v4.sh /path    # override buffer size
#   CHUNK_LINES=50000000 ./batch_dedup_v4.sh /p   # override chunk size
#   DRY_RUN=1 ./batch_dedup_v4.sh /path           # scan only, no sorting
# =============================================================================

set -uo pipefail

SRCDIR="${1:-.}"
TMPDIR="$SRCDIR/sorted_tmp"
SORT_TMP="$SRCDIR/sort_tmp"
OUTPUT="$SRCDIR/combined_deduped.txt"
LOGFILE="$SRCDIR/dedup.log"

# ---- Tuning (override via environment) ----
SORT_BUFFER="${SORT_BUFFER:-8G}"
# Files over this size get chunked (1GB default)
CHUNK_THRESHOLD="${CHUNK_THRESHOLD:-$((1 * 1024 * 1024 * 1024))}"
# Lines per chunk. 50M lines ≈ 500MB-1GB depending on avg line length.
CHUNK_LINES="${CHUNK_LINES:-50000000}"
# Max files to merge at once (stay under fd limits)
MERGE_BATCH="${MERGE_BATCH:-64}"
# Dry run mode
DRY_RUN="${DRY_RUN:-0}"

# File extensions to include
EXTENSIONS=( -name '*.txt' -o -name '*.org' -o -name '*.lst' -o -name '*.dic' -o -name '*.dict' -o -name '*.list' -o -name '*.wordlist' )

# ---- Logging ----
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# ---- Disk space check ----
check_disk() {
    local path="$1"
    local needed_gb="${2:-0}"
    local avail_kb
    avail_kb=$(df -k "$path" | awk 'NR==2{print $4}')
    local avail_gb=$(( avail_kb / 1024 / 1024 ))
    if [[ $needed_gb -gt 0 ]] && [[ $avail_gb -lt $needed_gb ]]; then
        log "[!] WARNING: Only ${avail_gb}GB free on $(df "$path" | awk 'NR==2{print $6}'). Need ~${needed_gb}GB."
        return 1
    fi
    echo "$avail_gb"
    return 0
}

# ---- Hierarchical merge ----
# Merges a list of pre-sorted files into one output file.
# Handles arbitrarily many inputs by merging in batches of MERGE_BATCH.
hierarchical_merge() {
    local output="$1"
    shift
    local -a inputs=("$@")
    local n=${#inputs[@]}

    if [[ $n -eq 0 ]]; then
        log "    [!] hierarchical_merge: no inputs"
        return 1
    fi

    if [[ $n -eq 1 ]]; then
        # Single file — just move it
        mv "${inputs[0]}" "$output"
        return 0
    fi

    if [[ $n -le $MERGE_BATCH ]]; then
        # Small enough to merge in one pass
        LC_ALL=C sort -m -u -T "$SORT_TMP" --buffer-size="$SORT_BUFFER" \
            "${inputs[@]}" > "$output" 2>>"$LOGFILE"
        return $?
    fi

    # Too many files — merge in batches, then merge the batches
    log "    Hierarchical merge: $n files in batches of $MERGE_BATCH"
    local merge_round_dir
    merge_round_dir=$(mktemp -d "$SORT_TMP/merge_round_XXXXXX")
    local -a intermediates=()
    local batch_num=0

    local i=0
    while [[ $i -lt $n ]]; do
        batch_num=$((batch_num + 1))
        local -a batch=()
        local j=0
        while [[ $j -lt $MERGE_BATCH ]] && [[ $((i + j)) -lt $n ]]; do
            batch+=("${inputs[$((i + j))]}")
            j=$((j + 1))
        done
        i=$((i + j))

        local intermediate="$merge_round_dir/merged_batch_${batch_num}.txt"
        log "    Merge batch $batch_num: ${#batch[@]} files"

        LC_ALL=C sort -m -u -T "$SORT_TMP" --buffer-size="$SORT_BUFFER" \
            "${batch[@]}" > "$intermediate" 2>>"$LOGFILE"

        if [[ $? -ne 0 ]] || [[ ! -s "$intermediate" ]]; then
            log "    [!] Batch $batch_num merge failed"
            rm -rf "$merge_round_dir"
            return 1
        fi

        intermediates+=("$intermediate")
    done

    log "    Merging ${#intermediates[@]} intermediate files..."

    # Recurse (usually just one more level)
    hierarchical_merge "$output" "${intermediates[@]}"
    local rc=$?

    # Clean up intermediates
    rm -rf "$merge_round_dir"
    return $rc
}

# ---- sort_large_file: chunk, sort, merge for files > CHUNK_THRESHOLD ----
sort_large_file() {
    local SRC="$1"
    local DEST="$2"
    local LABEL="$3"
    local FSIZE
    FSIZE=$(stat -c%s "$SRC")
    local FSIZE_H
    FSIZE_H=$(numfmt --to=iec-i --suffix=B "$FSIZE" 2>/dev/null || echo "${FSIZE}B")

    log "    Large file strategy: chunk → sort → merge"
    log "    Chunk size: ${CHUNK_LINES} lines"

    local CHUNK_DIR="$SORT_TMP/chunks_${LABEL}"
    local SORTED_DIR="$SORT_TMP/sorted_${LABEL}"
    mkdir -p "$CHUNK_DIR" "$SORTED_DIR"

    # Estimate chunk count from file size (rough: ~12 bytes/line avg)
    local EST_LINES=$(( FSIZE / 12 ))
    local EST_CHUNKS=$(( (EST_LINES / CHUNK_LINES) + 1 ))
    log "    Estimated: ~${EST_CHUNKS} chunks from ~${EST_LINES} lines"

    # ---- Step 1: Split into chunks ----
    log "    Splitting..."
    local SPLIT_START
    SPLIT_START=$(date +%s)

    split -l "$CHUNK_LINES" -d -a 4 --additional-suffix=".raw" \
        "$SRC" "$CHUNK_DIR/chunk_" 2>>"$LOGFILE"

    if [[ $? -ne 0 ]]; then
        log "    [!] split failed on $SRC"
        rm -rf "$CHUNK_DIR" "$SORTED_DIR"
        return 1
    fi

    local SPLIT_END
    SPLIT_END=$(date +%s)
    local NCHUNKS
    NCHUNKS=$(find "$CHUNK_DIR" -name '*.raw' -type f | wc -l)
    log "    Split into $NCHUNKS chunks ($((SPLIT_END - SPLIT_START))s)"

    # ---- Step 2: Sort each chunk, delete raw immediately ----
    local CHUNK_NUM=0
    local CHUNK_OK=0
    local CHUNK_FAIL=0
    local -a sorted_chunks=()

    # Process chunks in order
    for raw_chunk in $(find "$CHUNK_DIR" -name '*.raw' -type f | sort); do
        CHUNK_NUM=$((CHUNK_NUM + 1))
        local CHUNK_BASE
        CHUNK_BASE=$(basename "$raw_chunk" .raw)
        local sorted_chunk="$SORTED_DIR/${CHUNK_BASE}.txt"

        LC_ALL=C sort -u -T "$SORT_TMP" --buffer-size="$SORT_BUFFER" \
            "$raw_chunk" > "$sorted_chunk" 2>>"$LOGFILE"

        if [[ $? -eq 0 ]] && [[ -s "$sorted_chunk" ]]; then
            sorted_chunks+=("$sorted_chunk")
            CHUNK_OK=$((CHUNK_OK + 1))
        else
            rm -f "$sorted_chunk"
            CHUNK_FAIL=$((CHUNK_FAIL + 1))
            log "    [!] Chunk $CHUNK_NUM failed"
        fi

        # Delete raw chunk immediately to free disk space
        rm -f "$raw_chunk"

        # Progress every 10 chunks (or every chunk if < 20 total)
        if (( NCHUNKS < 20 )) || (( CHUNK_NUM % 10 == 0 )) || (( CHUNK_NUM == NCHUNKS )); then
            local pct=$(( CHUNK_NUM * 100 / NCHUNKS ))
            log "    Sorted $CHUNK_NUM/$NCHUNKS chunks (${pct}%)"
        fi
    done

    # Clean up empty chunk dir
    rmdir "$CHUNK_DIR" 2>/dev/null

    if [[ ${#sorted_chunks[@]} -eq 0 ]]; then
        log "    [!] All chunks failed for $SRC"
        rm -rf "$SORTED_DIR"
        return 1
    fi

    log "    $CHUNK_OK chunks sorted OK, $CHUNK_FAIL failed"

    # ---- Step 3: Hierarchical merge of sorted chunks ----
    log "    Merging ${#sorted_chunks[@]} sorted chunks..."
    local MERGE_START
    MERGE_START=$(date +%s)

    hierarchical_merge "$DEST" "${sorted_chunks[@]}"
    local MERGE_RC=$?

    local MERGE_END
    MERGE_END=$(date +%s)

    # Clean up sorted chunks
    rm -rf "$SORTED_DIR"

    if [[ $MERGE_RC -ne 0 ]] || [[ ! -s "$DEST" ]]; then
        log "    [!] Merge failed for $SRC"
        rm -f "$DEST"
        return 1
    fi

    local OUTLINE
    OUTLINE=$(wc -l < "$DEST")
    local DEST_H
    DEST_H=$(du -h "$DEST" | cut -f1)
    log "    -> $OUTLINE unique lines ($DEST_H) merge: $((MERGE_END - MERGE_START))s"

    return 0
}

# ---- sort_small_file: direct sort -u for files < CHUNK_THRESHOLD ----
sort_small_file() {
    local SRC="$1"
    local DEST="$2"

    LC_ALL=C sort -u -T "$SORT_TMP" --buffer-size="$SORT_BUFFER" \
        "$SRC" > "$DEST" 2>>"$LOGFILE"

    if [[ $? -ne 0 ]] || [[ ! -s "$DEST" ]]; then
        rm -f "$DEST"
        return 1
    fi

    local OUTLINE
    OUTLINE=$(wc -l < "$DEST")
    local DEST_H
    DEST_H=$(du -h "$DEST" | cut -f1)
    log "    -> $OUTLINE unique lines ($DEST_H)"
    return 0
}

# ===========================================================================
# MAIN
# ===========================================================================

mkdir -p "$TMPDIR" "$SORT_TMP"

log "============================================="
log "  Batch Dedup v4 (scales to 100GB+ files)"
log "============================================="
log "  Source:      $SRCDIR"
log "  Output:      $OUTPUT"
log "  Buffer:      $SORT_BUFFER"
log "  Chunk at:    $(numfmt --to=iec-i $CHUNK_THRESHOLD 2>/dev/null || echo $CHUNK_THRESHOLD) / ${CHUNK_LINES} lines"
log "  Merge batch: $MERGE_BATCH files"
log "  Temp:        $SORT_TMP"
log "  Disk free:   $(check_disk "$SRCDIR")GB on $(df "$SRCDIR" | awk 'NR==2{print $6}')"
log "============================================="

# ---- Build file list ----
FILELIST="$SRCDIR/.dedup_filelist.tmp"
find "$SRCDIR" -maxdepth 10 \( "${EXTENSIONS[@]}" \) \
    ! -name 'combined_deduped.txt' \
    ! -path '*/sorted_tmp/*' \
    ! -path '*/sort_tmp/*' \
    ! -path '*/tmp/*' \
    -type f \
    -print > "$FILELIST" 2>/dev/null

TOTAL_FILES=$(wc -l < "$FILELIST")
log ""
log "[*] Found $TOTAL_FILES wordlist files"

# Categorize files by size
SMALL_COUNT=0
LARGE_COUNT=0
TOTAL_BYTES=0

while IFS= read -r f; do
    SZ=$(stat -c%s "$f" 2>/dev/null || echo 0)
    TOTAL_BYTES=$((TOTAL_BYTES + SZ))
    if [[ $SZ -ge $CHUNK_THRESHOLD ]]; then
        LARGE_COUNT=$((LARGE_COUNT + 1))
    else
        SMALL_COUNT=$((SMALL_COUNT + 1))
    fi
done < "$FILELIST"

TOTAL_H=$(numfmt --to=iec-i --suffix=B "$TOTAL_BYTES" 2>/dev/null || echo "${TOTAL_BYTES}B")
CHUNK_H=$(numfmt --to=iec-i "$CHUNK_THRESHOLD" 2>/dev/null || echo "$CHUNK_THRESHOLD")

log "    Total size: $TOTAL_H"
log "    Small (< $CHUNK_H): $SMALL_COUNT files — direct sort"
log "    Large (>= $CHUNK_H): $LARGE_COUNT files — chunk+merge"
log ""

# Show the biggest files
log "[*] Top 15 by size:"
while IFS= read -r f; do
    stat --printf="%s %n\n" "$f" 2>/dev/null
done < "$FILELIST" | sort -rn | head -15 | while IFS=' ' read -r sz path; do
    szh=$(numfmt --to=iec-i --suffix=B "$sz" 2>/dev/null || echo "${sz}B")
    tag=""
    [[ $sz -ge $CHUNK_THRESHOLD ]] && tag=" [CHUNK]"
    log "    $szh  $(basename "$path")$tag"
done
log ""

if [[ "$DRY_RUN" == "1" ]]; then
    log "[*] Dry run — exiting without sorting."
    rm -f "$FILELIST"
    exit 0
fi

# ==== Phase 1: Sort each file ====
log "================================================================"
log "[*] Phase 1: Sort each file individually"
log "================================================================"
log ""

COUNT=0
SORTED_OK=0
SKIPPED=0
FAILED=0
PHASE1_START=$(date +%s)

while IFS= read -r f; do
    COUNT=$((COUNT + 1))

    BASENAME=$(basename "$f")
    BASENAME_NOEXT="${BASENAME%.*}"
    # Include a hash of the full path to avoid collisions from same-name files in subdirs
    PATH_HASH=$(echo "$f" | md5sum | cut -c1-8)
    OUTF="$TMPDIR/sorted_${COUNT}_${PATH_HASH}_${BASENAME_NOEXT}.txt"

    # Resume: skip if output already exists and is non-empty
    if [[ -f "$OUTF" ]] && [[ -s "$OUTF" ]]; then
        SKIPPED=$((SKIPPED + 1))
        log "  [$COUNT/$TOTAL_FILES] SKIP (exists): $BASENAME"
        continue
    fi

    rm -f "$OUTF"

    FSIZE=$(stat -c%s "$f" 2>/dev/null || echo 0)
    FSIZE_H=$(numfmt --to=iec-i --suffix=B "$FSIZE" 2>/dev/null || echo "${FSIZE}B")
    FILE_START=$(date +%s)

    if [[ $FSIZE -ge $CHUNK_THRESHOLD ]]; then
        log "  [$COUNT/$TOTAL_FILES] LARGE ($FSIZE_H): $BASENAME"
        if sort_large_file "$f" "$OUTF" "${COUNT}_${PATH_HASH}"; then
            SORTED_OK=$((SORTED_OK + 1))
        else
            FAILED=$((FAILED + 1))
        fi
    else
        log "  [$COUNT/$TOTAL_FILES] Sort ($FSIZE_H): $BASENAME"
        if sort_small_file "$f" "$OUTF"; then
            SORTED_OK=$((SORTED_OK + 1))
        else
            FAILED=$((FAILED + 1))
            log "    [!] FAILED: $BASENAME"
        fi
    fi

    FILE_END=$(date +%s)
    FILE_ELAPSED=$((FILE_END - FILE_START))
    if [[ $FILE_ELAPSED -gt 10 ]]; then
        log "    Time: ${FILE_ELAPSED}s ($((FILE_ELAPSED/60))m $((FILE_ELAPSED%60))s)"
    fi

done < "$FILELIST"

PHASE1_END=$(date +%s)
PHASE1_ELAPSED=$(( PHASE1_END - PHASE1_START ))

log ""
log "[*] Phase 1 complete in $((PHASE1_ELAPSED/3600))h $((PHASE1_ELAPSED%3600/60))m $((PHASE1_ELAPSED%60))s"
log "    Sorted:  $SORTED_OK"
log "    Skipped: $SKIPPED (resume)"
log "    Failed:  $FAILED"
log "    sorted_tmp: $(du -sh "$TMPDIR" | cut -f1)"
log "    Disk free: $(check_disk "$SRCDIR")GB"
log ""

# ==== Phase 2: Hierarchical merge of all sorted files ====
find "$TMPDIR" -name '*.txt' -type f -empty -delete 2>/dev/null

# Collect all sorted files into an array
SORTED_FILES=()
while IFS= read -r -d '' sf; do
    SORTED_FILES+=("$sf")
done < <(find "$TMPDIR" -name '*.txt' -type f -size +0c -print0 | sort -z)

NFILES=${#SORTED_FILES[@]}
TMPSIZE=$(du -sh "$TMPDIR" | cut -f1)

if [[ $NFILES -eq 0 ]]; then
    log "[!] No sorted files to merge. Exiting."
    exit 1
fi

log "================================================================"
log "[*] Phase 2: Hierarchical merge of $NFILES sorted files ($TMPSIZE)"
log "================================================================"
log ""

PHASE2_START=$(date +%s)

hierarchical_merge "$OUTPUT" "${SORTED_FILES[@]}"
MERGE_RC=$?

PHASE2_END=$(date +%s)
PHASE2_ELAPSED=$(( PHASE2_END - PHASE2_START ))

if [[ $MERGE_RC -ne 0 ]]; then
    log "[!] Final merge failed. sorted_tmp preserved for retry."
    exit 1
fi

LINES=$(wc -l < "$OUTPUT")
OUTSIZE=$(du -sh "$OUTPUT" | cut -f1)
TOTAL_ELAPSED=$(( PHASE2_END - PHASE1_START ))

log ""
log "============================================="
log "  COMPLETE"
log "============================================="
log "  Output:       $OUTPUT"
log "  Unique lines: $(printf "%'d" "$LINES")"
log "  File size:    $OUTSIZE"
log "  Phase 1:      $((PHASE1_ELAPSED/3600))h $((PHASE1_ELAPSED%3600/60))m"
log "  Phase 2:      $((PHASE2_ELAPSED/3600))h $((PHASE2_ELAPSED%3600/60))m"
log "  Total:        $((TOTAL_ELAPSED/3600))h $((TOTAL_ELAPSED%3600/60))m"
log "  Disk free:    $(check_disk "$SRCDIR")GB"
log "============================================="
log ""
log "[*] sorted_tmp preserved. Delete when satisfied:"
log "    rm -rf $TMPDIR $SORT_TMP"

rm -f "$FILELIST"
log "[*] Done."
