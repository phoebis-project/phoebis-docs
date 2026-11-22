#!/usr/bin/env python3
"""Serves the documentation site from local checkouts of the three products and follows their edits.

The command assembles the build tree as `scripts/assemble.py` does, starts `zensical serve` in it and then looks at
the sources once a second. When a file was added, removed or changed, it assembles again. The assembly writes what
differs and removes what is gone, so the serving Zensical sees the edited page alone and reloads it. A change the
assembly refuses prints its lines, and the served tree stays as the last good run left it.

A checkout's path comes from a `--checkout FOLDER=PATH` flag or from `checkouts.toml` at the repository's root, a file
git ignores that holds one key per folder. A flag wins over the file, and a relative path in the file is read from the
file's folder. Each argument behind `--` goes to `zensical serve`.
"""
import json
import pathlib
import signal
import stat
import subprocess
import sys
import time
import tomllib

from assemble import BUILD, ROOT, assemble, checkout_parser, read_sources, shape, source_roots

USAGE = "preview.py [--checkout FOLDER=PATH ...] [-- ZENSICAL_SERVE_ARG ...]"
ZENSICAL = "zensical==0.0.62"
# What a source raises while its writer is in the middle of a save: a file that is gone again, a TOML file that is
# half written, and a file that reads but holds no whole entry yet, which its reader refuses with a ValueError.
UNREAD = (OSError, ValueError)


def local_checkouts(root: pathlib.Path, flags: list[tuple[str, pathlib.Path]]) -> dict[str, pathlib.Path]:
    """Each product's checkout: its flag, or its key in checkouts.toml with a relative path read from that file's
    folder. A ValueError names the file, and for a value that is no path it also names the key."""
    named = {}
    file = root / "checkouts.toml"
    if file.exists():
        try:
            with open(file, "rb") as handle:
                data = tomllib.load(handle)
        except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
            raise ValueError(f"checkouts.toml does not read as TOML: {error}") from error
        for folder, path in data.items():
            if not isinstance(path, str):
                # The key in its quoted form, so a control character in it is escaped and the refusal stays one line.
                raise ValueError(
                    f"checkouts.toml: the key {json.dumps(folder, ensure_ascii=False)} holds {shape(path)}, and each"
                    " key holds a path"
                )
            named[folder] = root / path
    return named | dict(flags)


def snapshot(root: pathlib.Path, checkouts: dict[str, pathlib.Path]) -> dict[pathlib.Path, tuple[int, int]]:
    """Each source file with its size and its modification time, at each depth of each root that `source_roots` of
    the assembly names. The walk is fresh at each call, so a file added since the last look is in it."""
    files = {}
    pending = source_roots(root, checkouts)
    while pending:
        path = pending.pop()
        try:
            # A link counts as an entry of its own and is never followed, so the look that sees one arrive runs the
            # assembly, which refuses it.
            status = path.lstat()
            if stat.S_ISDIR(status.st_mode):
                pending += path.iterdir()
            else:
                files[path] = (status.st_size, status.st_mtime_ns)
        except FileNotFoundError:
            # A writer removed the path after its folder listed it, so the tree holds it no longer.
            continue
    return files


def say(line: str) -> None:
    # A reader follows the lines while the command runs, and a redirected stdout would hold them back in a block.
    print(line, flush=True)


def stopped(error: Exception) -> str:
    return f"not assembled: {type(error).__name__}: {error}"


def interrupt(signum, frame):
    raise KeyboardInterrupt


def serve(
    checkouts: dict[str, pathlib.Path],
    out: pathlib.Path,
    serve_args: list[str],
    seen: dict[pathlib.Path, tuple[int, int]],
) -> int:
    """Runs the server in the build tree and assembles again at each change of a source, from the look `seen` on.
    Returns the server's status, or 0 after an interrupt, which ends the server too."""
    # `kill` sends SIGTERM, whose default action would end this command and leave the server on its port.
    signal.signal(signal.SIGTERM, interrupt)
    server = None
    failed = None
    try:
        server = subprocess.Popen(["pipx", "run", ZENSICAL, "serve", *serve_args], cwd=out)
        while server.poll() is None:
            time.sleep(1)
            try:
                now = snapshot(ROOT, checkouts)
                if now == seen:
                    continue
                lines = assemble(ROOT, checkouts, out)
            except UNREAD as error:
                # `seen` keeps the last look that was assembled, so the next round runs the assembly again, and a
                # line that repeats from round to round is printed once.
                line = stopped(error)
                if line != failed:
                    say(line)
                failed = line
                continue
            seen, failed = now, None
            for line in lines:
                say(line)
        return server.returncode
    except KeyboardInterrupt:
        return 0
    finally:
        if server is not None and server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


def main(argv: list[str]) -> int:
    parser = checkout_parser(
        "preview.py",
        USAGE,
        __doc__,
        default=[],
        help="a product's checkout, which wins over the folder's key in checkouts.toml",
    )
    # argparse would read an option of `zensical serve` as one of its own, so it never sees what stands behind `--`.
    cut = argv.index("--") if "--" in argv else len(argv)
    args = parser.parse_args(argv[:cut])
    out = BUILD
    try:
        checkouts = local_checkouts(ROOT, args.checkout)
    except UNREAD as error:
        say(str(error))
        return 2
    try:
        missing = [source.folder for source in read_sources(ROOT) if source.folder not in checkouts]
        for folder in missing:
            say(f"no checkout for {folder}: pass --checkout {folder}=<path> or name it in checkouts.toml")
        if missing:
            return 2
        # Taken ahead of the assembly, so an edit that lands while it runs differs from this look at the first round.
        seen = snapshot(ROOT, checkouts)
        problems = assemble(ROOT, checkouts, out)
    except UNREAD as error:
        say(stopped(error))
        return 1
    for problem in problems:
        say(problem)
    if problems:
        return 1
    return serve(checkouts, out, argv[cut + 1 :], seen)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
