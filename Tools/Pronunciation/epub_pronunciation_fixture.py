#!/usr/bin/env python3
"""Package the public annotated fixture and an otherwise identical baseline."""
import argparse
from pathlib import Path
import re
import zipfile

SOURCE = Path(__file__).parent / "fixtures" / "epub-pronunciation"


def build(output: Path, annotated: bool = True) -> None:
    with zipfile.ZipFile(output, "w") as archive:
        info = zipfile.ZipInfo("mimetype", (2026, 9, 8, 0, 0, 0))
        archive.writestr(info, b"application/epub+zip", compress_type=zipfile.ZIP_STORED)
        for path in sorted(SOURCE.rglob("*")):
            if not path.is_file() or path.name == "mimetype":
                continue
            data = path.read_bytes()
            if not annotated and path.name == "chapter.xhtml":
                text = data.decode()
                text = re.sub(r' ssml:ph="[^"]*"', '', text)
                text = re.sub(r'<link rel="pronunciation"[^>]*/>', '', text)
                data = text.encode()
            info = zipfile.ZipInfo(path.relative_to(SOURCE).as_posix(), (2026, 9, 8, 0, 0, 0))
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    build(args.output / "pronunciation-annotated.epub")
    build(args.output / "pronunciation-baseline.epub", annotated=False)
