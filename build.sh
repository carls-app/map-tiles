#!/usr/bin/env bash
#
# Build the All About Olaf campus basemap.
#
# Pulls tiles out of the Protomaps daily planet build over HTTP range requests
# (no planet download, no OSM processing), then lays out a GitHub Pages site
# containing them twice — as a single PMTiles archive and as an exploded
# {z}/{x}/{y}.pbf directory — plus the glyphs, sprites and styles the map needs.
#
# Everything lands in ./dist, which is what gets force-pushed to gh-pages.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — change these and nothing else.
# ---------------------------------------------------------------------------

# The area the app actually cares about: St. Olaf, Carleton, and the town of
# Northfield between them. west,south,east,north
BBOX="-93.20,44.44,-93.12,44.49"

# Zoom range. The Protomaps planet build tops out at z15, so MAXZOOM cannot
# usefully exceed that; the style overzooms z15 tiles the rest of the way to
# STYLE_MAXZOOM for campus detail. See README ("Zoom levels").
MINZOOM=0
MAXZOOM=15
STYLE_MAXZOOM=18

# Extracting BBOX alone across every zoom looks broken when you pinch out: below
# about z10 a single tile covers the whole bounding box, so the map becomes one
# lonely rectangle floating in background colour with a hard edge all around it.
#
# So the extract is graduated. Each tier is "minzoom:maxzoom:bbox", widest at the
# bottom, tightening as the zoom climbs and tiles get expensive. The tiers are
# merged into one tileset afterwards. Measured cost of the whole pyramid is a
# few megabytes — see README ("Output sizes").
#
# Keep the tiers contiguous and covering MINZOOM..MAXZOOM. The last tier should
# be BBOX itself.
TIERS=(
  "0:8:-97.9,42.4,-88.4,49.6"        # upper midwest — context when fully zoomed out
  "9:12:-93.55,44.30,-92.80,44.75"   # Northfield and its approach roads
  "13:14:-93.28,44.38,-93.05,44.55"  # town and immediate surroundings
  "15:15:$BBOX"                      # campus detail
)

# The data extent of the merged tileset — the widest tier's bbox. This becomes
# the styles' source `bounds`. It has to be the wide one: if it were BBOX,
# MapLibre would cull every low-zoom tile except the one over campus and undo
# the whole point of the tiers above.
DATA_BOUNDS="-97.9,42.4,-88.4,49.6"

# Where the built site is served from. Written into the styles as absolute URLs,
# since MapLibre Native resolves style-relative URLs inconsistently.
SITE_URL="${SITE_URL:-https://carls-app.github.io/map-tiles}"

# Map opens here: between the two campuses.
CENTER_LON=-93.167
CENTER_LAT=44.462
CENTER_ZOOM=14

# Pinned tool and asset versions, so a rebuild in six months produces the same
# shape of output as one today.
PMTILES_VERSION="1.28.0"                                        # go-pmtiles CLI
PMTILES_PY_VERSION="3.7.0"                                      # PyPI pmtiles, used by the assembler
BASEMAPS_STYLE_VERSION="5.7.2"                                  # npm @protomaps/basemaps
ASSETS_COMMIT="028c18f713baecad011301ff7a69acc39bcc2ae7"        # protomaps/basemaps-assets

# The Protomaps daily builds are retained for about a week and there is no index
# to list them, so probe backwards from today until one answers.
BUILD_LOOKBACK_DAYS=10

# Hard ceiling on a single file served by GitHub Pages. Git LFS is not a way
# around this — Pages serves the LFS pointer file, not the object.
PAGES_FILE_LIMIT=100000000

# ---------------------------------------------------------------------------

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
WORK="$ROOT/.work"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

mkdir -p "$WORK"

# --- 1. tools --------------------------------------------------------------

log "Fetching tools"

