// Generate the two MapLibre styles this site publishes.
//
//   style.json          plain {z}/{x}/{y}.pbf source — works everywhere
//   style-pmtiles.json  pmtiles:// source — only if the binary was built with
//                       MLN_WITH_PMTILES (see README)
//
// Both are the same cartography over the same tiles; only the source differs.

import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { layers, namedFlavor } from "@protomaps/basemaps";

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
const STYLE_MAXZOOM = Number(env("STYLE_MAXZOOM"));
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

const ATTRIBUTION =
  '<a href="https://www.openstreetmap.org/copyright" target="_blank">&copy; OpenStreetMap contributors</a>';

const base = {
  version: 8,
  name: "All About Olaf Campus Basemap",
  metadata: {
    "aao:generated-by": "carls-app/map-tiles",
    "aao:schema": "protomaps basemap v4",
    "aao:style-package": `@protomaps/basemaps@${env("BASEMAPS_STYLE_VERSION")}`,
    "aao:note":
      "Basemap only. Campus building polygons come from ccc-server " +
      "(carleton.api.frogpond.tech/v1/map/geojson) and are drawn by the app on top of this.",
  },
  center: CENTER,
  zoom: CENTER_ZOOM,
  bearing: 0,
  pitch: 0,
  glyphs: `${SITE_URL}/fonts/{fontstack}/{range}.pbf`,
  sprite: `${SITE_URL}/sprites/sprite`,
  layers: styleLayers,
};

// The tileset stops at MAXZOOM; MapLibre scales those tiles the rest of the way
// to STYLE_MAXZOOM rather than requesting tiles that do not exist.
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

console.log(`  style.json          ${styleLayers.length} layers, tiles/{z}/{x}/{y}.pbf, z${MINZOOM}-z${MAXZOOM} (overzoom to z${STYLE_MAXZOOM})`);
console.log(`  style-pmtiles.json  ${styleLayers.length} layers, pmtiles://${SITE_URL}/campus.pmtiles`);

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
console.log(`  fontstacks verified: ${named.sort().join(", ")}`);
