import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

TOOL = Path(__file__).resolve().parents[1] / "narration_benchmark.py"
spec = importlib.util.spec_from_file_location("narration_benchmark", TOOL)
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class NarrationBenchmarkTests(unittest.TestCase):
    def test_epub_spine_navigation_and_prose_are_complete(self):
        fixture = json.loads(benchmark.FIXTURE.read_text())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "context.epub"
            benchmark.make_epub(path, fixture)
            with zipfile.ZipFile(path) as archive:
                self.assertEqual(archive.infolist()[0].filename, "mimetype")
                self.assertEqual(archive.infolist()[0].compress_type, zipfile.ZIP_STORED)
                opf = ET.fromstring(archive.read("book.opf"))
                ns = {"o": "http://www.idpf.org/2007/opf"}
                items = {item.attrib["id"]: item.attrib["href"] for item in opf.findall("o:manifest/o:item", ns)}
                spine = opf.findall("o:spine/o:itemref", ns)
                self.assertEqual(len(spine), len(fixture["chapters"]))
                for item, chapter in zip(spine, fixture["chapters"]):
                    document = ET.fromstring(archive.read(items[item.attrib["idref"]]))
                    paragraphs = document.findall(".//{http://www.w3.org/1999/xhtml}p")
                    self.assertEqual([p.text for p in paragraphs], [row["text"] for row in chapter["paragraphs"]])
                nav = ET.fromstring(archive.read("nav.xhtml"))
                links = nav.findall(".//{http://www.w3.org/1999/xhtml}a")
                self.assertEqual([link.attrib["href"] for link in links], [items[item.attrib["idref"]] for item in spine])

    def test_xml_sensitive_prose_survives_round_trip(self):
        fixture = {"chapters": [{"title": "A & B", "paragraphs": [{"text": 'A < B & C > D; "quoted".'}]}]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "context.epub"
            benchmark.make_epub(path, fixture)
            with zipfile.ZipFile(path) as archive:
                document = ET.fromstring(archive.read("chapter-0.xhtml"))
                self.assertEqual(document.find(".//{http://www.w3.org/1999/xhtml}p").text, fixture["chapters"][0]["paragraphs"][0]["text"])

    def test_invalid_parallelism_is_rejected(self):
        for value in ["0", "-1", "2,0", "four", ""]:
            with self.assertRaises(benchmark.argparse.ArgumentTypeError):
                benchmark.positive_list(value)
        self.assertEqual(benchmark.positive_list("1,2,4"), [1, 2, 4])


if __name__ == "__main__":
    unittest.main()
