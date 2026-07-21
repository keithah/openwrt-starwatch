#!/usr/bin/env python3
"""Compare logical IPK contents while ignoring archive timestamps."""

from __future__ import annotations

import gzip
import io
import sys
import tarfile
import zlib
from pathlib import Path


def archive_members(blob: bytes, label: str) -> list[tuple[object, ...]]:
    try:
        uncompressed = gzip.decompress(blob)
        with tarfile.open(fileobj=io.BytesIO(uncompressed), mode="r:") as archive:
            members = archive.getmembers()
            if len({member.name for member in members}) != len(members):
                raise ValueError(f"{label}: duplicate archive member")
            result: list[tuple[object, ...]] = []
            for member in members:
                payload = b""
                if member.isfile():
                    extracted = archive.extractfile(member)
                    if extracted is None:
                        raise ValueError(f"{label}: cannot read {member.name}")
                    payload = extracted.read()
                if member.name in {"./control.tar.gz", "./data.tar.gz"}:
                    payload = repr(archive_members(payload, f"{label}:{member.name}")).encode()
                result.append(
                    (
                        member.name,
                        member.type,
                        member.mode,
                        member.uid,
                        member.gid,
                        member.uname,
                        member.gname,
                        member.linkname,
                        member.devmajor,
                        member.devminor,
                        payload,
                    )
                )
            return result
    except (gzip.BadGzipFile, tarfile.TarError, EOFError, zlib.error) as exc:
        raise ValueError(f"{label}: invalid gzip-ustar archive: {exc}") from exc


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {Path(sys.argv[0]).name} FIRST.ipk SECOND.ipk", file=sys.stderr)
        return 2
    first = Path(sys.argv[1])
    second = Path(sys.argv[2])
    try:
        first_members = archive_members(first.read_bytes(), str(first))
        second_members = archive_members(second.read_bytes(), str(second))
    except (OSError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 1
    if first_members != second_members:
        print(f"logical IPK contents differ: {first} != {second}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
