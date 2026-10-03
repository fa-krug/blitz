import subprocess, sys, os, tempfile, xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SKELETON = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<rss version="2.0" xmlns:sparkle="%s" xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
    '  <channel><title>Blitz</title></channel>\n</rss>\n' % SPARKLE
)

def run(appcast, **kw):
    args = [sys.executable, os.path.join(os.path.dirname(__file__), "update-appcast.py"),
            "--appcast", appcast]
    for k, v in kw.items():
        args += ["--" + k.replace("_", "-"), v]
    subprocess.run(args, check=True)

def test_prepends_item_with_signed_enclosure():
    with tempfile.TemporaryDirectory() as d:
        appcast = os.path.join(d, "appcast.xml")
        open(appcast, "w").write(SKELETON)
        run(appcast, version="42", short_version="3.1.0 Beta 1", min_system="12.0",
            url="https://github.com/fa-krug/blitz/releases/download/build-42/Blitz-42.zip",
            signature="ABC123==", length="123456", title="Blitz 3.1.0 Beta 1",
            pubdate="Mon, 13 Jul 2026 10:00:00 +0000")
        tree = ET.parse(appcast)
        items = tree.findall(".//channel/item")
        assert len(items) == 1
        enc = items[0].find("enclosure")
        assert enc.get("url").endswith("/Blitz-42.zip")
        assert enc.get("{%s}version" % SPARKLE) == "42"
        assert enc.get("{%s}edSignature" % SPARKLE) == "ABC123=="
        assert enc.get("length") == "123456"
        assert enc.get("{%s}shortVersionString" % SPARKLE) == "3.1.0 Beta 1"
        assert items[0].find("{%s}minimumSystemVersion" % SPARKLE).text == "12.0"

def test_second_item_is_prepended_newest_first():
    with tempfile.TemporaryDirectory() as d:
        appcast = os.path.join(d, "appcast.xml")
        open(appcast, "w").write(SKELETON)
        for n in ("41", "42"):
            run(appcast, version=n, short_version="3.1.0", min_system="12.0",
                url="https://x/Blitz-%s.zip" % n, signature="S%s=" % n,
                length="10", title="v" + n, pubdate="Mon, 13 Jul 2026 10:00:00 +0000")
        versions = [e.get("{%s}version" % SPARKLE)
                    for e in ET.parse(appcast).findall(".//channel/item/enclosure")]
        assert versions == ["42", "41"], versions

def test_same_version_replaces_not_duplicates():
    with tempfile.TemporaryDirectory() as d:
        appcast = os.path.join(d, "appcast.xml")
        open(appcast, "w").write(SKELETON)
        run(appcast, version="42", short_version="3.1.0", min_system="12.0",
            url="https://x/Blitz-42.zip", signature="S1=", length="10",
            title="v42", pubdate="Mon, 13 Jul 2026 10:00:00 +0000")
        run(appcast, version="42", short_version="3.1.0", min_system="12.0",
            url="https://x/Blitz-42.zip", signature="S2=", length="10",
            title="v42", pubdate="Mon, 13 Jul 2026 11:00:00 +0000")
        encs = ET.parse(appcast).findall(".//channel/item/enclosure")
        assert len(encs) == 1, len(encs)
        assert encs[0].get("{%s}edSignature" % SPARKLE) == "S2="

if __name__ == "__main__":
    test_prepends_item_with_signed_enclosure()
    test_second_item_is_prepended_newest_first()
    test_same_version_replaces_not_duplicates()
    print("OK")
