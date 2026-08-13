// Generate the two MapLibre styles this site publishes.
//
//   style.json          plain {z}/{x}/{y}.pbf source — works everywhere
//   style-pmtiles.json  pmtiles:// source — only if the binary was built with
//                       MLN_WITH_PMTILES (see README)
//
// Both are the same cartography over the same tiles; only the source differs.

import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { layers, namedFlavor } from "@protomaps/basemaps";

// Read the version off the package that is actually installed, rather than
// restating it in build.sh. The style and the tile schema have to move
// together, so the number recorded in the style should be the one that
// generated it, not a second copy that can drift.
const basemapsVersion = createRequire(import.meta.url)("@protomaps/basemaps/package.json").version;

const out = process.argv[2];
if (!out) throw new Error("usage: make-style.mjs <outdir>");

const env = (k) => {
  const v = process.env[k];
  if (v === undefined || v === "") throw new Error(`missing env ${k}`);
  return v;
};

const SITE_URL = env("SITE_URL").replace(/\/$/, "");
// The extent of the merged tileset — the widest extraction tier, not the campus
// bbox. MapLibre culls tiles outside a source's `bounds`, so narrowing this to
// campus would suppress every low-zoom context tile.
const [west, south, east, north] = env("DATA_BOUNDS").split(",").map(Number);
const MINZOOM = Number(env("MINZOOM"));
const MAXZOOM = Number(env("MAXZOOM"));
const CENTER = [Number(env("CENTER_LON")), Number(env("CENTER_LAT"))];
const CENTER_ZOOM = Number(env("CENTER_ZOOM"));

// ---------------------------------------------------------------------------
// Cartography
// ---------------------------------------------------------------------------
//
// This is a campus wayfinding basemap. All About Olaf draws its own building
// polygons and markers on top of it, so the job here is to stay out of their
// way: the Protomaps "light" flavor, pulled further down in contrast.
//
// The three deliberate departures from stock "light":
//
//   buildings  Stock draws them at #cccccc, clearly darker than the ground.
//              AAO paints the campus buildings itself, so basemap footprints
//              underneath them read as a doubled, misregistered outline. Pulled
//              down until they read as texture rather than as subject — still
//              legible downtown, where they are the only building data there is,
//              but no longer competing with the app's own polygons on campus.
//
//   water      Stock is a vivid cyan (#80deea). On a map whose foreground is
//              app-drawn markers, the Cannon River should not be the brightest
//              thing on screen. Muted to a calm blue-gray that still reads
//              unmistakably as water.
//
//   parks      Northfield's two campuses are mostly green space, so stock's
//              saturated park green covers much of the frame. Desaturated so
//              the campuses read as ground rather than as highlighted areas.

const flavor = {
  ...namedFlavor("light"),

  background: "#e8e6e1",

  buildings: "#d5d0c7",

  water: "#c3d4de",
  zoo: "#d6dedd",

  park_a: "#dde3da",
  park_b: "#cbd9c9",
  wood_a: "#dbe1d8",
  wood_b: "#cbd7c6",
  scrub_a: "#dde2da",
  scrub_b: "#cdd8c9",

  // Institutional land — both campuses are tagged this way. Keep it a whisper
  // above the base earth tone so the campus boundary is legible but not loud.
  school: "#e6e2db",
  hospital: "#e6e0de",
  industrial: "#e0e2e1",
};

const styleLayers = layers("basemap", flavor, { lang: "en" });

// ---------------------------------------------------------------------------
// Carleton's campus layers
// ---------------------------------------------------------------------------
//
// These ride in the same source as the basemap — tile-join merged them into one
// tileset — so they are separate `source-layer`s, not a separate source.
//
// The polygons and the label points are two layers rather than one because the
// points are hand-placed anchors, not centroids. Letting the renderer derive a
// position from the polygon would throw away the tuning that
// carls-app/map-data's overrides.yaml exists to capture.

const CAMPUS_BUILDINGS_MINZOOM = Number(env("CAMPUS_BUILDINGS_MINZOOM"));
const CAMPUS_LABELS_MINZOOM = Number(env("CAMPUS_LABELS_MINZOOM"));
const OSM_BUILDINGS = env("OSM_BUILDINGS");

