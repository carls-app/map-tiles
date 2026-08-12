# map-tiles

Vector basemap tiles for [All About Olaf][aao], covering St. Olaf, Carleton and
the town of Northfield between them. Built from OpenStreetMap, published to
GitHub Pages.

**Live at <https://carls-app.github.io/map-tiles/>** — that page is also a
preview map you can pan around to check a build.

[aao]: https://github.com/StoDevX/AAO-React-Native

## What this is, and what it is not

This repo produces the map that renders *underneath* the app's own content:
streets, water, landuse, building footprints, labels. That is all.

**Campus building data is not here and must not be added here.** AAO fetches
building polygons from ccc-server at
`carleton.api.frogpond.tech/v1/map/geojson`, downstream of
[`carls-app/map-data`][map-data], and draws them on top of this basemap. If you
came here looking for building outlines, room data or campus geometry, you want
that repo, not this one.

[map-data]: https://github.com/carls-app/map-data

The cartography is deliberately quiet for that reason — see
[Cartography](#cartography) below.

## Using it from AAO

In `source/features/map/urls.ts`:

```ts
export const MAP_STYLE_URL = 'https://carls-app.github.io/map-tiles/style.json'
```

That replaces the `https://demotiles.maplibre.org/style.json` placeholder. It is
a drop-in swap; nothing else in the app needs to change.

### Why `style.json` and not `style-pmtiles.json`

The same tileset is published twice, with a style for each:

| Style | Source | Works when |
| --- | --- | --- |
| [`style.json`](https://carls-app.github.io/map-tiles/style.json) | `tiles/{z}/{x}/{y}.pbf` | always |
| [`style-pmtiles.json`](https://carls-app.github.io/map-tiles/style-pmtiles.json) | `pmtiles://…/campus.pmtiles` | only if the MapLibre binary was compiled with PMTiles support |

This is not redundancy for its own sake. In MapLibre GL JS you register the
`pmtiles://` protocol at runtime with `addProtocol`. **In MapLibre Native you
cannot** — PMTiles is the compile-time CMake option `MLN_WITH_PMTILES`. AAO's
iOS build consumes a *prebuilt* `MapLibre.xcframework` from
`maplibre-gl-native-distribution` via SwiftPM, and the Expo config plugin
exposes only `nativeVersion` and `spmSpec`. Nothing in the app repo can set that
flag, and whether the shipped binary has the provider compiled in is unverified.

So `style.json` is the default and the supported path. `style-pmtiles.json` is
there to try — if it renders, it is one request for the whole tileset instead of
one per tile, which is a real win on a cold start. If it renders blank, that is
your answer, and nothing was lost.

Both styles are otherwise identical: same layers, same colors, same tiles.

## Schema and style pairing

The tiles are **Protomaps Basemap schema v4** (v4.15.2 at the time of writing),
because they are extracted from the Protomaps daily planet build. The style is
generated from [`@protomaps/basemaps`][pmb] v5.7.2, which is the matching style
package for that schema.

**These two must move together.** A schema/style mismatch does not error — it
renders a blank map. If you regenerate tiles from a different source
(Planetiler's OpenMapTiles output, say), you must also swap to an
OpenMapTiles-schema style such as Positron or OSM Bright, and vice versa.

[pmb]: https://www.npmjs.com/package/@protomaps/basemaps

Two more things worth knowing on the AAO side:

- **Layer names** are Protomaps', not OpenMapTiles'. The tileset declares nine:
  `boundaries`, `buildings`, `earth`, `landcover`, `landuse`, `places`, `pois`,
  `roads`, `water`. If the app ever adds its own layers reading from the basemap
  source, those are the `source-layer` values to use. `build.sh` verifies that
  the style references all nine and nothing else, since a reference to a layer
  the tiles do not contain draws nothing and reports nothing.
- **The source id is `basemap`.** Layers the app inserts can be positioned
  relative to the style's layers by id; all basemap layer ids are Protomaps'
  stock ids.

## Zoom levels

The tileset is **z0–z15**. The style declares `maxzoom: 15` on the source, and
MapLibre overzooms — scaling z15 tiles — up to z18 and beyond.

This is not a compromise on detail. z15 is the Protomaps planet build's maximum,
and at that zoom it carries full-resolution building footprints and footpaths;
vector overzoom keeps them crisp because the geometry is scaled, not the pixels.
Rendering at z18 looks the same as native z18 tiles would.

The extract is **graduated**, not a single bounding box across all zooms:

| Zooms | Bounding box | Why |
| --- | --- | --- |
| z0–z8 | `-97.9,42.4,-88.4,49.6` | Upper Midwest. Pinching out shows Minneapolis and I-35, not a void. |
| z9–z12 | `-93.55,44.30,-92.80,44.75` | Northfield and its approach roads. |
| z13–z14 | `-93.28,44.38,-93.05,44.55` | Town and immediate surroundings. |
| z15 | `-93.20,44.44,-93.12,44.49` | Campus detail. |

The naive alternative — one campus-sized bbox at every zoom — was tried first
and looks broken. Below about z10 a single tile covers the entire bounding box,
so the map becomes one lonely rectangle of data with a hard edge all around it.
The pyramid above costs a few megabytes and fixes it completely.

The source's `bounds` is the **widest** tier, for the same reason: MapLibre culls
tiles outside a source's declared bounds, so narrowing it to the campus bbox
would suppress every low-zoom context tile and undo the tiers.

## Output sizes

Measured on the 2026-08-12 build:

| | Size | Files |
| --- | ---: | ---: |
| `campus.pmtiles` | 9,790,896 B (9.3 MiB) | 1 |
| `tiles/**/*.pbf` | 13,911,459 B (13.3 MiB) | 485 |
| `fonts/**/*.pbf` | 11,083,630 B (10.6 MiB) | 768 |
| `sprites/` | 52,154 B | 4 |
| **site total** | **35,378,483 B (33.7 MiB)** | **1,263** |

Tiles per zoom:

```
z0=1  z1=1  z2=2  z3=2   z4=2   z5=4    z6=9   z7=20
z8=64 z9=6  z10=12 z11=30 z12=80 z13=36 z14=144 z15=72
```

For comparison, [`carls-app/map-data`][map-data] holds a **raster** tileset over
roughly the same area at z12–z19: 2,677 PNGs, ~38 MB. The vector tileset here is
9.3 MiB as a PMTiles archive — about a quarter of that — while covering far more
ground at low zoom.

The exploded tree is larger than the archive (13.3 MiB vs 9.3 MiB) because those
tiles are stored **uncompressed**; see [GitHub Pages
constraints](#github-pages-constraints).

The glyphs are the largest single component and have nothing to do with the
tiles. That is 3 fontstacks × 256 Unicode ranges. It looks disproportionate for a
map of Minnesota, and at runtime it is: a device fetches the Latin range and
essentially nothing else. Full coverage is kept because the z0–z8 tier carries
global city and country labels, so any script can appear when the user pinches
all the way out, and a missing glyph range fails silently.

## GitHub Pages constraints

These are the ones that actually bite:

- **100 MB hard per-file limit.** `campus.pmtiles` is 9.3 MiB, so there is
  roughly 10× headroom. `build.sh` fails the build if it ever crosses the line
  rather than letting it break at request time.
- **Git LFS does not work on Pages.** Pages serves the LFS *pointer file*, not
  the object. If the archive ever outgrows 100 MB, move it to a GitHub Release
  asset (2 GB/file, range requests work) — do not reach for LFS.
- **1 GB site / 100 GB per month bandwidth**, both soft. At 34 MiB this is not
  close to either.
- **`.pbf` tiles are stored uncompressed.** Vector tiles are normally gzipped,
  but Pages will not set `Content-Encoding` on an arbitrary `.pbf`, so a gzipped
  tile arrives as garbage with no error to explain it. The PMTiles archive keeps
  its internal gzip, because PMTiles readers decompress from a declared field
  rather than an HTTP header. CI asserts the tree is not gzipped on every build.

### Range requests: verified, with a catch

**GitHub Pages does honour Range requests.** A real GET returns `206`:

```console
$ curl -sS -r 0-99 -D - -o /dev/null https://carls-app.github.io/map-tiles/campus.pmtiles
HTTP/2 206
accept-ranges: bytes
content-range: bytes 0-99/9790896
content-length: 100
```

**But `curl -r 0-99 -I` returns `200`, not `206`.** `-I` sends a HEAD request,
and Pages answers HEAD with a `200` and the full `content-length`, ignoring the
Range header:

```console
$ curl -sS -r 0-99 -I https://carls-app.github.io/map-tiles/campus.pmtiles
HTTP/2 200
accept-ranges: bytes
content-length: 9790896
```

If you check with `-I` you will conclude Range is unsupported and be wrong. Use a
GET.

Byte-serving was also verified end to end by reading a tile out of the published
archive over HTTP range requests and comparing it to the same tile in the
exploded tree:

```console
$ pmtiles tile https://carls-app.github.io/map-tiles/campus.pmtiles 15 7904 11856 | gunzip | sha256sum
d33e62e090d1526f…
$ sha256sum dist/tiles/15/7904/11856.pbf
d33e62e090d1526f…
```

Identical. The two published forms are the same tileset.

## Cartography

A campus wayfinding map, so the basemap's job is to stay out of the way of the
building polygons and markers AAO draws on top of it. The style is the Protomaps
`light` flavor pulled further down in contrast, with three deliberate departures
from stock:

- **Buildings** are muted well below stock's `#cccccc`. AAO paints the campus
  buildings itself, and basemap footprints underneath them read as a doubled,
  misregistered outline. They stay legible downtown, where they are the only
  building data there is.
- **Water** is a calm blue-grey instead of stock's vivid cyan. The Cannon River
  should not be the brightest thing on a screen whose foreground is app-drawn
  markers.
- **Parks and woods** are desaturated. Both campuses are largely green space, so
  stock's saturated park green covered most of the frame and read as
  highlighting rather than ground.

These live in one `flavor` object at the top of `scripts/make-style.mjs`.

## Building locally

Needs `bash`, `curl`, `git`, `python3` (3.9+) and `node` (20+). Everything else —
the `pmtiles` CLI, the Python library, the font and sprite assets — is fetched
and pinned by the script.

```console
$ ./build.sh
```

Takes about 25 seconds from a completely clean checkout — it pulls a few hundred
tiles out of the planet archive over range requests rather than downloading and
processing an OSM extract. Output lands in `dist/`, which is exactly what gets
published. Nothing is committed to the default branch.

To preview, serve `dist/` and open it — but note that the styles contain
absolute `https://carls-app.github.io/…` URLs, so a local server alone will
still pull tiles from the published site. To preview a *local* build end to end:

```console
$ SITE_URL=http://localhost:8080 ./build.sh
$ python3 -m http.server 8080 -d dist
```

(The preview page's `pmtiles://` option needs a server that supports Range
requests; `python3 -m http.server` does not, so that option will fail locally
while working fine on Pages.)

### Changing the bbox or zooms

Everything tunable is in one block at the top of `build.sh`: `BBOX`, `MINZOOM`,
`MAXZOOM`, `STYLE_MAXZOOM` and the `TIERS` array.

If you widen the area, change `TIERS` — that is what actually drives extraction.
The data extent written into the styles is the union of the tiers, computed at
build time, so there is no second place to keep in sync.

The build refuses to start if the tiers leave a zoom gap, overlap, stop short of
`MAXZOOM`, or contain a bbox that is not `west,south,east,north` — all of which
otherwise fail silently, a gap showing up as a map that goes blank at one zoom
and comes back at the next. It also refuses to produce a `campus.pmtiles` over
the 100 MB Pages limit. Re-run and check the reported sizes.

Build intermediates live in `.work/` and are gitignored, along with `dist/`,
`*.osm.pbf`, `*.mbtiles` and `*.pmtiles`. None of them belong in git on either
branch.

## How publishing works

- **Source** — build script, workflow, README — lives on the default branch.
- **Built output** is force-pushed to `gh-pages` as a single fresh commit.

The force-push is unconditional and deliberate. This repo owns `gh-pages`
entirely; there is nothing there to preserve. Without it, every rebuild would
add another ~34 MB of blobs to history forever.

`.github/workflows/build.yml` runs on `workflow_dispatch` and monthly on the 3rd.
It needs `permissions: contents: write`, and Pages must be configured to serve
from the `gh-pages` branch. Before publishing, CI asserts that no tile is
gzipped and that every fontstack, sprite and attribution the styles name is
actually present — both are failures that render a broken map without erroring.

Monthly is deliberate: OSM data for a college town does not move fast, and the
Protomaps daily builds this pulls from are only retained for about a week, so
`build.sh` probes backwards from today to find one.

## Attribution

Map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright),
licensed under the [ODbL](https://opendatacommons.org/licenses/odbl/). The
attribution is set in both style JSONs' source `attribution` field and must stay
there — MapLibre surfaces it in the map's attribution control, and it is a
license requirement, not a nicety.

Fonts are Noto Sans, under the [SIL Open Font License](https://carls-app.github.io/map-tiles/fonts/OFL.txt).
Basemap style and sprites are from [Protomaps](https://github.com/protomaps/basemaps)
(BSD-3-Clause).
