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

# Two areas, in west,south,east,north order.
#
# The region worth having at all: Northfield, reaching Apple Valley in the north
# and Faribault in the south, with the same distance east and west. About 52 km
# square.
REGION_BBOX="-93.50,44.28,-92.84,44.75"

# Where the app actually spends its time: both campuses, downtown Northfield and
# Dundas, with room to pan. This is the part that gets high-zoom detail.
CAMPUS_BBOX="-93.28,44.38,-93.05,44.55"

# Zoom range of the basemap tiles. The Protomaps planet build tops out at z15,
# so MAXZOOM cannot usefully exceed that — MapLibre overzooms z15 tiles beyond
# it. How far the user may pinch in is not set here and cannot be: the style
# spec has no such property. It is the map view's own maxZoomLevel, in the app.
MINZOOM=0
MAXZOOM=15

# Carleton's own building data, joined into the tileset as two extra layers on
# top of the OSM basemap. This is Carleton's, not OpenStreetMap's, and is
# credited separately in the styles.
#
# Prefer the live endpoint over carls-app/map-data's map.geojson, which is the
# same data frozen in 2018.
CAMPUS_GEOJSON_URL="https://carleton.api.frogpond.tech/v1/map/geojson"

# Footprints only need to exist where they are legible, and the labels a zoom
# later so they do not pile up on top of each other.
CAMPUS_BUILDINGS_MINZOOM=14
CAMPUS_LABELS_MINZOOM=15

# How finely campus geometry is stored, as a power of two: 14 means 16384 units
# per tile instead of tippecanoe's default 4096.
#
# Quantisation is tile size over extent, so precision can be bought either by
# adding zoom levels (shrinking the numerator) or by raising the extent. At z15
# the default 4096 quantises to ~21 cm — one pixel at z18, four at z20. Extent
# 16384 gets that to ~5.3 cm, sharp past z21.
#
# Raising the extent is the cheap half of that trade: same 7 tiles, same 48 KB.
# Reaching the same 5.3 cm by tiling to z17 instead would cost 94 campus tiles
# and, because MapLibre would then fetch real z16/z17 tiles that hold no
# basemap, another ~250 KB of overzoomed basemap to fill them. Tile extent is a
# per-layer field in the MVT spec, so a tile can carry basemap layers at 4096
# and these at 16384 with no special handling by the client.
CAMPUS_DETAIL=14

# What to do with the basemap's own OSM building footprints, which overlap
# Carleton's over campus. OSM's outlines are generally the more accurate of the
# two, so the campus layer is painted in the same grey with no outline and the
# two simply union — no doubled edge, and downtown Northfield (which has no
# campus data) keeps its buildings.
#
#   full   draw them normally — the default
#   ghost  fade them from CAMPUS_BUILDINGS_MINZOOM so only Carleton's read
#   off    omit the layer entirely
#
# `off` is the escape hatch if building polygons turn out to be a rendering
# cost on device: it roughly halves the polygon count over campus without
# touching the campus layer, which the app hit-tests taps against.
OSM_BUILDINGS="full"

# The extract is graduated: the whole region down to street level, then only the
# campus area for the zooms where tiles get expensive. Going one zoom deeper
# across the whole region costs more than the entire rest of the pyramid
# (measured: z14 over REGION_BBOX is 4.4 MB and 961 tiles on its own), and
# nothing in a campus wayfinding app needs building footprints in Faribault.
#
# Each tier is "minzoom:maxzoom:bbox". They must be contiguous and cover
# MINZOOM..MAXZOOM; the build checks that and refuses to start otherwise.
TIERS=(
  "0:13:$REGION_BBOX"   # whole region, down to street level
  "14:15:$CAMPUS_BBOX"  # campuses, Northfield and Dundas, in full detail
)

# Where the built site is served from. Written into the styles as absolute URLs,
# since MapLibre Native resolves style-relative URLs inconsistently.
SITE_URL="${SITE_URL:-https://carls-app.github.io/map-tiles}"

# Map opens here: between the two campuses.
CENTER_LON=-93.167
CENTER_LAT=44.462
CENTER_ZOOM=14

