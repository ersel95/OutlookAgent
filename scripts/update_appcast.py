#!/usr/bin/env python3
"""Insert or update one release <item> in appcast.xml (Sparkle's update feed).

CI release job DMG'yi Sparkle'ın `sign_update` (EdDSA) ile imzalar, sonra bunu
çağırıp `SUFeedURL`'nin gösterdiği feed'e yeni sürümü ekler. Aynı sürüm için
yeniden çalışırsa eski item'ı düşürür → idempotent.

Release notes:
    --notes-md PATH ile Markdown dosyası verilirse içerik HTML'e çevrilip
    <description><![CDATA[...]]></description> olarak item'a eklenir; Sparkle
    "Check for Updates" preview'da bunu kullanır. <sparkle:releaseNotesLink>
    fallback olarak yine eklenir (preview destekleyemeyen istemciler için).

Re-emit modu (notes-only refresh):
    --url / --length / --signature verilmezse mevcut item'dan kopyalanır.
    Sadece notları güncellemek için: --version + --notes-md yeterli.

Usage:
  update_appcast.py --version 1.0.3 \\
    --url https://github.com/ersel95/OutlookAgent/releases/download/v1.0.3/OutlookAgent-1.0.3.dmg \\
    --length 4192836 --signature 'BASE64==' [--notes-md RELEASES/v1.0.3.md] \\
    [--notes-url URL] [--min-system 14.0] [--appcast appcast.xml]
"""
import argparse
import html
import re
from datetime import datetime, timezone
from email.utils import format_datetime
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def sk(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


# MARK: - Markdown → HTML (minimal)
#
# Standart kütüphaneye bağlı kalmak için kendi convertor'ımı yazıyorum.
# Release notlarında ihtiyaç duyduğumuz feature'ler: H1/H2/H3, ul, ol, bold,
# italic, inline code, fenced code block, link. Karmaşık table / nested list
# desteklemiyor — daha kompleks içerik için RELEASES/v*.md basit tut.

# NOT: replacement'lar input'un ZATEN html.escape edilmiş olduğunu varsayar.
# `_inline()` önce tüm metni escape edip sonra pattern'leri uyguladığı için
# burada tekrar escape edilmez — aksi hâlde `<code>&lt;x&gt;</code>` istediğimiz
# yerde `<code>&amp;lt;x&amp;gt;</code>` (double-escaped) elde ederiz.
_INLINE_PATTERNS = [
    # Inline code first so it doesn't get mangled by bold/italic.
    (re.compile(r"`([^`]+)`"), lambda m: f"<code>{m.group(1)}</code>"),
    # Links [text](url) — URL grubu da ilk escape geçişinde temizlenmiştir.
    (re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)"),
        lambda m: f'<a href="{m.group(2)}">{m.group(1)}</a>'),
    # Bold **x** veya __x__
    (re.compile(r"\*\*(.+?)\*\*"), lambda m: f"<strong>{m.group(1)}</strong>"),
    (re.compile(r"__(.+?)__"), lambda m: f"<strong>{m.group(1)}</strong>"),
    # Italic *x* veya _x_  (greedy ama kelime sınırında)
    (re.compile(r"(?<![*\w])\*([^*\n]+?)\*(?![*\w])"),
        lambda m: f"<em>{m.group(1)}</em>"),
    (re.compile(r"(?<![_\w])_([^_\n]+?)_(?![_\w])"),
        lambda m: f"<em>{m.group(1)}</em>"),
]


def _inline(text: str) -> str:
    escaped = html.escape(text)
    out = escaped
    for pat, repl in _INLINE_PATTERNS:
        out = pat.sub(repl, out)
    return out


