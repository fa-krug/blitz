#!/usr/bin/env python3
"""Prepend a signed <item> to a Sparkle appcast (newest-first), in place."""
import argparse
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def sk(tag):
    return "{%s}%s" % (SPARKLE, tag)


def main():
    p = argparse.ArgumentParser()
    for name in ("appcast", "version", "short-version", "min-system",
                 "url", "signature", "length", "title", "pubdate"):
        p.add_argument("--" + name, required=True)
    a = p.parse_args()

    tree = ET.parse(a.appcast)
    channel = tree.find("channel")
    if channel is None:
        raise SystemExit("appcast has no <channel>")

    item = ET.Element("item")
    ET.SubElement(item, "title").text = a.title
    ET.SubElement(item, "pubDate").text = a.pubdate
    ET.SubElement(item, sk("minimumSystemVersion")).text = a.min_system
    enc = ET.SubElement(item, "enclosure")
    enc.set("url", a.url)
    enc.set("type", "application/octet-stream")
    enc.set(sk("version"), a.version)
    enc.set(sk("shortVersionString"), a.short_version)
    enc.set(sk("edSignature"), a.signature)
    enc.set("length", a.length)

    # Idempotency: drop any existing item announcing this same version so a
    # re-run replaces rather than duplicates it.
    for old in channel.findall("item"):
        enc_old = old.find("enclosure")
        if enc_old is not None and enc_old.get(sk("version")) == a.version:
            channel.remove(old)

    # Insert as the first <item>, after any non-item channel metadata.
    existing = channel.findall("item")
    insert_at = list(channel).index(existing[0]) if existing else len(list(channel))
    channel.insert(insert_at, item)

    tree.write(a.appcast, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    main()