# Tool versions are not here: mise.toml and mise.lock own pmtiles, uv, python
# and node; pyproject.toml and uv.lock own the Python packages; package.json
# owns the JS ones.
#
# This is the one pin left, because nothing else can express it — the font and
# sprite assets are a repo without releases, so it tracks the tip of its default
# branch by digest. Renovate matches on the comment, so keep the two attached.
# renovate: datasource=git-refs depName=https://github.com/protomaps/basemaps-assets branch=main
ASSETS_COMMIT="028c18f713baecad011301ff7a69acc39bcc2ae7"

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

# --- 0. check the tier config ----------------------------------------------
#
# TIERS is the one thing here that is meant to be edited, and the two ways to
# get it wrong are both silent. A gap in the zoom coverage yields a map that
# goes blank at one zoom level and comes back at the next; a `bounds` narrower
# than the data culls tiles that were paid for. So validate the tiers, and
# derive the data extent from them rather than restating it by hand.
DATA_BOUNDS="$(
  MINZOOM="$MINZOOM" MAXZOOM="$MAXZOOM" python3 - "${TIERS[@]}" <<'PY'
import os, sys

tiers = []
for spec in sys.argv[1:]:
    lo, hi, bbox = spec.split(":", 2)
    w, s, e, n = (float(v) for v in bbox.split(","))
    if not (w < e and s < n):
        sys.exit(f"tier {spec!r}: bbox is not west,south,east,north")
    tiers.append((int(lo), int(hi), (w, s, e, n)))

tiers.sort()
want = int(os.environ["MINZOOM"])
for lo, hi, _ in tiers:
    if lo != want:
        sys.exit(f"tier zoom coverage breaks at z{want}: next tier starts at z{lo}")
    if hi < lo:
        sys.exit(f"tier z{lo}-z{hi} has maxzoom below minzoom")
    want = hi + 1
if want - 1 != int(os.environ["MAXZOOM"]):
    sys.exit(f"tiers cover up to z{want - 1}, but MAXZOOM is z{os.environ['MAXZOOM']}")

# The union of every tier — what the tileset actually spans.
print("%s,%s,%s,%s" % (
    min(t[2][0] for t in tiers), min(t[2][1] for t in tiers),
    max(t[2][2] for t in tiers), max(t[2][3] for t in tiers),
))
PY
)"

# --- 1. tools --------------------------------------------------------------

log "Fetching tools"

# Every tool version lives in mise.toml, with mise.lock pinning the exact
# artifact and checksum per platform. That replaces three separate bootstrap
# blocks that used to live here — pmtiles, uv, and a hand-rolled venv — and
# means CI and a laptop install identically.
command -v mise >/dev/null || {
  echo "ERROR: mise not found. It manages this repo's toolchain (see mise.toml):" >&2
  echo "  curl https://mise.run | sh" >&2
  echo "  https://mise.jdx.dev/getting-started.html" >&2
  exit 1
}
mise install
mise exec -- pmtiles version
mise exec -- uv --version

PMTILES="mise exec -- pmtiles"

# Run a project script against the locked Python environment.
py() { mise exec -- uv run --quiet --project "$ROOT" "$@"; }

# tippecanoe tiles the campus layers and tile-join merges them into the basemap.
# Unlike the rest of the toolchain it is not fetched here — it is a C++ build,
# and every platform already packages it.
for tool in tippecanoe tile-join; do
  command -v "$tool" >/dev/null || {
    echo "ERROR: $tool not found. Install tippecanoe:" >&2
    echo "  Debian/Ubuntu: sudo apt-get install -y tippecanoe" >&2
    echo "  macOS:         brew install tippecanoe" >&2
    exit 1
  }
done
tippecanoe --version 2>&1 | head -1

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
  $PMTILES extract "$PLANET_URL" "$f" \
    --bbox="$tbbox" --minzoom="$minz" --maxzoom="$maxz" 2>&1 |
    grep -E 'Extract transferred|Region tiles' | sed 's/^/    /'
  TIER_FILES+=("$f")
done

# --- 4. merge the tiers ----------------------------------------------------

log "Merging the basemap tiers"

