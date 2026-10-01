#!/bin/bash
#
# Build a self-contained decarta.app: ingest the disc, build the reader, package it into
# a bundle that carries its own corpus and pictures and can be copied to /Applications.
#
#   scripts/build-app.sh                     # ingest the mounted disc, then package
#   SKIP_INGEST=1 scripts/build-app.sh       # repackage from build/corpus.db
#   DISC=/Volumes/L03JXLRD1 scripts/build-app.sh
#
# Nothing here redistributes encyclopedia content: the corpus and pictures are built from
# a disc the user owns, land only in build/, and are git-ignored.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DISC="${DISC:-/tmp/encarta_mnt}"
CORPUS="${CORPUS:-build/corpus.db}"
MEDIA_OUT="${MEDIA_OUT:-build/media}"
SCRATCH="${SCRATCH:-build/its-scratch}"
OUT="${OUT:-build/decarta.app}"
SKIP_INGEST="${SKIP_INGEST:-0}"
PYTHON="${PYTHON:-python3}"
CONFIG="${CONFIG:-release}"
APP_NAME=decarta

log() { printf '→ %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. ingest the disc
if [ "$SKIP_INGEST" = "1" ]; then
    log "skipping ingest (SKIP_INGEST=1)"
else
    [ -d "$DISC" ] || die "no disc tree at $DISC — mount it first (make mount), or set DISC=<path>"
    log "ingesting $DISC"
    PYTHONPATH=extractor "$PYTHON" -m decarta_extract ingest "$DISC" \
        --adapter encarta-its --scratch "$SCRATCH" --tokenizer trigram \
        --media-out "$MEDIA_OUT"
fi

[ -f "$CORPUS" ] || die "no corpus at $CORPUS"
[ -d "$MEDIA_OUT" ] || die "no media tree at $MEDIA_OUT"
[ -f packaging/Info.plist ] || die "missing packaging/Info.plist"

# ------------------------------------------------------------- 2. build the reader
log "building $APP_NAME ($CONFIG)"
( cd app && swift build -c "$CONFIG" )
BIN="$(cd app && swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
[ -x "$BIN" ] || die "no executable at $BIN"

# ------------------------------------------------------------ 3. assemble the bundle
log "assembling $(basename "$OUT")"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP_NAME"
cp packaging/Info.plist "$OUT/Contents/Info.plist"

# Icon: committed as a .icns; regenerate the design with packaging/make-icon.py.
[ -f packaging/decarta.icns ] || die "missing packaging/decarta.icns (run packaging/make-icon.py)"
cp packaging/decarta.icns "$OUT/Contents/Resources/$APP_NAME.icns"

# The reader looks for corpus.db in its Resources and for a media/ directory beside it,
# so this layout is what makes the bundle self-contained.
#
# The corpus is written out with VACUUM INTO and left in rollback-journal mode, so it is a
# single self-contained file: a WAL-mode database would make the reader create -shm/-wal
# sidecars inside the app bundle on first read, which both litters Resources and breaks
# the code signature.
CORPUS_TARGET="$OUT/Contents/Resources/corpus.db"
sqlite3 "$CORPUS" "VACUUM INTO '$CORPUS_TARGET'"
sqlite3 "$CORPUS_TARGET" "PRAGMA journal_mode=DELETE;"
rm -f "$CORPUS_TARGET-wal" "$CORPUS_TARGET-shm"
log "corpus written ($(du -h "$CORPUS_TARGET" | cut -f1), rollback journal)"

log "copying pictures"
ditto "$MEDIA_OUT" "$OUT/Contents/Resources/media"

VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo 0.1.0)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" \
    "$OUT/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$OUT/Contents/Info.plist"

# ------------------------------------------------------------------ 4. sanity check
# Everything that inspects the bundle happens *before* signing: opening the corpus even
# read-only must not be able to add files to a bundle that has already been sealed.
PICTURES="$(find "$OUT/Contents/Resources/media" -type f | wc -l | tr -d ' ')"
ARTICLES="$(sqlite3 "file:$CORPUS_TARGET?mode=ro" "SELECT COUNT(*) FROM articles;")"
[ -f "$OUT/Contents/Resources/$APP_NAME.icns" ] || die "icon missing from the bundle"
if [ -e "$CORPUS_TARGET-wal" ] || [ -e "$CORPUS_TARGET-shm" ]; then
    die "reading the corpus created sidecar files — the bundle would be modified at runtime"
fi

# -------------------------------------------------------------------- 5. sign last
# Ad-hoc signature: enough for local launch and for the app to keep its identity if it is
# moved, without pretending to be a signed distribution.
if codesign --force --sign - "$OUT" >/dev/null 2>&1; then
    if codesign --verify --deep "$OUT" >/dev/null 2>&1; then
        log "ad-hoc signed and verified"
    else
        log "warning: signature did not verify"
    fi
else
    log "codesign unavailable — continuing unsigned"
fi

SIZE="$(du -sh "$OUT" | cut -f1)"

echo
log "$OUT — $ARTICLES articles, $PICTURES pictures, $SIZE"
echo
echo "  install:  cp -R '$OUT' /Applications/"
echo "  run:      open '$OUT'"