PMTILES="$WORK/pmtiles"
if [ ! -x "$PMTILES" ]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)   PM_ASSET="Linux_x86_64" ;;
    Linux-aarch64)  PM_ASSET="Linux_arm64" ;;
    Darwin-x86_64)  PM_ASSET="Darwin_x86_64" ;;
    Darwin-arm64)   PM_ASSET="Darwin_arm64" ;;
    *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
  esac
  curl -fsSL -o "$WORK/pmtiles.tar.gz" \
    "https://github.com/protomaps/go-pmtiles/releases/download/v${PMTILES_VERSION}/go-pmtiles_${PMTILES_VERSION}_${PM_ASSET}.tar.gz"
  tar xzf "$WORK/pmtiles.tar.gz" -C "$WORK" pmtiles
  chmod +x "$PMTILES"
fi
"$PMTILES" version

# The assembler reads the archives with the official Python PMTiles library. A
# venv keeps this off the system interpreter, which some distros protect.
VENV="$WORK/venv"
if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
fi
"$VENV/bin/pip" install --quiet "pmtiles==${PMTILES_PY_VERSION}"
PYTHON="$VENV/bin/python"

# --- 2. find a planet build ------------------------------------------------

log "Locating a Protomaps daily build"

PLANET_URL=""
for i in $(seq 0 "$BUILD_LOOKBACK_DAYS"); do
  if date -v-1d >/dev/null 2>&1; then
    day="$(date -u -v-"${i}"d +%Y%m%d)"      # BSD date (macOS)
  else
    day="$(date -u -d "-${i} days" +%Y%m%d)" # GNU date
  fi
  url="https://build.protomaps.com/${day}.pmtiles"
  code="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -r 0-99 "$url" || true)"
  if [ "$code" = "206" ] || [ "$code" = "200" ]; then
    PLANET_URL="$url"
    echo "using $url"
    break
  fi
  echo "  $day -> $code"
done
[ -n "$PLANET_URL" ] || { echo "no Protomaps build found in the last $BUILD_LOOKBACK_DAYS days" >&2; exit 1; }

# --- 3. extract each tier --------------------------------------------------

log "Extracting ${#TIERS[@]} zoom tiers"

rm -rf "$DIST" "$WORK/tiers"
mkdir -p "$DIST" "$WORK/tiers"

TIER_FILES=()
for tier in "${TIERS[@]}"; do
  minz="${tier%%:*}"
  rest="${tier#*:}"
  maxz="${rest%%:*}"
  tbbox="${rest#*:}"
  f="$WORK/tiers/z${minz}-${maxz}.pmtiles"
  echo "  z${minz}-z${maxz}  $tbbox"
  "$PMTILES" extract "$PLANET_URL" "$f" \
    --bbox="$tbbox" --minzoom="$minz" --maxzoom="$maxz" 2>&1 |
    grep -E 'Extract transferred|Region tiles' | sed 's/^/    /'
  TIER_FILES+=("$f")
done

# --- 4. merge into both published forms ------------------------------------

log "Assembling tiles/{z}/{x}/{y}.pbf and the PMTiles archive"

"$PYTHON" "$ROOT/scripts/assemble.py" \
  "$DIST/tiles" "$WORK/campus.mbtiles" \
  "$DATA_BOUNDS" "$CENTER_LON" "$CENTER_LAT" "$CENTER_ZOOM" \
  "${TIER_FILES[@]}"

"$PMTILES" convert "$WORK/campus.mbtiles" "$DIST/campus.pmtiles" --tmpdir="$WORK" 2>&1 | sed 's/^/  /'
"$PMTILES" verify "$DIST/campus.pmtiles"
"$PMTILES" show "$DIST/campus.pmtiles" | grep -E 'zoom|bounds|tile type|compression|count' | sed 's/^/  /'

# --- 5. glyphs and sprites -------------------------------------------------
#
# A style that names a font or icon it cannot fetch renders without labels
# instead of erroring, so these are self-hosted alongside the tiles.

log "Vendoring glyphs and sprites"

# Fetch just the pinned commit rather than the whole history — the repo is
# mostly font binaries and its history is much larger than its tree.
ASSETS="$WORK/basemaps-assets"
if [ ! -e "$ASSETS/.git" ]; then
  mkdir -p "$ASSETS"
  git -C "$ASSETS" init --quiet
  git -C "$ASSETS" remote add origin https://github.com/protomaps/basemaps-assets.git