py "$ROOT/scripts/assemble.py" \
  "$WORK/basemap.mbtiles" \
  "$DATA_BOUNDS" "$CENTER_LON" "$CENTER_LAT" "$CENTER_ZOOM" \
  "${TIER_FILES[@]}"

# --- 5. Carleton's campus layers -------------------------------------------

log "Building the campus layers"

curl -fsSL -o "$WORK/campus-source.geojson" "$CAMPUS_GEOJSON_URL"
echo "  fetched $(wc -c < "$WORK/campus-source.geojson" | tr -d ' ') bytes from $CAMPUS_GEOJSON_URL"

py "$ROOT/scripts/campus-layers.py" "$WORK/campus-source.geojson" "$WORK"

# Nothing may be dropped: there are barely a hundred features and every one of
# them is a place someone might be trying to find. Hence --no-feature-limit and
# --no-tile-size-limit, and emphatically not --drop-densest-as-needed. Points
# are also dropped by default below the base zoom, which --drop-rate=1 disables.
tippecanoe -q -f -o "$WORK/campus_buildings.mbtiles" \
  --layer=campus_buildings \
  --minimum-zoom="$CAMPUS_BUILDINGS_MINZOOM" --maximum-zoom="$MAXZOOM" \
  --full-detail="$CAMPUS_DETAIL" \
  --no-feature-limit --no-tile-size-limit --no-tiny-polygon-reduction \
  "$WORK/campus_buildings.geojson"

tippecanoe -q -f -o "$WORK/campus_building_labels.mbtiles" \
  --layer=campus_building_labels \
  --minimum-zoom="$CAMPUS_LABELS_MINZOOM" --maximum-zoom="$MAXZOOM" \
  --full-detail="$CAMPUS_DETAIL" \
  --no-feature-limit --no-tile-size-limit --drop-rate=1 \
  "$WORK/campus_building_labels.geojson"

# --- 6. join into both published forms -------------------------------------

log "Joining campus layers into the basemap and converting"

# One archive and one tile tree for the app, rather than two sources to juggle.
tile-join -f -pk -o "$WORK/joined.mbtiles" \
  "$WORK/basemap.mbtiles" \
  "$WORK/campus_buildings.mbtiles" \
  "$WORK/campus_building_labels.mbtiles" >/dev/null

$PMTILES convert "$WORK/joined.mbtiles" "$DIST/campus.pmtiles" --tmpdir="$WORK" 2>&1 | sed 's/^/  /'
$PMTILES verify "$DIST/campus.pmtiles"
$PMTILES show "$DIST/campus.pmtiles" | grep -E 'zoom|bounds|tile type|compression|count' | sed 's/^/  /'

# The exploded tree comes from the joined archive, so the two published forms
# are the same tileset by construction.
log "Exploding to tiles/{z}/{x}/{y}.pbf (uncompressed)"
py "$ROOT/scripts/explode.py" "$DIST/campus.pmtiles" "$DIST/tiles"

# --- 7. glyphs and sprites -------------------------------------------------
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

# --- 8. styles -------------------------------------------------------------

log "Generating styles"

( cd "$ROOT" && { npm ci --silent 2>/dev/null || npm install --silent; } )

SITE_URL="$SITE_URL" \
DATA_BOUNDS="$DATA_BOUNDS" \
MINZOOM="$MINZOOM" \
MAXZOOM="$MAXZOOM" \
CENTER_LON="$CENTER_LON" CENTER_LAT="$CENTER_LAT" CENTER_ZOOM="$CENTER_ZOOM" \
CAMPUS_BUILDINGS_MINZOOM="$CAMPUS_BUILDINGS_MINZOOM" \
CAMPUS_LABELS_MINZOOM="$CAMPUS_LABELS_MINZOOM" \
OSM_BUILDINGS="$OSM_BUILDINGS" \
  node "$ROOT/scripts/make-style.mjs" "$DIST"

cp "$ROOT/site/index.html" "$DIST/index.html"
cp "$ROOT/site/.nojekyll" "$DIST/.nojekyll"

# Every mismatch this catches — style against schema, style against vendored
# assets — renders a blank or label-less map without raising an error, which is
# miserable to debug on device.
py "$ROOT/scripts/verify.py" "$DIST"

# --- 9. report -------------------------------------------------------------

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