def md_to_html(md: str) -> str:
    lines = md.replace("\r\n", "\n").split("\n")
    out = []
    i = 0
    in_para = []
    in_list = None  # "ul" | "ol" | None
    in_code = False
    code_lang = ""
    code_buf = []

    def flush_para():
        nonlocal in_para
        if in_para:
            joined = " ".join(in_para).strip()
            if joined:
                out.append(f"<p>{_inline(joined)}</p>")
            in_para = []

    def flush_list():
        nonlocal in_list
        if in_list:
            out.append(f"</{in_list}>")
            in_list = None

    def flush_code():
        nonlocal in_code, code_buf, code_lang
        if in_code:
            joined = "\n".join(code_buf)
            out.append(f"<pre><code>{html.escape(joined)}</code></pre>")
            in_code = False
            code_buf = []
            code_lang = ""

    while i < len(lines):
        raw = lines[i]
        line = raw.rstrip()

        # Fenced code block (```)
        fence = re.match(r"^```\s*(\S*)\s*$", line)
        if fence:
            if in_code:
                flush_code()
            else:
                flush_para()
                flush_list()
                in_code = True
                code_lang = fence.group(1)
            i += 1
            continue
        if in_code:
            code_buf.append(raw)
            i += 1
            continue

        # Headings
        h = re.match(r"^(#{1,6})\s+(.+?)\s*#*\s*$", line)
        if h:
            flush_para(); flush_list()
            level = len(h.group(1))
            text = _inline(h.group(2))
            out.append(f"<h{level}>{text}</h{level}>")
            i += 1
            continue

        # Lists
        ul = re.match(r"^[ \t]*[-*+]\s+(.+)$", line)
        ol = re.match(r"^[ \t]*\d+\.\s+(.+)$", line)
        if ul or ol:
            flush_para()
            kind = "ul" if ul else "ol"
            content = (ul.group(1) if ul else ol.group(1))
            if in_list != kind:
                flush_list()
                in_list = kind
                out.append(f"<{kind}>")
            out.append(f"<li>{_inline(content)}</li>")
            i += 1
            continue

        # Blank line ends paragraph and list
        if not line.strip():
            flush_para()
            flush_list()
            i += 1
            continue

        # Plain paragraph line
        flush_list()
        in_para.append(line.strip())
        i += 1

    flush_para()
    flush_list()
    flush_code()
    return "\n".join(out)


# MARK: - Embedded stylesheet

# Sparkle preview ufak (~400px wide, ~250-300px tall). System font, dark mode
# uyumlu, kompakt aralıklar. Inline ki ekstra HTTP request gerekmesin.
_CSS = """\
:root { color-scheme: light dark; }
body {
  font: 13px -apple-system, system-ui, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
  margin: 0; padding: 10px 14px; line-height: 1.45;
}
h1, h2, h3, h4 { margin: 0.7em 0 0.3em; font-weight: 600; }
h1 { font-size: 1.25em; }
h2 { font-size: 1.10em; }
h3 { font-size: 1.00em; opacity: 0.85; }
p { margin: 0.35em 0; }
ul, ol { padding-left: 1.3em; margin: 0.3em 0; }
li { margin: 0.12em 0; }
code {
  background: rgba(127,127,127,0.18); padding: 0 4px; border-radius: 3px;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.92em;
}
pre {
  background: rgba(127,127,127,0.14); padding: 8px 10px; border-radius: 5px;
  overflow-x: auto; font-size: 0.88em;
}
pre code { background: transparent; padding: 0; }
a { color: #0a66e6; text-decoration: none; }
a:hover { text-decoration: underline; }
hr { border: 0; border-top: 1px solid rgba(127,127,127,0.3); margin: 0.8em 0; }
@media (prefers-color-scheme: dark) {
  a { color: #5eaeff; }
}
"""


def render_notes_html(md_text: str) -> str:
    body = md_to_html(md_text)
    return f"<style>{_CSS}</style>\n{body}"


# MARK: - Appcast manipulation

def load_or_create(path: str):
    try:
        tree = ET.parse(path)
        root = tree.getroot()
        if root.find("channel") is None:
            ET.SubElement(root, "channel")
        return tree, root
    except (FileNotFoundError, ET.ParseError):
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "OutlookAgent"
        ET.SubElement(channel, "link").text = "https://github.com/ersel95/OutlookAgent"
        ET.SubElement(channel, "description").text = "OutlookAgent updates"
        return ET.ElementTree(root), root


def existing_item(channel, version: str):
    for it in channel.findall("item"):
        if it.findtext(sk("version")) == version:
            return it
    return None


