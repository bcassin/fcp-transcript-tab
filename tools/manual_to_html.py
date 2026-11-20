#!/usr/bin/env python3
"""Convert MANUAL.md (the small Markdown subset it uses) to one self-contained, styled HTML page.

Supported: # / ## / ### headings, paragraphs, bullet and numbered lists (one nesting level via indentation),
tables, **bold**, *italic*, `inline code`, horizontal rules. Standard library only.

Figure directive (screenshot with numbered badges; PNG is embedded as base64):
    @figure path/to/image.png WIDTH HEIGHT
    @badge N X Y            (X Y = badge centre in image pixels)
    @endfigure

usage: manual_to_html.py MANUAL.md [out.html]      (no out: writes to stdout)
"""
import base64
import html
import os
import re
import sys

CSS = """
:root { color-scheme: light dark; --bg:#fff; --fg:#1d1d1f; --muted:#6e6e73; --rule:#d2d2d7; --code-bg:#f2f2f5; --accent:#0a66d6; --th:#f5f5f7; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#1c1c1e; --fg:#f2f2f7; --muted:#a1a1a6; --rule:#3a3a3c; --code-bg:#2c2c2e; --accent:#64a8ff; --th:#2a2a2c; }
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; }
h2 { scroll-margin-top: 1rem; }
body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; }
.fig { position:relative; max-width:600px; margin:1.2rem auto; border:1px solid var(--rule); border-radius:8px; overflow:hidden; line-height:0; }
.fig img { width:100%; height:auto; display:block; }
.fig .b { position:absolute; width:18px; height:18px; margin:-9px 0 0 -9px; border-radius:50%; background:#5e5ce6; color:#fff; font:700 11px/18px -apple-system, Helvetica, Arial, sans-serif; text-align:center; }
main { max-width: 46rem; margin: 0 auto; padding: 2.5rem 1.25rem 4rem; }
h1 { font-size: 2rem; line-height: 1.2; margin: 0 0 1rem; }
h2 { font-size: 1.4rem; margin: 2.4rem 0 .6rem; padding-top: .4rem; }
h3 { font-size: 1.1rem; margin: 1.6rem 0 .4rem; }
p { margin: .7rem 0; }
ul, ol { margin: .6rem 0; padding-left: 1.5rem; }
li { margin: .25rem 0; }
li > ul, li > ol { margin: .2rem 0; }
hr { border: 0; border-top: 1px solid var(--rule); margin: 2rem 0; }
code { font: .9em ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code-bg); padding: .1em .35em; border-radius: 4px; word-break: break-word; }
table { border-collapse: collapse; width: 100%; margin: 1rem 0; font-size: .95rem; }
th, td { border: 1px solid var(--rule); padding: .4rem .6rem; text-align: left; vertical-align: top; }
th { background: var(--th); }
strong { font-weight: 650; }
a { color: var(--accent); }
@media (max-width: 600px) { main { padding: 1.5rem 1rem 3rem; } table { font-size: .85rem; } }
"""

def inline(text):
    """Escape, then apply code / bold / italic. Code spans are protected from the other rules."""
    codes = []
    def stash(m):
        codes.append(m.group(1))
        return "\x00%d\x00" % (len(codes) - 1)
    text = re.sub(r"`([^`]+)`", stash, text)
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\s][^*]*?)\*(?![\w*])", r"<em>\1</em>", text)
    def seclink(m):
        parts = re.split(r"(, | and | to )", m.group(2))
        out = []
        for k, part in enumerate(parts):
            if k % 2: out.append(part); continue
            label = (m.group(1) + part) if k == 0 else part
            out.append('<a href="#s%s">%s</a>' % (part, label))
        return "".join(out)
    text = re.sub(r"\b([Ss]ections? )(\d+[a-z]?(?:(?:, | and | to )\d+[a-z]?)*)", seclink, text)
    text = re.sub(r"\x00(\d+)\x00", lambda m: "<code>%s</code>" % html.escape(codes[int(m.group(1))], quote=False), text)
    return text

def split_row(line):
    line = line.strip()
    if line.startswith("|"): line = line[1:]
    if line.endswith("|"): line = line[:-1]
    return [c.strip() for c in line.split("|")]

LIST_RE = re.compile(r"^(\s*)([-*]|\d+\.)\s+(.*)$")

