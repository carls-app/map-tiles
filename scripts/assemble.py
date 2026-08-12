#!/usr/bin/env python3
"""Assemble the per-zoom-tier PMTiles extracts into the two published forms.

build.sh pulls several extracts out of the planet archive — a wide one for the
low zooms, progressively tighter ones as the zoom goes up (see TIERS in
build.sh). This merges them into:

  tiles/{z}/{x}/{y}.pbf   uncompressed, for the guaranteed-to-work path
  campus.mbtiles          gzipped, staging for `pmtiles convert`

Two things here matter more than they look:

1. The .pbf tree is *uncompressed*. Vector tiles are normally gzipped, but
   GitHub Pages will not set Content-Encoding on an arbitrary .pbf, so a gzipped
   tile arrives at the client as garbage with no error to explain it. The
   MBTiles/PMTiles side keeps its gzip, because those readers decompress
   from a declared compression field rather than an HTTP header.

2. The tree is XYZ; MBTiles is TMS. PMTiles hands back XYZ, which is what
   MapLibre asks for, and MBTiles wants the row flipped. Going tree -> MBTiles
   via mb-util instead of doing the flip here is the classic way to end up with
   a vertically mirrored map.
"""

import gzip
import json
import os
import sqlite3
import sys

from pmtiles.reader import MmapSource, Reader, all_tiles
from pmtiles.tile import Compression


def decompress(data: bytes, compression: Compression) -> bytes:
    if compression in (Compression.NONE, Compression.UNKNOWN):
        return data
    if compression == Compression.GZIP:
        return gzip.decompress(data)
    raise SystemExit(f"unsupported tile compression: {compression}")


def init_mbtiles(path: str) -> sqlite3.Connection:
    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.executescript(
        """
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        CREATE TABLE metadata (name text, value text);
        CREATE TABLE tiles (
            zoom_level integer,
            tile_column integer,
            tile_row integer,
            tile_data blob
        );
        CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
        """
    )
    return db


def main(argv: list[str]) -> None:
    outdir, mbtiles_path, bounds, center_lon, center_lat, center_zoom = argv[1:7]
    archives = argv[7:]
    if not archives:
        raise SystemExit("usage: assemble.py <tiledir> <out.mbtiles> <bounds> <clon> <clat> <cz> <archive...>")

    tree_dir = os.path.join(outdir)
    db = init_mbtiles(mbtiles_path)

    seen: set[tuple[int, int, int]] = set()
    source_metadata: dict = {}
    zoom_counts: dict[int, int] = {}
    raw_bytes = 0

    for archive in archives:
        with open(archive, "rb") as f:
            header = Reader(MmapSource(f)).header()
            compression = header["tile_compression"]
            if not source_metadata:
                source_metadata = Reader(MmapSource(f)).metadata()

            for (z, x, y), data in all_tiles(MmapSource(f)):
                # Tiers are disjoint zoom ranges, but never let a later tier
                # silently shadow an earlier one if that ever stops being true.
                if (z, x, y) in seen:
                    continue
                seen.add((z, x, y))

                raw = decompress(data, compression)
                if raw[:2] == b"\x1f\x8b":
                    raise SystemExit(f"tile {z}/{x}/{y} still gzipped after decompression")

                d = os.path.join(tree_dir, str(z), str(x))
                os.makedirs(d, exist_ok=True)
                with open(os.path.join(d, f"{y}.pbf"), "wb") as out:
                    out.write(raw)

                # MBTiles rows are TMS, counted from the south.
                db.execute(
                    "INSERT INTO tiles VALUES (?,?,?,?)",
                    (z, x, (1 << z) - 1 - y, gzip.compress(raw, mtime=0)),
                )

                zoom_counts[z] = zoom_counts.get(z, 0) + 1
                raw_bytes += len(raw)

    zooms = sorted(zoom_counts)
    metadata = {
        "name": "AAO Campus Basemap",
        "format": "pbf",
        "type": "baselayer",
        "version": "1",
        "description": "OpenStreetMap basemap for St. Olaf, Carleton and Northfield, MN",
        "attribution": '<a href="https://www.openstreetmap.org/copyright" target="_blank">&copy; OpenStreetMap contributors</a>',
        "bounds": bounds,
        "center": f"{center_lon},{center_lat},{center_zoom}",
        "minzoom": str(zooms[0]),
        "maxzoom": str(zooms[-1]),
        # vector_layers is what tells MapLibre which layers the tiles contain.
        # Losing it here yields a valid archive that renders nothing.
        "json": json.dumps({"vector_layers": source_metadata.get("vector_layers", [])}),
    }
    if not source_metadata.get("vector_layers"):
        raise SystemExit("source archive had no vector_layers metadata")

    db.executemany("INSERT INTO metadata VALUES (?,?)", metadata.items())
    db.commit()
    db.close()

    print(f"  {len(seen)} tiles, {raw_bytes / 1_000_000:.1f} MB uncompressed")
    print("  per zoom: " + " ".join(f"z{z}={zoom_counts[z]}" for z in zooms))


if __name__ == "__main__":
    main(sys.argv)
