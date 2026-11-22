#!/usr/bin/env bash
# The preview has to read a checkout's path the way the README states it: a flag wins over checkouts.toml, and a
# relative path in that file is read from the file's folder. It also has to see an edit at each depth of a checkout's
# pages. A run with three flags from the repository's root that edits a page at the top level shows none of the
# three. The script finds its repository from its own path, so each case works on a copy of it inside a throwaway
# repository. The cases of a flag, of a relative path and of a page one folder down import the copy and call one of its
# functions, and each other case runs the command. A case that starts a server puts a stand-in for pipx first on the
# PATH, which starts no Zensical.
set -euo pipefail

here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
started=
# A case that fails leaves its preview and the stand-in's sleep behind, which would outlive the build's step. The
# cleanup ends the process group of the preview in flight and reads no process id from a file: an id that a finished
# case left can belong to another process by now, and a stand-in that has not written its id yet would be missed.
cleanup() {
  [ -z "$started" ] || kill -KILL -- "-$started" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
# A case that runs the command with another PATH reaches the interpreter by its path.
python=$(command -v python3)
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

# A value of checkouts.toml that is no path, such as a number, names no checkout. A reader that hands it on as a path
# fails in the path join, and the line it ends with names no key, so the writer cannot tell which entry to mend. The key
# holds a line feed, which TOML takes in a quoted key, so a refusal that prints the key as it stands runs over two
# lines.
repository "$tmp/number/repo"
printf '"alpha\\nbeta" = 5\n' > "$tmp/number/repo/checkouts.toml"
out=$(python3 "$tmp/number/repo/scripts/preview.py" 2>&1) && fail "a checkouts.toml whose value is a number passed"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "a checkouts.toml whose value is a number printed more than one line: $out"
grep -qF 'checkouts.toml' <<< "$out" || fail "the line for a value that is a number names no file: $out"
grep -qw 'alpha' <<< "$out" || fail "the line for a value that is a number names no key: $out"

# A look that stops at the top level of a checkout's docs/site/ misses an edit of a page or an image one folder down,
# so the preview runs no assembly for it and the browser keeps the old page.
repository "$tmp/nested/repo"
mkdir -p "$tmp/nested/alpha/docs/site/guide"
echo '# Page' > "$tmp/nested/alpha/docs/site/guide/page.md"
why=$(python3 - "$tmp/nested" <<'PY'
import pathlib
import sys

sys.path.insert(0, f"{sys.argv[1]}/repo/scripts")
import preview

alpha = pathlib.Path(sys.argv[1], "alpha")
if alpha / "docs/site/guide/page.md" not in preview.snapshot(preview.ROOT, {"alpha": alpha}):
    print("docs/site/guide/page.md of a checkout is in no look at the sources")
    sys.exit(1)
PY
) || fail "${why:-the call of snapshot ended with a traceback}"

# A serving Zensical stays until a signal ends it, so the stand-in for pipx records the arguments it was handed and its
# own process id and then stays as long. It replaces itself with the sleep, so the recorded id is the server's.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/pipx" <<'PIPX'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$PIPX_RECORD/args"
echo "$$" > "$PIPX_RECORD/pid"
exec sleep 600
PIPX
chmod +x "$tmp/bin/pipx"

# A site of one product whose assembly refuses nothing, so the command goes on to its server.
site() {
  repository "$1/repo"
  mkdir -p "$1/repo/docs" "$1/alpha/docs/site" "$1/record"
  printf '[project]\nsite_name = "Manual"\n' > "$1/repo/zensical.toml"
  printf '[[source]]\nfolder = "alpha"\nrepository = "example/alpha"\ntitle = "Alpha"\n' > "$1/repo/sources.toml"
  echo '# Start' > "$1/repo/docs/index.md"
  echo '# Alpha' > "$1/alpha/docs/site/index.md"
  printf 'nav = [ "index.md" ]\n' > "$1/alpha/docs/nav.toml"
}
# setsid makes the command the leader of a process group of its own, so the cleanup can end the command and its server
# together and reach no other process. The script runs without job control, so the background command leads no group
# of its own, setsid then replaces itself with the command without a fork, and $! is the id of the command and of its
# group. A case that saw its preview end sets started to nothing again.
preview() {
  PIPX_RECORD="$1/record" PATH="$tmp/bin:$PATH" setsid "$python" "$1/repo/scripts/preview.py" \
    --checkout alpha="$1/alpha" > "$1/out" 2>&1 &
  started=$!
}
# A case waits on the state it reads, ten seconds at most, so it holds no fixed sleep and a break cannot hang the build.
wait_until() {
  local tries=0
  until "$@"; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.1
  done
}
# A child that ended stays a zombie until its parent waits for it, and a signal 0 still reaches a zombie.
ended() {
  case "$(ps -o state= -p "$1" 2>/dev/null)" in
    '' | Z*) return 0 ;;
    *) return 1 ;;
  esac
}

# A launch with no handler for a missing program ends a host without pipx in the traceback of FileNotFoundError, where
# one line names the program that the run lacks. An empty folder is the PATH, so no pipx of the host is found.
site "$tmp/bare"
mkdir "$tmp/bare/empty"
status=0
out=$(PATH="$tmp/bare/empty" "$python" "$tmp/bare/repo/scripts/preview.py" --checkout alpha="$tmp/bare/alpha" 2>&1) \
  || status=$?
[ "$status" != 0 ] || fail "a host without pipx passed"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "a host without pipx got more than one line: $out"
grep -qw 'pipx' <<< "$out" || fail "the line for a host without pipx names no pipx: $out"

# A loop that never looks at the sources leaves the build tree as the first assembly wrote it, so the served page stays
# the old one after its edit.
site "$tmp/serve"
preview "$tmp/serve"
wait_until [ -s "$tmp/serve/record/pid" ] || fail "the preview started no server: $(cat "$tmp/serve/out")"
echo '# Alpha, edited' > "$tmp/serve/alpha/docs/site/index.md"
wait_until grep -qxF '# Alpha, edited' "$tmp/serve/repo/build/docs/alpha/index.md" \
  || fail "an edited page of a checkout was not assembled again within ten seconds"

# kill sends SIGTERM, and a command that the signal's default action ends leaves its server on the port. The case ends
# the preview of the case above. An interrupt of the command answers 0, and an interrupt path that sets no status ends
# the command in a traceback after both processes are gone, which the two waits cannot tell from a clean end.
server=$(cat "$tmp/serve/record/pid")
kill -TERM "$started"
wait_until ended "$started" || fail "a SIGTERM did not end the preview within ten seconds"
wait_until ended "$server" || fail "a SIGTERM ended the preview and left its server running"
status=0
wait "$started" || status=$?
started=
[ "$status" = 0 ] || fail "a SIGTERM gave the preview the status $status, where 0 was due"

# A server that a signal ended has a negative return code, and a command that answers it raw gives the shell 241 for
# SIGTERM, where a shell reads 128 plus the signal's number, 143, as the end by that signal.
site "$tmp/status"
preview "$tmp/status"
wait_until [ -s "$tmp/status/record/pid" ] || fail "the preview started no server: $(cat "$tmp/status/out")"
kill -TERM "$(cat "$tmp/status/record/pid")"
wait_until ended "$started" || fail "the preview did not end within ten seconds of its server's end"
status=0
wait "$started" || status=$?
started=
[ "$status" = 143 ] || fail "a server that SIGTERM ended gave the command the status $status, where 143 was due"

echo "preview: ok"
