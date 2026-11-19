#!/usr/bin/env python3
"""Assembles one documentation tree from the site's own pages and a checkout of each product.

The tree holds the site's own `docs/` and `overrides/`, each product's `docs/site/` under the product's folder, and the
configuration with a nav merged from the start page and each product's `docs/nav.toml`. Zensical builds the site from
it, with the tree as its working directory.

The script refuses what the strict build accepts without a word: a nav path that leaves its product's folder, a page
that no nav entry names, a product folder that the site's own `docs/` takes and a symbolic link in a tree it copies. It
checks each source and the output directory before its first write, so a refused run writes nothing and removes
nothing, and a tree from an earlier run stays whole.
"""
import argparse
import json
import os
import pathlib
import posixpath
import sys
import tomllib
import typing

ROOT = pathlib.Path(__file__).resolve().parent.parent
USAGE = "assemble.py --checkout FOLDER=PATH [--checkout FOLDER=PATH ...] [--out DIR]"
THIS = "this repository"


class Source(typing.NamedTuple):
    folder: str
    repository: str
    title: str


def read_sources(root: pathlib.Path) -> list[Source]:
    """The products of sources.toml, in the file's order, which is the tabs'."""
    with open(root / "sources.toml", "rb") as file:
        data = tomllib.load(file)
    return [Source(entry["folder"], entry["repository"], entry["title"]) for entry in data["source"]]


def checkout_pair(value: str) -> tuple[str, pathlib.Path]:
    """A `FOLDER=PATH` argument as its two halves. argparse reports any other value as a usage error."""
    folder, sep, path = value.partition("=")
    if not sep or not folder or not path:
        raise argparse.ArgumentTypeError(f"{value!r} is no FOLDER=PATH")
    return folder, pathlib.Path(path)


MARKER = ".phoebis-docs-build"
MARKER_TEXT = "scripts/assemble.py wrote this tree and removes from it what its sources no longer hold.\n"


def walk(top: pathlib.Path) -> tuple[list[str], list[str]]:
    """The files under `top` at each depth and the entries that are symbolic links, as sorted paths relative to it.

    The walk follows no link: a copy that follows one carries a file from outside the tree into the published site. A
    link at `top` itself is the caller's to test, since a scan of a linked directory reads it as a plain one.
    """
    files, links = [], []
    pending = [""] if top.is_dir() else []
    while pending:
        folder = pending.pop()
        with os.scandir(top / folder) as entries:
            for entry in entries:
                path = posixpath.join(folder, entry.name)
                if entry.is_symlink():
                    links.append(path)
                elif entry.is_dir():
                    pending.append(path)
                elif entry.is_file():
                    files.append(path)
    return sorted(files), sorted(links)


def linked(owner: str, path: str) -> str:
    return f"{owner}: {path} is a symbolic link, and the assembly copies none"


def shape(value) -> str:
    """A TOML value's kind, for the reason a nav does not read."""
    if isinstance(value, dict):
        return "a table with one key" if len(value) == 1 else f"a table with {len(value)} keys"
    if isinstance(value, list):
        return "an array"
    if isinstance(value, bool):
        return "a boolean"
    if isinstance(value, (int, float)):
        return "a number"
    return "a date or a time"


def read_nav(path: pathlib.Path) -> tuple[list, list[str]]:
    """The `nav` array of a product's docs/nav.toml and each path it names, a section's at each depth. A ValueError
    carries the reason a file does not read as a nav, so the run reports it with a line and no traceback."""
    try:
        with open(path, "rb") as file:
            data = tomllib.load(file)
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise ValueError(str(error)) from error
    nav = data.get("nav")
    if not isinstance(nav, list):
        raise ValueError("it holds no nav array")
    return nav, nav_paths(nav)


def nav_paths(nav: list) -> list[str]:
    paths = []
    for entry in nav:
        if isinstance(entry, str):
            paths.append(entry)
            continue
        if not isinstance(entry, dict) or len(entry) != 1:
            raise ValueError(f"an entry is {shape(entry)}, and each entry is a path or a table with one key")
        ((title, value),) = entry.items()
        if isinstance(value, str):
            paths.append(value)
        elif isinstance(value, list):
            paths += nav_paths(value)
        else:
            raise ValueError(
                f"the entry {json.dumps(title, ensure_ascii=False)} holds {shape(value)}, and each entry holds a path"
                " or an array"
            )
    return paths


