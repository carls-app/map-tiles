#!/usr/bin/env python3
"""Cross-check the generated styles against the tileset that was actually built.

The failure this exists to catch is a schema/style mismatch, which does not
error anywhere — MapLibre asks for a `source-layer` the tiles do not contain,
finds nothing, and draws a blank map. Same class of silent failure as a style
naming a font it cannot fetch.

Run after both the tiles and the styles exist.
"""

import json
import os
import sys

from pmtiles.reader import MmapSource, Reader


def tileset_layers(archive: str) -> set[str]:
    with open(archive, "rb") as f:
        metadata = Reader(MmapSource(f)).metadata()
    layers = metadata.get("vector_layers")
    if layers is None and isinstance(metadata.get("json"), str):
        layers = json.loads(metadata["json"]).get("vector_layers")
    if not layers:
        raise SystemExit("archive declares no vector_layers")
    return {layer["id"] for layer in layers}


def fontstacks(value, found: set[str]) -> None:
    """Collect every fontstack named anywhere in a text-font value.

    text-font can be a plain list of names or an expression that picks between
    them, so this walks the whole structure rather than assuming a shape.
    """
    if isinstance(value, list):
        for item in value:
            fontstacks(item, found)
    elif isinstance(value, dict):
        for item in value.values():
            fontstacks(item, found)
    elif isinstance(value, str) and value.startswith("Noto Sans"):
        found.add(value)


def main(dist: str) -> None:
    available = tileset_layers(os.path.join(dist, "campus.pmtiles"))
    problems = []

    for name in ("style.json", "style-pmtiles.json"):
        path = os.path.join(dist, name)
        with open(path) as f:
            style = json.load(f)

        referenced = {
            layer["source-layer"]
            for layer in style["layers"]
            if "source-layer" in layer
        }
        for missing in sorted(referenced - available):
            problems.append(
                f"{name}: references source-layer {missing!r}, not in the tileset"
            )

        # Every layer must point at a source that exists, or it silently draws
        # nothing.
        sources = set(style["sources"])
        for layer in style["layers"]:
            if "source" in layer and layer["source"] not in sources:
                problems.append(
                    f"{name}: layer {layer['id']!r} uses unknown source {layer['source']!r}"
                )

        for source_id, source in style["sources"].items():
            if not source.get("attribution"):
                problems.append(
                    f"{name}: source {source_id!r} has no attribution (ODbL requires it)"
                )

        # Glyphs and sprites are absolute URLs into this same site; confirm the
        # files they point at were actually produced.
        site = style["glyphs"].split("/fonts/")[0]
        stacks: set[str] = set()
        for layer in style["layers"]:
            fontstacks(layer.get("layout", {}).get("text-font", []), stacks)
        if not stacks:
            problems.append(f"{name}: no fontstacks found — labels would not render")
        for stack in sorted(stacks):
            rel = (
                style["glyphs"]
                .replace(site, dist)
                .replace("{fontstack}", stack)
                .replace("{range}", "0-255")
            )
            if not os.path.exists(rel):
                problems.append(f"{name}: glyph range missing: {rel}")

        for suffix in (".json", ".png", "@2x.json", "@2x.png"):
            rel = style["sprite"].replace(site, dist) + suffix
            if not os.path.exists(rel):
                problems.append(f"{name}: sprite missing: {rel}")

    if problems:
        print("\n".join(f"  {p}" for p in problems), file=sys.stderr)
        raise SystemExit("style verification failed")

    print(
        f"  styles reference {len(available)} source-layers, all present: {', '.join(sorted(available))}"
    )
    print("  fontstacks, sprites and attribution all resolve")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "dist")
