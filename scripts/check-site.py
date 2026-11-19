#!/usr/bin/env python3
"""Read-only checks over the built documentation site.

`links` walks the built site for an internal link or image that resolves to nothing, and for a link whose fragment
names no heading or anchor on the page it lands on. A root-relative link carries the path that `site_url` in the
repository's zensical.toml publishes the site under. `prose` holds the mechanical content rules of the site's prose,
over each file it is given and each Markdown file at each depth of a folder it is given.
"""
import functools
import html.parser
import pathlib
import re
import sys
import tomllib
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE = ROOT / "build" / "site"

# Another host's links are not this script's business.
SKIPPED = ("http:", "https:", "mailto:", "javascript:", "data:", "tel:")
# The theme's skip link points at a page's first heading, and 404.html, built from no Markdown, has none, so the
# theme writes `#__skip` there with nothing carrying that id.
SKIP_LINK = "#__skip"


def site_prefix(config: pathlib.Path) -> list[str] | None:
    """The path segments `site_url` publishes the site under, an empty list for an address without a path, or None
    after printing why the configuration names no address."""
    with open(config, "rb") as file:
        url = tomllib.load(file).get("project", {}).get("site_url")
    if not url:
        print(f"{config.name}: no site_url under [project]")
        return None
    path = urllib.parse.unquote(urllib.parse.urlsplit(url).path)
    return [segment for segment in path.split("/") if segment]


class Links(html.parser.HTMLParser):
    """The hrefs and srcs a page carries, and the ids the site build gave its headings and anchors."""

    def __init__(self):
        super().__init__()
        self.found = []
        # A `src` fragment is the theme's light and dark switch on an image, not a place on a page, so only an
        # `href` has its fragment checked.
        self.hrefs = []
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("href", "src") and value:
                self.found.append(value)
            if name == "href" and value:
                self.hrefs.append(value)
            if name == "id" and value:
                self.ids.add(value)


@functools.cache
def ids_of(page):
    parser = Links()
    parser.feed(page.read_text(encoding="utf-8"))
    return parser.ids


def target_of(site, prefix, page, raw):
    """The file a link lands on, a directory read as its `index.html` and a link without a path as `page`
    itself, or None when the link resolves to nothing."""
    path = urllib.parse.unquote(urllib.parse.urlsplit(raw).path)
    if not path:
        return page
    site = site.resolve()
    if path.startswith("/"):
        # A root-relative link must carry the prefix site_url publishes this site under. A browser resolves
        # it against the host root, not against site/, so a link missing the prefix is dangling regardless
        # of whether some other path happens to exist under site/.
        parts = path.lstrip("/").split("/")
        if parts[: len(prefix)] != prefix:
            return None
        remainder = "/".join(parts[len(prefix) :])
        candidates = [site / remainder] if remainder else [site]
    else:
        candidates = [page.parent / path]
    for target in candidates:
        target = target.resolve()
        if not target.is_relative_to(site):
            continue
        if target.is_file():
            return target
        if target.is_dir() and (target / "index.html").is_file():
            return target / "index.html"
    return None


def resolves(site, prefix, page, raw):
    return target_of(site, prefix, page, raw) is not None


def fragment_missing_from(site, prefix, page, raw):
    """The page whose ids lack a link's fragment: the page itself for a bare `#x`, the resolved target for
    `page/#x`. None when the fragment is among them or there is none to check."""
    fragment = urllib.parse.unquote(urllib.parse.urlsplit(raw).fragment)
    if not fragment or raw == SKIP_LINK:
        return None
    target = target_of(site, prefix, page, raw)
    # A link that lands nowhere is the path check's finding, and an image or a file other than a page has no ids.
    if target is None or target.suffix != ".html":
        return None
    return None if fragment in ids_of(target) else target


def check_links(site, prefix):
    # Resolved first, so a page and the target a link resolves to share one root for the paths a finding prints.
    site = site.resolve()
    pages = sorted(site.rglob("*.html"))
    if not pages:
        print(f"no pages under {site}. Build the site first.")
        return 1
    dangling = 0
    for page in pages:
        parser = Links()
        parser.feed(page.read_text(encoding="utf-8"))
        for raw in parser.found:
            if raw.startswith(SKIPPED):
                continue
            if not resolves(site, prefix, page, raw):
                print(f"{page.relative_to(site)}: {raw} resolves to nothing")
                dangling += 1
        for raw in parser.hrefs:
            if raw.startswith(SKIPPED):
                continue
            target = fragment_missing_from(site, prefix, page, raw)
            if target is not None:
                print(f"{page.relative_to(site)}: {raw} names no heading or anchor in {target.relative_to(site)}")
                dangling += 1
    return 1 if dangling else 0


FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
CODE_SPAN = re.compile(r"(`+)(.+?)\1")
HTML_COMMENT = re.compile(r"<!--.*?-->")
DASHES = ("—", "–")
# The words of a working document that a reference page does not use. "commit", "lane", "plan" and "review" have a
# product sense (a committed stream, the fast lane, the plan meter, auto mode's review) and stay off the list. "shape"
# with a capital letter is case-sensitive, since "the shape a client sends" is prose.
VOCABULARY = re.compile(
    r"\b(sub-projects?|subprojects?|rulings?|tasks?|findings?|worktrees?|workstreams?|item [0-9]+|option [0-9])\b",
    re.IGNORECASE,
)
SHAPE_LETTER = re.compile(r"\bshape [A-Z]\b")
BARE_API_KEY = re.compile(r"\bapi_key\b")


def prose_files(paths: list[pathlib.Path]) -> list[pathlib.Path]:
    """Each file as it is given and each folder as its `*.md` files at each depth, sorted. With no path: the pages of
    the build tree and the repository's README."""
    files: list[pathlib.Path] = []
    for path in paths or [ROOT / "build" / "docs", ROOT / "README.md"]:
        files += sorted(path.rglob("*.md")) if path.is_dir() else [path]
    return files


def check_prose(files):
    """The mechanical content rules over a page's prose: fenced blocks dropped (a fence closes only on a bare fence
    line of its own character, at least as long), code spans removed with an open span carried across lines until a
    blank line or a fence ends its paragraph, HTML comments removed from each remaining line, the column count read
    on the original line."""
    findings = 0
    for path in files:
        if not path.is_file():
            print(f"{path} is missing")
            findings += 1
            continue
        shown = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
        fence, spanned = None, False
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            marker = FENCE.match(line)
            if fence is None and (marker or not line.strip()):
                # A code span never crosses a paragraph, so a backtick left open ends at a blank line or a fence.
                spanned = False
            if fence is None and marker:
                fence = marker.group(1)
                continue
            if fence is not None:
                # A shorter fence line, or one with an info string (a three-backtick `sh` line inside a three- or
                # four-backtick block), is content, not the close.
                run = marker.group(1) if marker else None
                if run and line.strip() == run and run[0] == fence[0] and len(run) >= len(fence):
                    fence = None
                continue
            if len(line) > 120 and not line.lstrip().startswith("|"):
                print(f"{shown}:{number}: columns: {len(line)}")
                findings += 1
            text = line
            if spanned:
                # The previous line opened a span: the text up to its closing backtick is code.
                closing = text.find("`")
                spanned = closing < 0
                text = "" if spanned else text[closing + 1 :]
            text = CODE_SPAN.sub("", text)
            if text.count("`") % 2:
                # An odd backtick count opens a span that wraps onto the next line.
                text = text[: text.rfind("`")]
                spanned = True
            text = HTML_COMMENT.sub("", text)
            hits = (
                ("semicolon", ";" in text),
                ("dash", any(dash in text for dash in DASHES)),
                ("vocabulary", bool(VOCABULARY.search(text) or SHAPE_LETTER.search(text))),
                ("api_key", bool(BARE_API_KEY.search(text))),
            )
            for rule, hit in hits:
                if hit:
                    print(f"{shown}:{number}: {rule}: {text.strip()}")
                    findings += 1
    return 1 if findings else 0


USAGE = "usage: check-site.py links [SITE_DIR] | prose [PATH...]"


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "links":
        prefix = site_prefix(ROOT / "zensical.toml")
        if prefix is None:
            return 1
        return check_links(pathlib.Path(argv[2]) if len(argv) > 2 else SITE, prefix)
    if len(argv) >= 2 and argv[1] == "prose":
        return check_prose(prose_files([pathlib.Path(p) for p in argv[2:]]))
    print(USAGE)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
