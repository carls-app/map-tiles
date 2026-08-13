#!/usr/bin/env python3
"""Explode the published PMTiles archive into a tiles/{z}/{x}/{y}.pbf tree.

Runs on the *joined* archive, so the directory tree and the single-file archive
are the same tileset — basemap plus campus layers — rather than two things that
could drift.

The tiles come out uncompressed. Vector tiles are normally gzipped, but GitHub
Pages will not set Content-Encoding on an arbitrary .pbf, so a gzipped tile
arrives at the client as garbage with no error to explain it. The archive keeps
its internal gzip, because PMTiles readers decompress from a declared field
rather than an HTTP header.

Coordinates are XYZ, which is what MapLibre asks for. Going via MBTiles and
mb-util instead would hand back TMS and flip the map vertically.
"""

import gzip
import os
import sys

from pmtiles.reader import MmapSource, Reader, all_tiles
from pmtiles.tile import Compression


def decompress(data: bytes, compression: Compression) -> bytes:
    if compression in (Compression.NONE, Compression.UNKNOWN):
        return data
    if compression == Compression.GZIP:
        return gzip.decompress(data)
    raise SystemExit(f"unsupported tile compression: {compression}")


def main(archive: str, outdir: str) -> None:
    with open(archive, "rb") as f:
        compression = Reader(MmapSource(f)).header()["tile_compression"]

        count = 0
        total = 0
        for (z, x, y), data in all_tiles(MmapSource(f)):
            raw = decompress(data, compression)
            # A gzip member here would mean double compression, which renders as
            # an empty map rather than an error on device.
            if raw[:2] == b"\x1f\x8b":
                raise SystemExit(
                    f"tile {z}/{x}/{y} is still gzipped after decompression"
                )
            path = os.path.join(outdir, str(z), str(x))
            os.makedirs(path, exist_ok=True)
            with open(os.path.join(path, f"{y}.pbf"), "wb") as out:
                out.write(raw)
            count += 1
            total += len(raw)

    if count == 0:
        raise SystemExit("no tiles written — the archive is empty")
    print(f"  {count} tiles, {total / 1_000_000:.1f} MB uncompressed")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: explode.py <archive.pmtiles> <outdir>")
    main(sys.argv[1], sys.argv[2])