fi
if ! git -C "$ASSETS" cat-file -e "${ASSETS_COMMIT}^{commit}" 2>/dev/null; then
  git -C "$ASSETS" fetch --quiet --depth 1 origin "$ASSETS_COMMIT"
fi
git -C "$ASSETS" checkout --quiet --force "$ASSETS_COMMIT"

mkdir -p "$DIST/fonts" "$DIST/sprites"
# The three stacks the style names, and every range of each. Only the Latin
# ranges get requested around Northfield, but the z0-z8 tiers carry global city
# and country labels, so any script can show up when the user pinches out.
for stack in "Noto Sans Regular" "Noto Sans Medium" "Noto Sans Italic"; do
  cp -R "$ASSETS/fonts/$stack" "$DIST/fonts/$stack"
done
cp "$ASSETS/fonts/OFL.txt" "$DIST/fonts/OFL.txt"

# The style is derived from the Protomaps "light" flavor, so the light sprite
# sheet is the matching one. Both densities: iOS is a 2x/3x device.
cp "$ASSETS/sprites/v4/light.json"     "$DIST/sprites/sprite.json"
cp "$ASSETS/sprites/v4/light.png"      "$DIST/sprites/sprite.png"
cp "$ASSETS/sprites/v4/light@2x.json"  "$DIST/sprites/sprite@2x.json"
cp "$ASSETS/sprites/v4/light@2x.png"   "$DIST/sprites/sprite@2x.png"

# --- 6. styles -------------------------------------------------------------

log "Generating styles"

( cd "$ROOT" && { npm ci --silent 2>/dev/null || npm install --silent; } )

SITE_URL="$SITE_URL" \
DATA_BOUNDS="$DATA_BOUNDS" \
MINZOOM="$MINZOOM" \
MAXZOOM="$MAXZOOM" \
STYLE_MAXZOOM="$STYLE_MAXZOOM" \
CENTER_LON="$CENTER_LON" CENTER_LAT="$CENTER_LAT" CENTER_ZOOM="$CENTER_ZOOM" \
BASEMAPS_STYLE_VERSION="$BASEMAPS_STYLE_VERSION" \
  node "$ROOT/scripts/make-style.mjs" "$DIST"

cp "$ROOT/site/index.html" "$DIST/index.html"
cp "$ROOT/site/.nojekyll" "$DIST/.nojekyll"

# Every mismatch this catches — style against schema, style against vendored
# assets — renders a blank or label-less map without raising an error, which is
# miserable to debug on device.
"$PYTHON" "$ROOT/scripts/verify.py" "$DIST"

# --- 7. report -------------------------------------------------------------

log "Output"

TILE_COUNT="$(find "$DIST/tiles" -name '*.pbf' | wc -l | tr -d ' ')"
FONT_COUNT="$(find "$DIST/fonts" -name '*.pbf' | wc -l | tr -d ' ')"
{
  echo "campus.pmtiles : $(du -h "$DIST/campus.pmtiles" | cut -f1)"
  echo "tiles/         : $(du -sh "$DIST/tiles" | cut -f1) across $TILE_COUNT files"
  echo "fonts/         : $(du -sh "$DIST/fonts" | cut -f1) across $FONT_COUNT ranges"
  echo "sprites/       : $(du -sh "$DIST/sprites" | cut -f1)"
  echo "site total     : $(du -sh "$DIST" | cut -f1)"
} | sed 's/^/  /'

SIZE_BYTES="$(wc -c < "$DIST/campus.pmtiles" | tr -d ' ')"
if [ "$SIZE_BYTES" -gt "$PAGES_FILE_LIMIT" ]; then
  echo "ERROR: campus.pmtiles is $SIZE_BYTES bytes, over the 100 MB GitHub Pages per-file limit." >&2
  echo "Shrink a tier's bbox or zoom range, or move the archive to a Release asset." >&2
  exit 1
fi

log "Done — $DIST is ready to publish"
