#!/usr/bin/env python3
"""Merge the per-zoom-tier PMTiles extracts into one MBTiles staging file.

build.sh pulls several extracts out of the planet archive — a wide one for the
low zooms, a tighter one as the zoom goes up (see TIERS in build.sh). This
merges them into a single MBTiles, which is then joined with the campus layers
and converted to the published PMTiles archive.

The tiles are XYZ coming out of PMTiles and TMS going into MBTiles, so the row
is flipped here. Getting that wrong mirrors the map vertically, and nothing
downstream would complain.
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
    mbtiles_path, bounds, center_lon, center_lat, center_zoom = argv[1:6]
    archives = argv[6:]
    if not archives:
        raise SystemExit("usage: assemble.py <out.mbtiles> <bounds> <clon> <clat> <cz> <archive...>")

    db = init_mbtiles(mbtiles_path)

    seen: set[tuple[int, int, int]] = set()
    source_metadata: dict = {}
    zoom_counts: dict[int, int] = {}

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
                # MBTiles rows are TMS, counted from the south.
                db.execute(
                    "INSERT INTO tiles VALUES (?,?,?,?)",
                    (z, x, (1 << z) - 1 - y, gzip.compress(raw, mtime=0)),
                )
                zoom_counts[z] = zoom_counts.get(z, 0) + 1

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

    print(f"  {len(seen)} basemap tiles")
    print("  per zoom: " + " ".join(f"z{z}={zoom_counts[z]}" for z in zooms))


if __name__ == "__main__":
    main(sys.argv)