def build_item(args, fallback_enclosure: ET.Element | None,
               fallback_pubdate: str | None) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"OutlookAgent {args.version}"
    # Yeniden insert ediyorsak orijinal pubDate'i koru (notes-only refresh).
    pubdate = args.pubdate or fallback_pubdate or format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, "pubDate").text = pubdate

    ET.SubElement(item, sk("version")).text = args.version
    ET.SubElement(item, sk("shortVersionString")).text = args.version
    ET.SubElement(item, sk("minimumSystemVersion")).text = args.min_system

    # Release notes — Markdown dosyası varsa inline HTML embed (Sparkle bunu
    # öncelikli olarak tercih eder, link'e gitmez).
    if args.notes_md:
        with open(args.notes_md, "r", encoding="utf-8") as f:
            md = f.read()
        html_payload = render_notes_html(md)
        desc = ET.SubElement(item, "description")
        # CDATA — ElementTree native CDATA desteklemediği için sonradan write
        # ediyoruz; geçici olarak text'i unique placeholder'a koyup
        # serialize sonrası swap edeceğiz.
        desc.text = f"__CDATA_PLACEHOLDER_{args.version}__"
        # Payload'ı geri yazmak için saklayalım.
        args._cdata_payload = html_payload

    # Fallback: GitHub release tag — eski Sparkle / preview destekleyemeyen
    # istemciler için.
    notes_url = args.notes_url or (
        f"https://github.com/ersel95/OutlookAgent/releases/tag/v{args.version}"
    )
    ET.SubElement(item, sk("releaseNotesLink")).text = notes_url

    # Enclosure — sig/length/url eksikse mevcut item'dan kopyala.
    enclosure = ET.SubElement(item, "enclosure")
    if args.url and args.length and args.signature:
        enclosure.set("url", args.url)
        enclosure.set("length", str(args.length))
        enclosure.set("type", "application/octet-stream")
        enclosure.set(sk("edSignature"), args.signature)
    elif fallback_enclosure is not None:
        for attr in ("url", "length", "type"):
            v = fallback_enclosure.get(attr)
            if v is not None:
                enclosure.set(attr, v)
        sig = fallback_enclosure.get(sk("edSignature"))
        if sig:
            enclosure.set(sk("edSignature"), sig)
    else:
        raise SystemExit(
            f"appcast: {args.version} için enclosure verisi yok ve mevcut item bulunamadı."
        )
    return item


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True)
    p.add_argument("--url", default="")
    p.add_argument("--length", default=0, type=int)
    p.add_argument("--signature", default="")
    p.add_argument("--notes-url", default="")
    p.add_argument("--notes-md", default="",
                   help="Markdown release notes; HTML'e çevrilip <description>'a CDATA gömülür")
    p.add_argument("--pubdate", default="",
                   help="RFC-2822 pubDate override (re-emit için orijinali korumaya yarar)")
    p.add_argument("--min-system", default="14.0")
    p.add_argument("--appcast", default="appcast.xml")
    args = p.parse_args()

    tree, root = load_or_create(args.appcast)
    channel = root.find("channel")

    existing = existing_item(channel, args.version)
    fallback_enclosure = existing.find("enclosure") if existing is not None else None
    fallback_pubdate = existing.findtext("pubDate") if existing is not None else None
    if existing is not None:
        channel.remove(existing)

    item = build_item(args, fallback_enclosure, fallback_pubdate)
    first_item = channel.find("item")
    if first_item is not None:
        channel.insert(list(channel).index(first_item), item)  # newest first
    else:
        channel.append(item)

    ET.indent(tree, space="  ")
    # Serialize'da CDATA placeholder'ı gerçek CDATA blok'una swap et.
    raw_xml = ET.tostring(root, encoding="utf-8", xml_declaration=True).decode("utf-8")
    payload = getattr(args, "_cdata_payload", None)
    if payload is not None:
        placeholder = f"__CDATA_PLACEHOLDER_{args.version}__"
        cdata = f"<![CDATA[{payload}]]>"
        raw_xml = raw_xml.replace(placeholder, cdata)
    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(raw_xml)
    print(f"appcast.xml updated for {args.version}")


if __name__ == "__main__":
    main()
