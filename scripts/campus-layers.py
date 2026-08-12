#!/usr/bin/env python3
"""Split Carleton's campus GeoJSON into the two layers that get tiled.

The source gives one feature per place, whose geometry is a GeometryCollection
holding the footprint polygon(s) and a label anchor point. Three things about
that shape drive this script:

1. **GeometryCollection has to go.** Both tippecanoe and MapLibre reject it. It
   is valid GeoJSON that neither supports, and the failure is silent — the
   features simply never appear — so it is unwrapped here.

2. **The points are hand-placed label anchors, not centroids.** Carleton tuned
   them (that is what carls-app/map-data's overrides.yaml exists to do), so they
   ship as their own layer rather than letting the renderer derive a position
   from the polygon.

3. **A building with wings arrives as several polygons.** They are merged into a
   single MultiPolygon feature so the building highlights and hit-tests as one
   thing. (In the data as of this writing no feature actually has more than one
   polygon, but the merge is what keeps that from silently becoming several
   features if one gains a wing.)

Not every place has a footprint — the Bald Spot, Lyman Lakes and the parking
lots are anchor-only. Those still get a label; they just have no polygon, which
the labels layer records as hasFootprint=false so the app does not go looking
for one to highlight.
"""

import json
import os
import sys

# Kept deliberately small: every property here is paid for in every tile. The
# source carries floor lists, office lists, photo URLs and prose descriptions,
# none of which a basemap needs — the app already fetches the full record.
def properties(feature: dict) -> dict:
    props = feature.get("properties") or {}
    categories = props.get("categories") or []
    return {
        # The app keys its selection highlight off this, so it has to survive
        # tiling on both layers.
        "buildingId": feature["id"],
        "name": props.get("name") or "",
        "category": categories[0] if categories else "",
    }


def polygons_of(geometry: dict) -> list:
    """Every polygon in a geometry, as a list of MultiPolygon-shaped parts."""
    kind = geometry["type"]
    if kind == "Polygon":
        return [geometry["coordinates"]]
    if kind == "MultiPolygon":
        return list(geometry["coordinates"])
    return []


def main(src: str, outdir: str) -> None:
    data = json.load(open(src))
    features = data.get("features") or []
    if not features:
        raise SystemExit(f"{src}: no features")

    buildings = []
    labels = []
    problems = []

    for feature in features:
        geometry = feature.get("geometry") or {}
        parts = geometry.get("geometries") if geometry.get("type") == "GeometryCollection" else [geometry]
        parts = parts or []

        if not feature.get("id"):
            problems.append(f"feature with no id: {(feature.get('properties') or {}).get('name')!r}")
            continue

        rings = []
        points = []
        for part in parts:
            rings.extend(polygons_of(part))
            if part.get("type") == "Point":
                points.append(part["coordinates"])

        props = properties(feature)

        if rings:
            buildings.append({
                "type": "Feature",
                "geometry": {"type": "MultiPolygon", "coordinates": rings},
                "properties": props,
            })

        if len(points) > 1:
            problems.append(f"{feature['id']}: {len(points)} label anchors, using the first")
        if points:
            labels.append({
                "type": "Feature",
                "geometry": {"type": "Point", "coordinates": points[0]},
                "properties": {**props, "hasFootprint": bool(rings)},
            })
        else:
            problems.append(f"{feature['id']}: no label anchor, will not be labelled")

    os.makedirs(outdir, exist_ok=True)
    for name, collection in (("campus_buildings", buildings), ("campus_building_labels", labels)):
        with open(os.path.join(outdir, f"{name}.geojson"), "w") as out:
            json.dump({"type": "FeatureCollection", "features": collection}, out)

    multi = sum(1 for f in buildings if len(f["geometry"]["coordinates"]) > 1)
    print(f"  {len(features)} source features")
    print(f"  campus_buildings       {len(buildings)} footprints ({multi} merged from several polygons)")
    print(f"  campus_building_labels {len(labels)} anchors ({sum(1 for f in labels if not f['properties']['hasFootprint'])} without a footprint)")
    for problem in problems:
        print(f"  note: {problem}")

    # Every source feature must come through on at least one layer. The brief is
    # explicit that none of these may be dropped, and a silent shortfall here
    # would look identical to a tiling problem later.
    covered = {f["properties"]["buildingId"] for f in buildings} | {f["properties"]["buildingId"] for f in labels}
    missing = {f["id"] for f in features if f.get("id")} - covered
    if missing:
        raise SystemExit(f"  {len(missing)} source features reached neither layer: {sorted(missing)[:10]}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: campus-layers.py <campus.geojson> <outdir>")
    main(sys.argv[1], sys.argv[2])
