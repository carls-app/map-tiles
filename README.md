# map-tiles

Vector basemap tiles for [All About Olaf][aao]. Full detail over St. Olaf,
Carleton and the town of Northfield between them, with street-level coverage out
to Apple Valley in the north and Faribault in the south. Built from
OpenStreetMap, published to GitHub Pages.

**Live at <https://carls-app.github.io/map-tiles/>** — that page is also a
preview map you can pan around to check a build.

[aao]: https://github.com/StoDevX/AAO-React-Native

## What this is, and what it is not

An OpenStreetMap basemap — streets, water, landuse, building footprints, labels
— plus two layers of Carleton's own campus data joined into the same tileset.

**It is still not the campus dataset.** The two campus layers here carry a
footprint, a label anchor, a name and a `buildingId`, and nothing else. Room
data, departments, offices, hours, photos and prose all stay in ccc-server at
`carleton.api.frogpond.tech/v1/map/geojson`, downstream of
[`carls-app/map-data`][map-data], which the app fetches directly. This repo
copies the two fields a *map* needs and leaves the record alone.

[map-data]: https://github.com/carls-app/map-data

The cartography is deliberately quiet — the app draws its own selection
highlight on top of these layers. See [Cartography](#cartography) below.

## Carleton's campus layers

Built from the live endpoint, not [`carls-app/map-data`][map-data]'s
`map.geojson`, which is the same data frozen in 2018.

| Layer | Geometry | Zooms | Features | Properties |
| --- | --- | --- | ---: | --- |
| `campus_buildings` | MultiPolygon | z14+ | 96 | `buildingId`, `name`, `category` |
| `campus_building_labels` | Point | z15+ | 124 | `buildingId`, `name`, `category`, `hasFootprint` |

`buildingId` is the source feature's `id` and is on **both** layers — the app
keys its selection highlight off it, so it has to survive tiling.

Three things about the source shape drive `scripts/campus-layers.py`:

- Each feature is a **`GeometryCollection`** holding the polygon(s) and a point.
  Neither tippecanoe nor MapLibre supports that — it is valid GeoJSON that the
  style spec does not cover — and both fail *silently*, so it is unwrapped
  before tiling.
- A building with wings arrives as several polygons, merged here into one
  `MultiPolygon` so it highlights and hit-tests as a single building. (No
  feature in the current data actually has more than one polygon; the merge is
  what stops that from silently becoming several features if one gains a wing.)
- The points are **hand-placed label anchors, not centroids** — that is what
  `map-data`'s `overrides.yaml` exists to correct. They ship as their own layer
  rather than letting the renderer derive a position from the polygon.

Only 96 of the 124 features have a footprint. The other 28 are places, not
buildings — the Bald Spot, Lyman Lakes, the parking lots, the wind turbine.
They still get a label; `hasFootprint` is false so the app knows there is no
polygon to highlight.

Nothing is dropped at any stage: tippecanoe runs with `--no-feature-limit`,
`--no-tile-size-limit` and `--drop-rate=1`, emphatically not
`--drop-densest-as-needed`, and `campus-layers.py` fails the build if any source
feature reaches neither layer.

The two layers are merged into the basemap with `tile-join`, so the app consumes
one `campus.pmtiles` and one `tiles/{z}/{x}/{y}.pbf` tree. The exploded tree is
regenerated from the joined archive, so both published forms are the same
tileset by construction.

The whole pipeline is PMTiles end to end: `pmtiles merge` combines the zoom
tiers, tippecanoe writes the campus layers as PMTiles, and `tile-join` reads and
writes PMTiles too — so the published archive is produced directly, with no
MBTiles staging format and no format conversion. `pmtiles merge` also *requires*
its inputs to be disjoint, which turns "the tiers must not overlap" from an
assumption into something the build enforces.

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
MapLibre overzooms — scaling z15 tiles — beyond that.

**Nothing here caps how far the user can zoom in.** The MapLibre style spec has
no property for it; that is the map view's own `maxZoomLevel`, set by the app.

What the tileset does determine is how far in it still looks *sharp*.
Quantisation is tile size over tile extent, so the basemap's default 4096 units
per tile puts z15 geometry on a ~21 cm grid — one pixel at z18, two at z19, four
at z20, where stair-stepping starts to show.

The campus layers are stored at extent 16384 instead (`CAMPUS_DETAIL=14`),
which is ~5.3 cm and stays sub-pixel past z21. Buying the same precision by
tiling them to z17 would have cost 94 tiles instead of 7, plus ~250 KB of
overzoomed basemap to fill the z16/z17 tiles MapLibre would then start
requesting — which contain no basemap otherwise. Raising the extent costs
**+1,085 bytes**. Tile extent is a per-layer field in the MVT spec, so a single
tile carries `roads` at 4096 and `campus_buildings` at 16384 with no special
handling by the client.

This is not a compromise on detail. z15 is the Protomaps planet build's maximum,
and at that zoom it carries full-resolution building footprints and footpaths;
vector overzoom keeps them crisp because the geometry is scaled, not the pixels.
Rendering at z18 looks the same as native z18 tiles would.

## Area covered

Two bounding boxes, both at the top of `build.sh`:

| | Box | Extent |
| --- | --- | --- |
| `REGION_BBOX` | `-93.50,44.28,-92.84,44.75` | ~52 km square: Apple Valley in the north, Faribault in the south, the same distance east and west |
| `CAMPUS_BBOX` | `-93.28,44.38,-93.05,44.55` | Both campuses, downtown Northfield and Dundas, with room to pan |

The extract is **graduated** rather than one box across all zooms:

| Zooms | Box | Why |
| --- | --- | --- |
| z0–z13 | `REGION_BBOX` | The whole region, down to street level. |
| z14–z15 | `CAMPUS_BBOX` | Building footprints and footpaths, where the app actually operates. |

The split is where it is because one more zoom of the full region costs more than
everything else combined — z14 over `REGION_BBOX` alone measures 4.4 MB and 961
tiles — and nothing in a campus wayfinding app needs building footprints in
Faribault.

The source's `bounds` is the **union** of the tiers, computed at build time.
MapLibre culls tiles outside a source's declared bounds, so hardcoding it
narrower than the data would suppress tiles that had already been paid for.

### If you pinch out past the region

Below z9 each zoom is a single tile, and a tile at those zooms covers far more
than the region does — the z7 tile spans Minneapolis to central Iowa. So zooming
out shows more context, not less, right down to the whole world at z0.

What you *can* see, on a wide viewport, is the edge of that tile. On a phone it
is not reachable: one 512 px tile more than fills a ~390 pt screen at any zoom.
On an iPad in landscape, or when panning hard, the boundary shows.

Padding the low zooms fixes it and costs real money: a ±1° pad on z0–z9 measured
**+1.3 MB** against a 6.0 MiB archive. It is deliberately not enabled. To turn it
on, add a tier above the others and let the others start at z10:

```bash
TIERS=(
  "0:9:-94.2,43.5,-92.2,45.5"   # low-zoom padding
  "10:13:$REGION_BBOX"
  "14:15:$CAMPUS_BBOX"
)
```

## Output sizes

Measured on the 2026-08-12 build:

| | Size | Files |
| --- | ---: | ---: |
| `campus.pmtiles` | 6,399,990 B (6.1 MiB) | 1 |
| `tiles/**/*.pbf` | 8,543,202 B (8.1 MiB) | 985 |
| `fonts/**/*.pbf` | 11,083,630 B (10.6 MiB) | 768 |
| `sprites/` | 52,154 B | 4 |
| **site total** | **26,695,145 B (25.5 MiB)** | **1,764** |

Carleton's two campus layers cost **+69,222 B (+1.1%)** on the archive — 96
footprints and 124 label points over z14–z15.

Tiles per zoom:

```
z0=1   z1=1   z2=1   z3=1   z4=1    z5=1    z6=1     z7=1
z8=1   z9=2   z10=6  z11=20 z12=64  z13=256 z14=144  z15=484
```

For comparison, [`carls-app/map-data`][map-data] holds a **raster** tileset over
roughly this area at z12–z19: 2,677 PNGs, ~38 MB. The vector tileset here is
6.0 MiB as a PMTiles archive — about a sixth of that — while also covering z0–z11,
which the raster set does not.

The exploded tree is larger than the archive (8.1 MiB vs 6.0 MiB) because those
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

- **100 MB hard per-file limit.** `campus.pmtiles` is 6.0 MiB, so there is
  roughly 16× headroom. `build.sh` fails the build if it ever crosses the line
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

### The two building layers

Carleton's footprints and OSM's overlap on campus, and the two datasets disagree
about outlines. Comparing them, **OSM's are generally the more accurate** — it
picks up wings and extensions Carleton's polygons miss — so `campus_buildings`
is not trying to overrule them. It exists for the `buildingId` and for the app
to hit-test taps against.

Both layers are therefore painted **opaque, in the same colour**, which is the
only arrangement in which two overlapping fills union cleanly. The stock
Protomaps buildings layer is half-transparent; leaving it that way and matching
it means the overlap composites twice and lands four values per channel darker
than either layer alone. That is a small number and a very visible one — the eye
reads a low-contrast step on a flat field as an edge, so every building where
the two disagree grows a doubled outline: a lighter fringe around a darker core.

Two opaque layers in one colour cannot do that. Overlap, OSM-only and
campus-only all resolve to the same pixel, and a disagreement reads as one
slightly larger building. The colour is the stock fill flattened against the
earth beneath it, computed rather than hardcoded, so the map keeps the
appearance it had and stays right if the flavor changes.

`OSM_BUILDINGS` in `build.sh` controls the OSM layer:

| | |
| --- | --- |
| `full` | draw it normally — the default |
| `ghost` | fade it from `CAMPUS_BUILDINGS_MINZOOM` so only Carleton's read |
| `off` | omit it entirely |

With the doubling fixed, `off` is a **performance** lever rather than a
cartographic one: buildings are the densest polygons on the map, and at z17 over
campus the renderer draws every OSM footprint plus every Carleton one. Dropping
the OSM layer roughly halves that without touching `campus_buildings`, which the
app taps against and which therefore cannot be hidden.

## Building locally

Needs `bash`, `curl`, `git`, [`mise`](https://mise.jdx.dev), and **tippecanoe**
(which supplies `tile-join`):

```console
$ curl https://mise.run | sh
$ sudo apt-get install -y tippecanoe     # Debian/Ubuntu
$ brew install tippecanoe                # macOS
```

mise reads `mise.toml` and `mise.lock` and installs Python, Node, uv and the
`pmtiles` CLI at exactly the versions CI uses — `build.sh` runs `mise install`
itself, so a clean checkout needs nothing else. tippecanoe is the exception: it
is a C++ build with no prebuilt releases, so it stays a system package and the
build fails early with that hint if it is missing.

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

Everything tunable is in one block at the top of `build.sh`: `REGION_BBOX`,
`CAMPUS_BBOX`, `MINZOOM`, `MAXZOOM` and the `TIERS` array.

Editing the two boxes is usually enough, since `TIERS` refers to them. If you
need a different zoom split, edit `TIERS` — that is what actually drives
extraction. The data extent written into the styles is the union of the tiers,
computed at build time, so there is no second place to keep in sync.

The build refuses to start if the tiers leave a zoom gap, overlap, stop short of
`MAXZOOM`, or contain a bbox that is not `west,south,east,north` — all of which
otherwise fail silently, a gap showing up as a map that goes blank at one zoom
and comes back at the next. It also refuses to produce a `campus.pmtiles` over
the 100 MB Pages limit. Re-run and check the reported sizes.

Changing a bbox or a zoom moves the tile count and the archive size, so expect
to move `MIN_TILES` and `MIN_ARCHIVE_BYTES` (see [Floors](#floors)) with it. The
build says so by name when it stops.

Build intermediates live in `.work/` and are gitignored, along with `dist/`,
`*.osm.pbf`, `*.mbtiles` and `*.pmtiles`. None of them belong in git on either
branch.

## How publishing works

- **Source** — build script, workflow, README — lives on the default branch.
- **Built output** is force-pushed to `gh-pages` as a single fresh commit.

The force-push is unconditional and deliberate. This repo owns `gh-pages`
entirely; there is nothing there to preserve. Without it, every rebuild would
add another ~34 MB of blobs to history forever.

`.github/workflows/build.yml` runs on **every push to `main`**, **daily** at
07:00 UTC, on `workflow_dispatch`, and as a **dry run on every pull request**.

Publishing on push is what keeps the site from lagging the source: anything
merged here can change the output — a bbox, a zoom, a colour, a pinned tool
version — and waiting for the monthly cron means it silently stays stale until
someone dispatches a run by hand. Markdown is excluded via `paths-ignore`, since
documentation cannot change a tile. The PR run does everything except
publish: it builds, asserts no tile is gzipped, runs `scripts/verify.py`, and
writes the resulting sizes and layer counts to the run summary. The publish and
live-site steps are gated on `github.event_name != 'pull_request'`.

That gate exists because the workflow used to be unexercisable without merging
it, and three separate bugs were found that way — including a verification step
that passed in one second without verifying anything.
It needs `permissions: contents: write`, and Pages must be configured to serve
from the `gh-pages` branch. Before publishing, CI asserts that no tile is
gzipped and that every fontstack, sprite and attribution the styles name is
actually present — both are failures that render a broken map without erroring.

Daily is deliberate, and it is what makes fixing the map practical: Protomaps
rebuilds the planet every day from OSM minutely replication, and the build this
pulls from carries OSM data to about 04:00 UTC the same day. So an OSM edit
reaches the app roughly a day later without anyone touching this repo. 07:00 UTC
leaves the upstream build a few hours to publish.

Those daily builds are only retained for about a week and there is no index of
them, so `build.sh` probes backwards from today until one answers — which also
covers a run that fires before the day's build lands.

The publish step waits until Pages is actually serving the archive it just
built — comparing hashes, not just waiting for a `200` — before running its
checks. Waiting for a `200` is useless here: the previous deployment answers
`200` for the whole window, so the checks would pass against stale content and
prove nothing about what was pushed.

### Floors

Every other check here catches a *structural* failure: a layer the style names
but the tileset lacks, a source feature that reached neither campus layer, a
gzipped tile. None of them notice a build that is well-formed and simply holds
far less than it should — which is what a degraded upstream looks like. The
Carleton endpoint answering `200` with a handful of records passes every
assertion in `campus-layers.py`, because nothing was *dropped*; there was less
to drop. A truncated planet build is the same story.

That matters because the force-push is unconditional and the app renders this in
production: a bad build replaces a good one and stays up until the next daily
run. So four floors, in the same config block as `PAGES_FILE_LIMIT`:

| | Floor | Currently |
| --- | ---: | ---: |
| `MIN_CAMPUS_BUILDINGS` | 90 | 96 |
| `MIN_CAMPUS_LABELS` | 115 | 124 |
| `MIN_TILES` | 900 | 985 |
| `MIN_ARCHIVE_BYTES` | 5,000,000 | ~6.4 MB |

They are tripwires, not targets — set well below the current numbers so ordinary
drift never trips them, and a demolished building or a quiet week of OSM edits
does not fail a build. The two output floors are checked against the finished
`dist/`, not per-stage, so it does not matter which step came up short.

## Linting

`.github/workflows/lint.yml` runs on every push to `main` and every PR:

| Tool | Covers | Pinned in |
| --- | --- | --- |
| `ruff check` + `ruff format --check` | `scripts/*.py` | `pyproject.toml` / `uv.lock` |
| `oxlint` + `oxfmt --check` | `scripts/*.mjs` | `package.json` |
| `shellcheck` | `build.sh` | `mise.toml` / `mise.lock` |
| `actionlint` | the workflows themselves | `mise.toml` / `mise.lock` |

Run them locally with `npm run lint` (JS), `uv run ruff check scripts/ && uv run
ruff format --check scripts/`, and `shellcheck build.sh`.

ruff runs on its own floating defaults — no `[tool.ruff]` section — so its line
length and rule set track the pinned version rather than a local opinion.

`actionlint` is here for a specific reason: every workflow bug in this repo so
far only surfaced when a run actually happened, which meant merging first. It
catches the half of that which is statically detectable.

There is no TypeScript. `scripts/make-style.mjs` is one unannotated file, and a
`tsc --checkJs` pass over it reports only missing `@types/node` and implicit
`any` on unannotated parameters — no real findings — so it would be a dependency
and a config file for nothing. oxlint covers the correctness rules that do not
need types.

### Why the style generator is JavaScript

It is the only JS in the repo, and it is JS because `@protomaps/basemaps`
generates **71 of the style's 73 layers**. That package is the upstream
cartography for the exact tile schema this repo extracts, it is published only
to npm, and Renovate tracks it. Porting it to Python would mean owning those 71
layers by hand and re-porting them on every upstream release — which is the
schema/style drift described above, the failure that renders a blank map with no
error. The two layers this repo writes itself are the campus ones.

## Dependencies

Renovate keeps things current, configured in `renovate.json` off the same base
as [StoDevX/AAO-React-Native][aao]'s.

Everything is pinned, in four places:

| What | Where | How Renovate sees it |
| --- | --- | --- |
| `@protomaps/basemaps` | `package.json` | npm manager |
| `pmtiles` (Python), `ruff` | `pyproject.toml` / `uv.lock` | pep621 manager |
| `actions/*` | `.github/workflows/build.yml` | github-actions manager, digest-pinned |
| Python, Node, `uv`, `go-pmtiles`, `shellcheck`, `actionlint` | `mise.toml` / `mise.lock` | mise manager |
| `basemaps-assets` commit | `build.sh` | custom manager, `# renovate:` comment |
| `protomaps/basemaps-assets` | `build.sh` | custom manager, commit digest off `main` |

The `# renovate:` comments above the pins in `build.sh` are load-bearing — they
are what the custom managers match on. Detach one and that pin silently stops
being updated.

A **major** bump of `@protomaps/basemaps` needs dashboard approval rather than
landing on its own, because the style and the tile schema have to move together
and a mismatch renders a blank map with no error. See [Schema and style
pairing](#schema-and-style-pairing).

The style package version is not restated in `build.sh`;
`scripts/make-style.mjs` reads it from the installed package, so the number
recorded in the style is the one that generated it.

## Attribution

Two separate sources, credited separately:

- **Basemap** — map data © [OpenStreetMap
  contributors](https://www.openstreetmap.org/copyright), licensed under the
  [ODbL](https://opendatacommons.org/licenses/odbl/).
- **`campus_buildings` and `campus_building_labels`** — © [Carleton
  College](https://www.carleton.edu/). This is Carleton's data, not
  OpenStreetMap's, and must not be presented as the latter.

Both appear in each style JSON's source `attribution` field and must stay there
— MapLibre surfaces it in the map's attribution control, and the OSM half is a
license requirement, not a nicety:

```
© OpenStreetMap contributors | Carleton College
```

Fonts are Noto Sans, under the [SIL Open Font License](https://carls-app.github.io/map-tiles/fonts/OFL.txt).
Basemap style and sprites are from [Protomaps](https://github.com/protomaps/basemaps)
(BSD-3-Clause).
