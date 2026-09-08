import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

TOOL = Path(__file__).resolve().parents[1] / 'epub_pronunciation_fixture.py'
spec = importlib.util.spec_from_file_location('epub_fixture', TOOL)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class EPUBPronunciationFixtureTests(unittest.TestCase):
    def test_reproducible_archives_have_identical_display_and_distinct_instructions(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b, repeated = [Path(tmp) / name for name in ('a.epub', 'b.epub', 'repeated.epub')]
            module.build(a)
            module.build(b, annotated=False)
            module.build(repeated)
            self.assertEqual(a.read_bytes(), repeated.read_bytes())
            displays = []
            for path in (a, b):
                with zipfile.ZipFile(path) as archive:
                    first = archive.infolist()[0]
                    self.assertEqual(first.filename, 'mimetype')
                    self.assertEqual(first.compress_type, zipfile.ZIP_STORED)
                    self.assertEqual(archive.read(first), b'application/epub+zip')
                    tree = ET.fromstring(archive.read('EPUB/chapter.xhtml'))
                    body = tree.find('{http://www.w3.org/1999/xhtml}body')
                    displays.append(' '.join(''.join(body.itertext()).split()))
                    for name in archive.namelist():
                        if name.endswith(('.xml', '.opf', '.xhtml', '.pls')):
                            ET.fromstring(archive.read(name))
                    count = sum('{http://www.w3.org/2001/10/synthesis}ph' in element.attrib for element in tree.iter())
                    self.assertEqual(count, 3 if path == a else 0)
            self.assertEqual(displays[0], displays[1])

    def test_committed_archives_match_generator(self):
        with tempfile.TemporaryDirectory() as tmp:
            for annotated, name in ((True, 'pronunciation-annotated.epub'), (False, 'pronunciation-baseline.epub')):
                target = Path(tmp) / name
                module.build(target, annotated)
                self.assertEqual(target.read_bytes(), (TOOL.parent / 'fixtures' / name).read_bytes())


if __name__ == '__main__':
    unittest.main()
