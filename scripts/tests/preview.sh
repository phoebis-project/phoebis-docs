#!/usr/bin/env bash
# The preview has to read a checkout's path the way the README states it: a flag wins over checkouts.toml, and a
# relative path in that file is read from the file's folder. A run with three flags from the repository's root shows
# neither. The script finds its repository from its own path, so each case imports a copy of it inside a throwaway
# repository and calls the function that reads the paths, which starts no server.
set -euo pipefail

here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1" >&2; exit 1; }

# The preview imports the assembly, so a throwaway repository takes both scripts.
repository() {
  mkdir -p "$1/scripts"
  cp "$here/scripts/assemble.py" "$here/scripts/preview.py" "$1/scripts/"
}

# A file that wins over a flag serves the checkout checkouts.toml names when the writer passes another one for a
# single run, and the pages on the screen are those of the wrong directory.
repository "$tmp/flag/repo"
printf 'alpha = "/from/the/file"\n' > "$tmp/flag/repo/checkouts.toml"
why=$(python3 - "$tmp/flag/repo" <<'PY'
import pathlib
import sys

sys.path.insert(0, f"{sys.argv[1]}/scripts")
import preview

checkouts = preview.local_checkouts(preview.ROOT, [("alpha", pathlib.Path("/from/the/flag"))])
if checkouts["alpha"] != pathlib.Path("/from/the/flag"):
    print(f"a folder with a flag and a key in checkouts.toml was read as {checkouts['alpha']}")
    sys.exit(1)
PY
) || fail "${why:-the call of local_checkouts ended with a traceback}"

# A relative path that is read from the working directory names another folder as soon as the preview starts from
# outside the repository, so the case runs from the file system's root.
repository "$tmp/relative/repo"
printf 'alpha = "../alpha"\n' > "$tmp/relative/repo/checkouts.toml"
why=$(cd / && python3 - "$tmp/relative" <<'PY'
import pathlib
import sys

sys.path.insert(0, f"{sys.argv[1]}/repo/scripts")
import preview

checkouts = preview.local_checkouts(preview.ROOT, [])
if checkouts["alpha"].resolve() != pathlib.Path(sys.argv[1], "alpha").resolve():
    print(f"../alpha in checkouts.toml was read as {checkouts['alpha'].resolve()}")
    sys.exit(1)
PY
) || fail "${why:-the call of local_checkouts ended with a traceback}"

echo "preview: ok"