// Quiet on purpose: the app draws its own selection highlight on top of these,
// and a loud base layer would fight it.
//
// The fill is the *same* colour as the basemap's own buildings, and carries no
// outline, which is what keeps the two datasets from arguing. OSM's outlines
// are generally the more accurate of the two — comparing them over campus, OSM
// picks up wings and extensions that Carleton's polygons miss — so this layer
// is not trying to overrule them. Painted in the same grey with no edge, the
// overlap is invisible and a disagreement reads as one slightly larger
// building rather than a doubled, misregistered outline.
//
// It still has to be *drawn*: the app hit-tests taps against this layer's
// rendered geometry to resolve a buildingId, so it cannot be hidden.
//
// Both building layers are painted **opaque, in the same colour**, and that is
// the whole trick. The stock Protomaps layer is half-transparent; leaving it
// that way and matching it means the overlap composites twice and lands about
// four values per channel darker than either layer alone. That is a small
// number and a very visible one — the eye reads a low-contrast step on a flat
// field as an edge, so every building where the two datasets disagree grows a
// doubled outline: a lighter fringe around a darker core.
//
// Two opaque layers in one colour cannot do that. Overlap, OSM-only and
// campus-only all resolve to the same pixel, so a disagreement reads as one
// slightly larger building instead of two misregistered ones.
//
// The colour is the stock fill flattened against the earth beneath it, so the
// map keeps the appearance it had before — computed rather than hardcoded, so
// it stays right if the flavor changes.
const stockBuildings = styleLayers.find((l) => l.id === "buildings");
if (!stockBuildings) throw new Error("expected a basemap layer called buildings");

const parseHex = (hex) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));

const flatten = (fg, bg, alpha) => {
  if (typeof alpha !== "number") return fg; // an expression: leave it be
  const [fr, fg_, fb] = parseHex(fg);
  const [br, bg_, bb] = parseHex(bg);
  const mix = (f, b) => Math.round(b * (1 - alpha) + f * alpha);
  return (
    "#" +
    [mix(fr, br), mix(fg_, bg_), mix(fb, bb)].map((v) => v.toString(16).padStart(2, "0")).join("")
  );
};

const BUILDING_FILL = flatten(
  stockBuildings.paint["fill-color"],
  flavor.earth,
  stockBuildings.paint["fill-opacity"],
);
const BUILDING_PAINT = { "fill-color": BUILDING_FILL, "fill-opacity": 1 };

const campusLayers = [
  {
    id: "campus_buildings",
    type: "fill",
    source: "basemap",
    "source-layer": "campus_buildings",
    minzoom: CAMPUS_BUILDINGS_MINZOOM,
    paint: { ...BUILDING_PAINT },
  },
  {
    id: "campus_building_labels",
    type: "symbol",
    source: "basemap",
    "source-layer": "campus_building_labels",
    minzoom: CAMPUS_LABELS_MINZOOM,
    layout: {
      "text-field": ["get", "name"],
      // Must name a stack the site actually hosts under `glyphs`. A stack that
      // is not there renders no labels and reports nothing; build.sh checks it.
      "text-font": ["Noto Sans Medium"],
      "text-size": ["interpolate", ["linear"], ["zoom"], 15, 10, 18, 13],
      "text-anchor": "center",
      "text-max-width": 8,
      "text-padding": 2,
    },
    paint: {
      "text-color": "#4f4b45",
      "text-halo-color": "#f0eeea",
      "text-halo-width": 1.2,
    },
  },
];

// Where they go: above the basemap's own buildings, below its street labels.
// Found by layer id rather than index, so an upstream reshuffle of the
// Protomaps layer list cannot silently put them somewhere else.
const insertAfter = (id) => {
  const i = styleLayers.findIndex((l) => l.id === id);
  if (i < 0) throw new Error(`expected a basemap layer called ${id}`);
  return i + 1;
};
const insertBefore = (id) => {
  const i = styleLayers.findIndex((l) => l.id === id);
  if (i < 0) throw new Error(`expected a basemap layer called ${id}`);
  return i;
};

// The label layer goes in first, at the higher index, so inserting the fill
// below it does not shift the position that was just computed.
styleLayers.splice(insertBefore("address_label"), 0, campusLayers[1]);
styleLayers.splice(insertAfter("buildings"), 0, campusLayers[0]);

