#!/usr/bin/env python3
"""抓取第三方库文档站到 docs/<lib>/{raw,pages}，用于离线查阅。

用法: python3 Tools/crawl-docs.py <lib> <base-url>
例:   python3 Tools/crawl-docs.py iglistkit https://instagram.github.io/IGListKit/
"""
import os
import re
import sys
import time
import html as htmllib
import urllib.parse
import urllib.request
from collections import deque

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) docs-crawler"


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


# ---------------------------------------------------------------- html -> md

PRE_RE = re.compile(r"<pre\b[^>]*>(.*?)</pre>", re.S | re.I)


def strip_tags(s):
    return htmllib.unescape(re.sub(r"<[^>]+>", "", s))


def pre_to_md(block, lang):
    text = strip_tags(block)
    text = text.strip("\n")
    # 去掉整块缩进（jazzy 的 declaration 块常有公共缩进）
    lines = text.split("\n")
    indents = [len(l) - len(l.lstrip()) for l in lines if l.strip()]
    pad = min(indents) if indents else 0
    text = "\n".join(l[pad:] if len(l) >= pad else l for l in lines)
    fence = "```" + (lang or "")
    return f"\n\n{fence}\n{text.strip()}\n```\n\n"


def inline_md(s):
    s = re.sub(r"<code\b[^>]*>(.*?)</code>", lambda m: "`" + strip_tags(m.group(1)).strip() + "`", s, flags=re.S | re.I)
    s = re.sub(r"<a\b[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
               lambda m: f"[{strip_tags(m.group(2)).strip()}]({m.group(1)})", s, flags=re.S | re.I)
    s = re.sub(r"<(?:b|strong)\b[^>]*>(.*?)</(?:b|strong)>", r"**\1**", s, flags=re.S | re.I)
    s = re.sub(r"<(?:i|em)\b[^>]*>(.*?)</(?:i|em)>", r"*\1*", s, flags=re.S | re.I)
    s = re.sub(r"<[^>]+>", "", s)
    s = htmllib.unescape(s)
    return re.sub(r"[ \t]+", " ", s).strip()


def html_to_md(html):
    # 只保留正文容器
    m = re.search(r"<article[^>]*class=\"[^\"]*main-content[^\"]*\"[^>]*>(.*?)</article>", html, re.S | re.I)
    if not m:
        m = re.search(r"<main\b[^>]*>(.*?)</main>", html, re.S | re.I)
    if not m:
        m = re.search(r"<body\b[^>]*>(.*?)</body>", html, re.S | re.I)
    body = m.group(1) if m else html
    body = re.sub(r"<(script|style|nav|footer)\b.*?</\1>", "", body, flags=re.S | re.I)

    # <pre> 先抽出来做成占位符，避免被当作普通标签处理
    blocks = []

    def stash(mm):
        # 往上看一点，拿 aside-title 作为代码块语言
        lang = ""
        before = body[max(0, mm.start() - 400):mm.start()]
        t = re.findall(r"aside-title[^>]*>\s*([A-Za-z+#0-9 ]{1,20})\s*<", before)
        if t:
            lang = t[-1].strip().lower().replace(" ", "")
            lang = {"objective-c": "objc", "obj-c": "objc"}.get(lang, lang)
            if lang not in ("objc", "swift", "json", "bash", "ruby", "kotlin", "java", "xml", "http"):
                lang = ""
        blocks.append(pre_to_md(mm.group(1), lang))
        return f"\n\x00B{len(blocks)-1}\x00\n"

    out = PRE_RE.sub(stash, body)

    out = re.sub(r"<h([1-6])\b[^>]*>(.*?)</h\1>",
                 lambda m: "\n\n" + "#" * int(m.group(1)) + " " + inline_md(m.group(2)) + "\n\n",
                 out, flags=re.S | re.I)
    out = re.sub(r"<li\b[^>]*>(.*?)</li>", lambda m: "\n- " + inline_md(m.group(1)), out, flags=re.S | re.I)
    out = re.sub(r"<(ul|ol)\b[^>]*>", "\n", out, flags=re.I)
    out = re.sub(r"</(ul|ol)>", "\n", out, flags=re.I)
    out = re.sub(r"<tr\b[^>]*>", "\n| ", out, flags=re.I)
    out = re.sub(r"</t[dh]>", " | ", out, flags=re.I)
    out = re.sub(r"<br\s*/?>", "\n", out, flags=re.I)
    out = re.sub(r"</p>", "\n\n", out, flags=re.I)
    out = re.sub(r"<(p|div|section|table|blockquote)\b[^>]*>", "\n", out, flags=re.I)
    out = re.sub(r"</(div|section|table|blockquote)>", "\n", out, flags=re.I)
    out = re.sub(r"<hr\s*/?>", "\n\n---\n\n", out, flags=re.I)
    out = inline_md(out)
    for i, b in enumerate(blocks):
        out = out.replace(f"\x00B{i}\x00", b)
    out = re.sub(r"\n{3,}", "\n\n", out)
    out = re.sub(r"[ \t]+\n", "\n", out)
    return out.strip() + "\n"


# ---------------------------------------------------------------- crawl

def slug(url, base):
    path = urllib.parse.urlparse(url).path
    prefix = urllib.parse.urlparse(base).path.rstrip("/")
    if path.startswith(prefix):
        path = path[len(prefix):]
    path = path.lstrip("/")
    if not path or path.endswith("/"):
        path += "index.html"
    return path


def crawl(lib, base, limit=400):
    host = urllib.parse.urlparse(base).netloc
    prefix = urllib.parse.urlparse(base).path
    raw_dir = os.path.join(ROOT, "docs", lib, "raw")
    page_dir = os.path.join(ROOT, "docs", lib, "pages")
    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(page_dir, exist_ok=True)

    seen, queue, saved, failed = set(), deque([base]), [], []
    while queue and len(seen) < limit:
        url = queue.popleft()
        url = url.split("#")[0]
        if url in seen:
            continue
        seen.add(url)
        try:
            html = fetch(url)
        except Exception as e:
            failed.append(f"{url} :: {e}")
            continue
        rel = slug(url, base)
        raw_path = os.path.join(raw_dir, rel)
        os.makedirs(os.path.dirname(raw_path), exist_ok=True)
        with open(raw_path, "w", encoding="utf-8") as f:
            f.write(html)
        md = html_to_md(html)
        md_rel = re.sub(r"\.html?$", ".md", rel)
        md_path = os.path.join(page_dir, md_rel)
        os.makedirs(os.path.dirname(md_path), exist_ok=True)
        with open(md_path, "w", encoding="utf-8") as f:
            f.write(f"<!-- source: {url} -->\n\n" + md)
        saved.append((rel, len(md)))

        for href in re.findall(r'href="([^"]+)"', html):
            if href.startswith(("mailto:", "javascript:")):
                continue
            nxt = urllib.parse.urljoin(url, href)
            p = urllib.parse.urlparse(nxt)
            if p.netloc != host or not p.path.startswith(prefix):
                continue
            if p.path.split(".")[-1].lower() not in ("html", "htm", ""):
                continue
            nxt = nxt.split("#")[0]
            if nxt not in seen:
                queue.append(nxt)
        time.sleep(0.05)

    print(f"[{lib}] pages={len(saved)} failed={len(failed)} -> docs/{lib}/pages")
    for rel, n in sorted(saved):
        print(f"  {n:>7}  {rel}")
    for fl in failed:
        print(f"  FAIL {fl}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    crawl(sys.argv[1], sys.argv[2])