def leaves(path: str) -> bool:
    """Whether a nav path names a file outside its product's folder. A name such as `..notes/a.md` stays inside."""
    return posixpath.isabs(path) or posixpath.normpath(path).split("/")[0] == ".."


def read_site(root: pathlib.Path, sources: list[Source], problems: list[str]) -> dict[str, list[str]]:
    """The files of the repository's own `docs/` and `overrides/`, with each problem of the two trees in `problems`."""
    trees = {}
    for name in ("docs", "overrides"):
        top = root / name
        if top.is_symlink():
            problems.append(linked(THIS, name))
            trees[name] = []
            continue
        files, links = walk(top)
        problems += [linked(THIS, f"{name}/{link}") for link in links]
        trees[name] = files
    problems += [
        f"{THIS}: docs/{page} is in no nav entry, and the site's own nav names index.md alone"
        for page in trees["docs"]
        if page.endswith(".md") and page != "index.md"
    ]
    problems += [
        f"sources.toml: the folder {source.folder} is taken by docs/{source.folder} of this repository"
        for source in sources
        if os.path.lexists(root / "docs" / source.folder)
    ]
    return trees


def read_product(source: Source, checkout: pathlib.Path, problems: list[str]) -> tuple[list, list[str]]:
    """The product's nav and the files under its `docs/site/`, with each problem of the checkout in `problems`."""
    repository = source.repository
    nav_file = checkout / "docs/nav.toml"
    site = checkout / "docs/site"
    nav, paths, files = [], None, []
    if nav_file.is_symlink():
        problems.append(linked(repository, "docs/nav.toml"))
    elif not nav_file.exists():
        problems.append(f"{repository}: docs/nav.toml is missing under {checkout}")
    else:
        try:
            nav, paths = read_nav(nav_file)
        except ValueError as error:
            problems.append(f"{repository}: docs/nav.toml does not read as a nav: {error}")
    if site.is_symlink():
        problems.append(linked(repository, "docs/site"))
        return nav, files
    if not os.path.lexists(site / "index.md"):
        problems.append(f"{repository}: docs/site/index.md is missing under {checkout}")
    files, links = walk(site)
    problems += [linked(repository, f"docs/site/{link}") for link in links]
    if paths is None:
        return nav, files
    named = set()
    for path in paths:
        if leaves(path):
            problems.append(f"{repository}: docs/nav.toml names {path}, which leaves docs/site/")
        else:
            named.add(posixpath.normpath(path))
    problems += [
        f"{repository}: docs/site/{page} is in no entry of docs/nav.toml"
        for page in files
        if page.endswith(".md") and page not in named
    ]
    return nav, files


def prefixed(nav: list, folder: str) -> list:
    """The product's nav with the folder in front of each path, a bare path's as a titled one's."""
    entries = []
    for entry in nav:
        if isinstance(entry, str):
            entries.append(f"{folder}/{entry}")
            continue
        ((title, value),) = entry.items()
        entries.append({title: f"{folder}/{value}" if isinstance(value, str) else prefixed(value, folder)})
    return entries


def toml_nav(nav, depth=1):
    """The nav as a TOML array with one entry per line, a section's array nested inside its entry."""
    pad = "  " * depth
    lines = ["["]
    for entry in nav:
        if isinstance(entry, str):
            lines.append(f"{pad}{json.dumps(entry, ensure_ascii=False)},")
            continue
        ((title, value),) = entry.items()
        inner = json.dumps(value, ensure_ascii=False) if isinstance(value, str) else toml_nav(value, depth + 1)
        lines.append(f"{pad}{{ {json.dumps(title, ensure_ascii=False)} = {inner} }},")
    lines.append("  " * (depth - 1) + "]")
    return "\n".join(lines)