// How much of the basemap's own OSM building layer to draw. Since the campus
// fill matches it exactly, "full" is the default and the two datasets simply
// union — OSM keeps its better outlines, and downtown Northfield, which has no
// campus data at all, keeps its buildings.
//
// The other two settings exist because these are the densest polygons on the
// map: at z17 over campus the renderer is drawing every OSM footprint plus
// every Carleton one. If that turns out to cost too much on device, dropping
// the OSM layer roughly halves the building geometry without touching the
// campus layer the app taps against.
const osmBuildingsIndex = styleLayers.findIndex((l) => l.id === "buildings");
stockBuildings.paint = { ...BUILDING_PAINT };
if (OSM_BUILDINGS === "off") {
  styleLayers.splice(osmBuildingsIndex, 1);
} else if (OSM_BUILDINGS === "ghost") {
  const osmBuildings = styleLayers[osmBuildingsIndex];
  osmBuildings.paint = {
    ...osmBuildings.paint,
    "fill-opacity": [
      "interpolate",
      ["linear"],
      ["zoom"],
      CAMPUS_BUILDINGS_MINZOOM - 1,
      1,
      CAMPUS_BUILDINGS_MINZOOM + 1,
      0.3,
    ],
  };
} else if (OSM_BUILDINGS !== "full") {
  throw new Error(`OSM_BUILDINGS must be one of full, ghost, off — got "${OSM_BUILDINGS}"`);
}

// Defined once in build.sh, so the styles and the archive's own metadata cannot
// drift apart. Carleton's building data is Carleton's, not OpenStreetMap's, and
// is credited separately for that reason.
const ATTRIBUTION = env("ATTRIBUTION");

const base = {
  version: 8,
  name: "All About Olaf Campus Basemap",
  metadata: {
    "aao:generated-by": "carls-app/map-tiles",
    "aao:schema": "protomaps basemap v4",
    "aao:style-package": `@protomaps/basemaps@${basemapsVersion}`,
    "aao:campus-layers": "campus_buildings, campus_building_labels",
    "aao:osm-buildings": OSM_BUILDINGS,
    "aao:note":
      "OSM basemap plus Carleton's own building footprints and label anchors, from " +
      "carleton.api.frogpond.tech/v1/map/geojson. Both campus layers carry buildingId. " +
      "The app draws its selection highlight on top of these.",
  },
  center: CENTER,
  zoom: CENTER_ZOOM,
  bearing: 0,
  pitch: 0,
  glyphs: `${SITE_URL}/fonts/{fontstack}/{range}.pbf`,
  sprite: `${SITE_URL}/sprites/sprite`,
  layers: styleLayers,
};

// The tileset stops at MAXZOOM; MapLibre scales those tiles beyond it rather
// than requesting tiles that do not exist. Nothing here caps how far the user
// can zoom — the style spec has no property for it, so that is the map view's
// maxZoomLevel, set by the app.
const sourceCommon = {
  type: "vector",
  attribution: ATTRIBUTION,
  bounds: [west, south, east, north],
};

writeFileSync(
  join(out, "style.json"),
  JSON.stringify(
    {
      ...base,
      sources: {
        basemap: {
          ...sourceCommon,
          tiles: [`${SITE_URL}/tiles/{z}/{x}/{y}.pbf`],
          minzoom: MINZOOM,
          maxzoom: MAXZOOM,
        },
      },
    },
    null,
    2,
  ) + "\n",
);

writeFileSync(
  join(out, "style-pmtiles.json"),
  JSON.stringify(
    {
      ...base,
      name: `${base.name} (PMTiles)`,
      sources: {
        basemap: {
          ...sourceCommon,
          url: `pmtiles://${SITE_URL}/campus.pmtiles`,
        },
      },
    },
    null,
    2,
  ) + "\n",
);

console.log(
  `  campus layers       campus_buildings (z${CAMPUS_BUILDINGS_MINZOOM}+), campus_building_labels (z${CAMPUS_LABELS_MINZOOM}+), OSM buildings: ${OSM_BUILDINGS}`,
);
console.log(
  `  style.json          ${styleLayers.length} layers, tiles/{z}/{x}/{y}.pbf, z${MINZOOM}-z${MAXZOOM} (overzoomed beyond)`,
);
console.log(
  `  style-pmtiles.json  ${styleLayers.length} layers, pmtiles://${SITE_URL}/campus.pmtiles`,
);

// Guard against the failure mode the README warns about: a style naming a
// fontstack the site does not host renders with no labels and no error.
const fonts = new Set();
const walk = (v) => {
  if (Array.isArray(v)) v.forEach(walk);
  else if (v && typeof v === "object") Object.values(v).forEach(walk);
  else if (typeof v === "string") fonts.add(v);
};
for (const l of styleLayers) if (l.layout?.["text-font"]) walk(l.layout["text-font"]);
const expected = new Set(["Noto Sans Regular", "Noto Sans Medium", "Noto Sans Italic"]);
const named = [...fonts].filter((f) => f.startsWith("Noto Sans"));
const missing = named.filter((f) => !expected.has(f));
if (missing.length) {
  throw new Error(`style names fontstacks the build does not vendor: ${missing.join(", ")}`);
}
console.log(`  fontstacks verified: ${named.toSorted().join(", ")}`);