def render_list(lines, i):
    """Render a (possibly nested) list starting at lines[i]; returns (html, next_index). Continuation lines are indented text."""
    m = LIST_RE.match(lines[i])
    base = len(m.group(1))
    ordered = m.group(2)[0].isdigit()
    tag = "ol" if ordered else "ul"
    out = ["<%s>" % tag]
    while i < len(lines):
        m = LIST_RE.match(lines[i])
        if not m or len(m.group(1)) < base: break
        if len(m.group(1)) > base:          # deeper item without a parent item: treat as nested under the previous one
            sub, i = render_list(lines, i)
            out[-1] = out[-1][:-5] + sub + "</li>"
            continue
        if m.group(2)[0].isdigit() != ordered: break
        item = [m.group(3)]
        i += 1
        while i < len(lines) and lines[i].strip() and not LIST_RE.match(lines[i]) and re.match(r"^\s+\S", lines[i]):
            item.append(lines[i].strip()); i += 1
        out.append("<li>%s</li>" % inline(" ".join(item)))
        if i < len(lines) and LIST_RE.match(lines[i]) and len(LIST_RE.match(lines[i]).group(1)) > base:
            sub, i = render_list(lines, i)
            out[-1] = out[-1][:-5] + sub + "</li>"
    out.append("</%s>" % tag)
    return "".join(out), i

BASEDIR = "."

def convert(md):
    lines = md.replace("\r\n", "\n").split("\n")
    out, i, title = [], 0, "Manual"
    while i < len(lines):
        line = lines[i]
        if not line.strip():
            i += 1; continue
        fm = re.match(r"^@figure\s+(\S+)\s+(\d+)\s+(\d+)\s*$", line)
        if fm:
            path, w, h = fm.group(1), int(fm.group(2)), int(fm.group(3))
            if not os.path.isabs(path): path = os.path.join(BASEDIR, path)
            with open(path, "rb") as f: data = base64.b64encode(f.read()).decode()
            fig = ['<div class="fig"><img alt="The Transcript tab with numbered controls" src="data:image/png;base64,%s">' % data]
            i += 1
            while i < len(lines) and not lines[i].startswith("@endfigure"):
                bm = re.match(r"^@badge\s+(\d+)\s+(\d+)\s+(\d+)\s*$", lines[i])
                if bm: fig.append('<span class="b" style="left:%.2f%%;top:%.2f%%">%s</span>' % (int(bm.group(2)) * 100.0 / w, int(bm.group(3)) * 100.0 / h, bm.group(1)))
                i += 1
            out.append("".join(fig) + "</div>"); i += 1; continue
        m = re.match(r"^(#{1,3})\s+(.*?)\s*#*$", line)
        if m:
            n = len(m.group(1))
            if n == 1 and title == "Manual": title = re.sub(r"[`*]", "", m.group(2))
            idm = re.match(r"^(\d+[a-z]?)\.\s", m.group(2))
            hid = ' id="s%s"' % idm.group(1) if idm else ""
            out.append("<h%d%s>%s</h%d>" % (n, hid, inline(m.group(2)), n)); i += 1; continue
        if re.match(r"^\s*([-*_])\1\1+\s*$", line):
            out.append("<hr>"); i += 1; continue
        if line.lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|?\s*:?-{2,}", lines[i + 1]):
            head = split_row(line); i += 2
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                rows.append(split_row(lines[i])); i += 1
            t = ["<table><thead><tr>%s</tr></thead><tbody>" % "".join("<th>%s</th>" % inline(c) for c in head)]
            for r in rows:
                r = (r + [""] * len(head))[:len(head)]
                t.append("<tr>%s</tr>" % "".join("<td>%s</td>" % inline(c) for c in r))
            t.append("</tbody></table>")
            out.append("".join(t)); continue
        if LIST_RE.match(line):
            h, i = render_list(lines, i); out.append(h); continue
        para = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(r"^(#{1,3}\s|\s*([-*_])\2\2+\s*$|\s*\|)", lines[i]) and not LIST_RE.match(lines[i]):
            para.append(lines[i].strip()); i += 1
        out.append("<p>%s</p>" % inline(" ".join(para)))
    body = "\n".join(out)
    return ("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
            "<title>%s</title><style>%s</style></head>\n<body><main>\n%s\n</main></body></html>\n" % (html.escape(title), CSS, body))

def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__); return 2
    global BASEDIR
    BASEDIR = os.path.dirname(os.path.abspath(argv[1]))
    with open(argv[1], encoding="utf-8") as f:
        page = convert(f.read())
    if len(argv) > 2:
        with open(argv[2], "w", encoding="utf-8") as f: f.write(page)
    else:
        sys.stdout.write(page)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