def own_tree(out: pathlib.Path) -> bool:
    """Whether `out` is missing, empty or a tree this script wrote. The upkeep removes files, so an `out` that names a
    product's checkout would otherwise lose that product's nav and its pages."""
    if not os.path.lexists(out):
        return True
    if not out.is_dir():
        return False
    return not any(out.iterdir()) or (out / MARKER).is_file()


def prune(out: pathlib.Path, name: str, keep: dict[str, pathlib.Path]) -> None:
    """Removes under `out/<name>` each file that `keep` does not name and each folder that empties.

    The walk stays inside `docs/` and `overrides/`, so the `site/` that Zensical writes and each other entry at the
    tree's top, such as another build tree inside this one, stay as they are. A link is removed and never followed.
    """
    top = out / name
    if top.is_symlink():
        top.unlink()
        return
    files, links = walk(top)
    for path in links + [path for path in files if f"{name}/{path}" not in keep]:
        (top / path).unlink()
    for folder, _, _ in os.walk(top, topdown=False):
        if not os.listdir(folder):
            os.rmdir(folder)


def write(target: pathlib.Path, data: bytes) -> None:
    """Writes `data` unless the file already holds those bytes. The preview runs the assembly again at each edit while
    Zensical serves the tree, and a rewritten file hands the server a change for a page that did not change."""
    if target.is_symlink():
        target.unlink()
    elif target.is_file() and target.read_bytes() == data:
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)


def assemble(root: pathlib.Path, checkouts: dict[str, pathlib.Path], out: pathlib.Path) -> list[str]:
    """Writes the build tree under `out` and returns no line, or returns one line per problem and writes and removes
    nothing."""
    problems = []
    sources = read_sources(root)
    folders = {source.folder for source in sources}
    problems += [f"sources.toml names no folder {folder}" for folder in checkouts if folder not in folders]
    problems += [
        f"sources.toml: no checkout for {source.folder}, pass --checkout {source.folder}=<path>"
        for source in sources
        if source.folder not in checkouts
    ]
    site = read_site(root, sources, problems)
    keep = {f"docs/{path}": root / "docs" / path for path in site["docs"]}
    keep |= {f"overrides/{path}": root / "overrides" / path for path in site["overrides"]}
    nav = [{"Home": "index.md"}]
    for source in sources:
        checkout = checkouts.get(source.folder)
        if checkout is None:
            continue
        product_nav, files = read_product(source, checkout, problems)
        nav.append({source.title: prefixed(product_nav, source.folder)})
        keep |= {f"docs/{source.folder}/{path}": checkout / "docs/site" / path for path in files}
    lines = (root / "zensical.toml").read_text(encoding="utf-8").splitlines(keepends=True)
    project = next((index for index, line in enumerate(lines) if line.strip() == "[project]"), None)
    if project is None:
        problems.append("zensical.toml: no [project] line to write the nav behind")
    if not own_tree(out):
        problems.append(
            f"--out: {out} is neither missing nor empty nor a tree this script wrote, which holds {MARKER}"
        )
    if problems:
        return problems

    lines[project] = lines[project].rstrip("\n") + "\n"
    lines.insert(project + 1, f"nav = {toml_nav(nav)}\n")
    out.mkdir(parents=True, exist_ok=True)
    if not (out / MARKER).exists():
        (out / MARKER).write_text(MARKER_TEXT, encoding="utf-8")
    for name in ("docs", "overrides"):
        prune(out, name, keep)
    for path, source_file in sorted(keep.items()):
        write(out / path, source_file.read_bytes())
    write(out / "zensical.toml", "".join(lines).encode("utf-8"))
    return []


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="assemble.py", usage=USAGE, description=__doc__.splitlines()[0])
    parser.add_argument(
        "--checkout",
        action="append",
        required=True,
        type=checkout_pair,
        metavar="FOLDER=PATH",
        help="a product's checkout, one per folder of sources.toml",
    )
    parser.add_argument(
        "--out", type=pathlib.Path, default=ROOT / "build", metavar="DIR", help="the build tree, build/ by default"
    )
    args = parser.parse_args(argv)
    problems = assemble(ROOT, dict(args.checkout), args.out)
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
