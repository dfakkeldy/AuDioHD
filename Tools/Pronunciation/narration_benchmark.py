#!/usr/bin/env python3
"""Build a public synthetic listening EPUB; optionally benchmark an existing CLI.

Does not build Apple targets, download models itself, or judge pronunciation.
Each trial has fresh audio/capture paths; the installed model cache stays warm.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import itertools
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import time
import zipfile

FIXTURE = Path(__file__).with_name("fixtures") / "narration_context.json"


def make_epub(destination: Path, fixture: dict) -> None:
    chapters = fixture["chapters"]
    manifest, spine, nav = [], [], []
    with zipfile.ZipFile(destination, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        for index, chapter in enumerate(chapters):
            name = f"chapter-{index}.xhtml"
            title = html.escape(chapter["title"])
            paragraphs = "".join(f'<p>{html.escape(row["text"])}</p>' for row in chapter["paragraphs"])
            archive.writestr(name, f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head><body><h1>{title}</h1>{paragraphs}</body></html>')
            manifest.append(f'<item id="c{index}" href="{name}" media-type="application/xhtml+xml"/>')
            spine.append(f'<itemref idref="c{index}"/>')
            nav.append(f'<li><a href="{name}">{title}</a></li>')
        archive.writestr("nav.xhtml", '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol>' + "".join(nav) + '</ol></nav></body></html>')
        archive.writestr("book.opf", '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">echo-synthetic-narration-context-v1</dc:identifier><dc:title>Narration Context Regression</dc:title><dc:creator>Echo Test Fixture</dc:creator><dc:language>en</dc:language><meta property="dcterms:modified">2026-09-07T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>' + "".join(manifest) + '</manifest><spine>' + "".join(spine) + '</spine></package>')


def positive_list(value: str) -> list[int]:
    try:
        values = [int(part) for part in value.split(",")]
        if not values or any(item < 1 for item in values):
            raise ValueError
        return values
    except ValueError as error:
        raise argparse.ArgumentTypeError("expected comma-separated positive integers") from error


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New output directory (never overwrite a run).")
    parser.add_argument("--cli", type=Path, help="Existing Release echo-cli. Omit to generate fixtures only.")
    parser.add_argument("--jobs", type=positive_list, default=[1])
    parser.add_argument("--threads", type=positive_list, default=[1, 2, 4])
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--no-word-timings", action="store_true")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    if args.cli and (platform.system() != "Darwin" or not shutil.which("ffprobe")):
        parser.error("benchmarks need macOS and ffprobe; fixture generation is portable")
    args.output.mkdir(parents=True, exist_ok=False)
    fixture = json.loads(FIXTURE.read_text())
    epub = (args.output / "context.epub").resolve()
    make_epub(epub, fixture)
    (args.output / "listening-checklist.json").write_text(json.dumps(fixture, indent=2) + "\n")
    if not args.cli:
        print(epub)
        return
    report = {"platform": platform.platform(), "cli_sha256": hashlib.sha256(args.cli.read_bytes()).hexdigest(),
              "fixture_sha256": hashlib.sha256(FIXTURE.read_bytes()).hexdigest(),
              "note": "First trial may include model preparation. RTF includes import/export; not a pure inference benchmark. No automatic listening score.", "trials": []}
    report_path = args.output / "benchmark.json"
    for jobs, threads, run in itertools.product(args.jobs, args.threads, range(args.runs)):
        trial = (args.output / f"jobs-{jobs}-threads-{threads}-run-{run}").resolve()
        trial.mkdir()
        command = [str(args.cli.resolve()), "narrate", "--epub", str(epub), "--out", str(trial / "audio.m4b"),
                   "--title", "Narration Context Regression", "--author", "Echo Test Fixture",
                   "--work-dir", str(trial / "work"), "--jobs", str(jobs), "--threads", str(threads), "--no-pronunciation-review"]
        if args.no_word_timings:
            command.append("--no-word-timings")
        started = time.monotonic()
        with (trial / "stdout.log").open("w") as stdout, (trial / "stderr.log").open("w") as stderr:
            completed = subprocess.run(["/usr/bin/time", "-l", *command], stdout=stdout, stderr=stderr)
        elapsed = time.monotonic() - started
        stderr_text = (trial / "stderr.log").read_text()
        memory = re.search(r"(\d+)\s+maximum resident set size", stderr_text)
        row = {"jobs": jobs, "threads": threads, "run": run, "exit_code": completed.returncode,
               "wall_seconds": elapsed, "word_timings": not args.no_word_timings,
               "peak_rss_bytes": int(memory.group(1)) if memory else None}
        if completed.returncode == 0:
            duration = float(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", str(trial / "audio.m4b")], text=True))
            row.update(audio_seconds=duration, rtf=elapsed / duration)
        report["trials"].append(row)
        report_path.write_text(json.dumps(report, indent=2) + "\n")
        if completed.returncode:
            raise SystemExit(f"Trial failed; see {trial}")
    print(report_path)


if __name__ == "__main__":
    main()
