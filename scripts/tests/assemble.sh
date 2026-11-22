#!/usr/bin/env bash
# The assembly has to refuse what the strict build accepts without a word: a nav path that leaves its product's folder,
# a page no nav names, a product folder the site's own `docs/` takes and a symbolic link. It also has to leave a tree
# that a second run and a serving Zensical can rely on, and to leave alone a directory it did not write. The script
# finds its repository from its own path, so each case runs a copy of it inside a throwaway repository.
set -euo pipefail

here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1" >&2; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/docs" "$repo/overrides/partials"
cp "$here/scripts/assemble.py" "$repo/scripts/"
printf '[project]\nsite_name = "Manual"\ndocs_dir = "docs"\n' > "$repo/zensical.toml"
printf '[[source]]\nfolder = "alpha"\nrepository = "example/alpha"\ntitle = "Alpha"\n\n' > "$repo/sources.toml"
printf '[[source]]\nfolder = "beta"\nrepository = "example/beta"\ntitle = "Beta"\n' >> "$repo/sources.toml"
echo '# Start' > "$repo/docs/index.md"
: > "$repo/overrides/partials/logo.html"

# A product with a page one folder down and an image, which needs no nav entry.
product() {
  mkdir -p "$tmp/$1/docs/site/guides" "$tmp/$1/docs/site/assets"
  echo "# $1" > "$tmp/$1/docs/site/index.md"
  echo '# Setup' > "$tmp/$1/docs/site/guides/setup.md"
  : > "$tmp/$1/docs/site/assets/shot.png"
  printf 'nav = [\n  { "Overview" = "index.md" },\n  { "Guides" = [\n    { "Setup" = "guides/setup.md" },\n  ] },\n]\n' \
    > "$tmp/$1/docs/nav.toml"
}
# Each case starts from two whole products and no build tree, so no finding of an earlier case can satisfy it.
fresh() { rm -rf "$tmp/alpha" "$tmp/beta" "$tmp/out"; product alpha; product beta; }
run() { python3 "$repo/scripts/assemble.py" --checkout alpha="$tmp/alpha" --checkout beta="$tmp/beta" --out "$tmp/out"; }

# A nav path that leaves its folder lets one product's nav claim a page of another product or of the site, and the
# strict build accepts it. The nested path beside it has to pass.
fresh
run > /dev/null || fail "two products with a page one folder down and an image without a nav entry were refused"
sed -i 's|"guides/setup.md"|"../beta/index.md"|' "$tmp/alpha/docs/nav.toml"
rm "$tmp/alpha/docs/site/guides/setup.md"
out=$(run) && fail "a nav path that leaves its product's folder passed"
echo "$out" | grep -qF 'example/alpha: docs/nav.toml names ../beta/index.md, which leaves docs/site/' \
  || fail "a nav path that leaves its folder was refused without its line: $out"

# A page that no nav entry names is published outside the navigation, and the strict build accepts it. The page sits
# one folder down, so a walk of the top level alone misses it.
fresh
echo '# Orphan' > "$tmp/alpha/docs/site/guides/orphan.md"
out=$(run) && fail "a page that no nav entry names passed"
echo "$out" | grep -qF 'example/alpha: docs/site/guides/orphan.md is in no entry of docs/nav.toml' \
  || fail "a page that no nav entry names was refused without its line: $out"

# A product folder that the site's own docs/ takes is overwritten by the product's copy without a word. The file in it
# is an image, which needs no nav entry, so the taken folder is the tree's one problem.
fresh
mkdir -p "$repo/docs/alpha"
: > "$repo/docs/alpha/shot.png"
out=$(run) && fail "a product folder that the site's own docs/ takes passed"
echo "$out" | grep -qF 'sources.toml: the folder alpha is taken by docs/alpha of this repository' \
  || fail "a product folder that the site's own docs/ takes was refused without its line: $out"
rm -rf "$repo/docs/alpha"

# An index.md at a nav's top that the merge leaves without its folder names the site's start page, which exists, so
# no dead entry shows and the product's tab opens the wrong page. The link check cannot report that one path, bare or
# titled.
fresh
printf 'nav = [ "index.md", { "Setup" = "guides/setup.md" } ]\n' > "$tmp/beta/docs/nav.toml"
run > /dev/null || fail "a bare index.md and a titled one at the top of a nav were refused"
why=$(python3 - "$tmp/out/zensical.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as file:
    nav = tomllib.load(file)["project"]["nav"]
if nav[2]["Beta"][0] != "beta/index.md":
    print(f"the bare index.md at the top of beta's nav was merged as {nav[2]['Beta'][0]!r}")
    sys.exit(1)
if nav[1]["Alpha"][0] != {"Overview": "alpha/index.md"}:
    print(f"the titled index.md at the top of alpha's nav was merged as {nav[1]['Alpha'][0]!r}")
    sys.exit(1)
PY
) || fail "${why:-the written zensical.toml did not read as the merged nav}"

# The preview runs the assembly again at each edit while Zensical serves the tree, and a second local build reuses it
# too, so a page its product no longer holds has to leave the tree, or a link to the old page passes on that machine
# alone. The removal stays inside the tree's docs/ and overrides/: an upkeep that walks the whole tree removes the
# site/ that Zensical wrote and each tree nested beside it.
fresh
run > /dev/null || fail "two whole products were refused"
rm "$tmp/alpha/docs/site/guides/setup.md"
printf 'nav = [\n  { "Overview" = "index.md" },\n]\n' > "$tmp/alpha/docs/nav.toml"
mkdir -p "$tmp/out/site"
: > "$tmp/out/site/keep.html"
run > /dev/null || fail "a second run into the tree the first one wrote was refused"
[ ! -e "$tmp/out/docs/alpha/guides/setup.md" ] || fail "a page its product no longer holds stayed in the build tree"
[ -f "$tmp/out/docs/alpha/index.md" ] || fail "a page its product still holds left the build tree"
[ -f "$tmp/out/site/keep.html" ] || fail "a second run removed a file of the tree's site/, which Zensical writes"

# A refusal that comes after part of the tree is written leaves a served tree half new. The edit is in the first
# product and the refusal in the second, so an assembly that copies one product before it checks the next shows it.
fresh
run > /dev/null || fail "two whole products were refused"
echo '# alpha, edited' > "$tmp/alpha/docs/site/index.md"
echo '# Orphan' > "$tmp/beta/docs/site/orphan.md"
run > /dev/null && fail "a page that no nav entry names passed"
[ "$(cat "$tmp/out/docs/alpha/index.md")" = '# alpha' ] || fail "a refused run wrote alpha's edited page into the tree"

# A source that does not read stops a run after its checks pass. An upkeep that runs ahead of the reads has by then
# removed each page the sources no longer hold, so the run leaves the last good tree short of a page. The page leaves
# alpha and the file that does not read is beta's, so such an upkeep runs before the read fails.
# Root reads a file of any mode, so as root no source fails to read and the case cannot show the break.
if [ "$(id -u)" = 0 ]; then
  echo "skip: a source that does not read, since root reads a file of any mode"
else
  fresh
  run > /dev/null || fail "two whole products were refused"
  rm "$tmp/alpha/docs/site/guides/setup.md"
  printf 'nav = [\n  { "Overview" = "index.md" },\n]\n' > "$tmp/alpha/docs/nav.toml"
  chmod 000 "$tmp/beta/docs/site/index.md"
  run > /dev/null 2>&1 && fail "a run with a source that does not read passed"
  [ -f "$tmp/out/docs/alpha/guides/setup.md" ] \
    || fail "a run that stopped on a source it cannot read removed a page of the last tree"
fi

# The preview runs the assembly again at each edit while Zensical serves the tree, so a page whose bytes did not
# change keeps its file, or the server sees a change for each page at each save.
fresh
run > /dev/null || fail "two whole products were refused"
touch -d '2001-01-01 00:00:00 UTC' "$tmp/out/docs/alpha/index.md" "$tmp/out/docs/beta/index.md"
echo '# beta, edited' > "$tmp/beta/docs/site/index.md"
run > /dev/null || fail "a second run into the tree the first one wrote was refused"
[ "$(stat -c %Y "$tmp/out/docs/alpha/index.md")" = 978307200 ] \
  || fail "a page whose bytes did not change was written again"
[ "$(cat "$tmp/out/docs/beta/index.md")" = '# beta, edited' ] || fail "a page whose bytes changed was not written again"

# A copy follows a symbolic link, so a file from outside a product's pages would land in the published site, which no
# build step reports. An image needs no nav entry, so the link is the tree's one problem.
fresh
: > "$tmp/outside.png"
ln -s "$tmp/outside.png" "$tmp/alpha/docs/site/assets/linked.png"
out=$(run) && fail "a symbolic link under a product's docs/site/ passed"
echo "$out" | grep -qF 'example/alpha: docs/site/assets/linked.png is a symbolic link, and the assembly copies none' \
  || fail "a symbolic link under a product's docs/site/ was refused without its line: $out"
# A walk reads a linked top directory as a plain one, so a linked docs/site would be copied whole from wherever it
# points.
fresh
mv "$tmp/beta/docs/site" "$tmp/beta-site"
ln -s "$tmp/beta-site" "$tmp/beta/docs/site"
out=$(run) && fail "a product's docs/site as a symbolic link passed"
echo "$out" | grep -qF 'example/beta: docs/site is a symbolic link, and the assembly copies none' \
  || fail "a product's docs/site as a symbolic link was refused without its line: $out"
# The site's own docs/ as a link is a linked top directory too, so the walk would copy it whole from wherever it points.
fresh
mv "$repo/docs" "$tmp/site-docs"
ln -s "$tmp/site-docs" "$repo/docs"
status=0
out=$(run) || status=$?
[ "$status" = 1 ] || fail "the site's own docs/ as a symbolic link exited $status, where a refusal exits 1: $out"
echo "$out" | grep -qF 'this repository: docs is a symbolic link, and the assembly copies none' \
  || fail "the site's own docs/ as a symbolic link was refused without its line: $out"
[ ! -e "$tmp/out" ] || fail "a run that refused the site's own docs/ as a symbolic link wrote a build tree"
rm "$repo/docs"
mv "$tmp/site-docs" "$repo/docs"
# The walk copies no link, so a link under the site's own docs/ that the run does not report drops its file from the
# site without a word.
fresh
: > "$tmp/site-shot.png"
ln -s "$tmp/site-shot.png" "$repo/docs/linked.png"
status=0
out=$(run) || status=$?
[ "$status" = 1 ] || fail "a symbolic link under the site's own docs/ exited $status, where a refusal exits 1: $out"
echo "$out" | grep -qF 'this repository: docs/linked.png is a symbolic link, and the assembly copies none' \
  || fail "a symbolic link under the site's own docs/ was refused without its line: $out"
[ ! -e "$tmp/out" ] || fail "a run that refused a symbolic link under the site's own docs/ wrote a build tree"
rm "$repo/docs/linked.png"
# A product's docs as a link would carry the nav and the pages in from wherever it points, and the tests of
# docs/nav.toml and docs/site below it read two plain entries.
fresh
mv "$tmp/beta/docs" "$tmp/beta-docs"
ln -s "$tmp/beta-docs" "$tmp/beta/docs"
status=0
out=$(run) || status=$?
[ "$status" = 1 ] || fail "a product's docs as a symbolic link exited $status, where a refusal exits 1: $out"
echo "$out" | grep -qF 'example/beta: docs is a symbolic link, and the assembly copies none' \
  || fail "a product's docs as a symbolic link was refused without its line: $out"
[ ! -e "$tmp/out" ] || fail "a run that refused a product's docs as a symbolic link wrote a build tree"
# A product's docs/nav.toml as a link would read a file from outside the checkout as the product's nav.
fresh
mv "$tmp/alpha/docs/nav.toml" "$tmp/alpha-nav.toml"
ln -s "$tmp/alpha-nav.toml" "$tmp/alpha/docs/nav.toml"
status=0
out=$(run) || status=$?
[ "$status" = 1 ] || fail "a product's docs/nav.toml as a symbolic link exited $status, where a refusal exits 1: $out"
echo "$out" | grep -qF 'example/alpha: docs/nav.toml is a symbolic link, and the assembly copies none' \
  || fail "a product's docs/nav.toml as a symbolic link was refused without its line: $out"
[ ! -e "$tmp/out" ] || fail "a run that refused a product's docs/nav.toml as a symbolic link wrote a build tree"

# The upkeep removes files, so an --out that names a product's checkout would lose pages that are not committed yet.
fresh
out=$(python3 "$repo/scripts/assemble.py" --checkout alpha="$tmp/alpha" --checkout beta="$tmp/beta" \
  --out "$tmp/alpha") && fail "an --out that names a product's checkout passed"
echo "$out" | grep -qF -- "--out: $tmp/alpha is neither missing nor empty nor a tree this script wrote" \
  || fail "an --out that names a product's checkout was refused without its line: $out"
[ -f "$tmp/alpha/docs/nav.toml" ] || fail "an --out that names a product's checkout lost the product's docs/nav.toml"

# The site's own nav is the start page alone, so a second page of the site's own docs/ is published outside the
# navigation, and the strict build accepts it.
fresh
echo '# Extra' > "$repo/docs/extra.md"
out=$(run) && fail "a page of the site's own docs/ beside the start page passed"
echo "$out" \
  | grep -qF "this repository: docs/extra.md is in no nav entry, and the site's own nav names index.md alone" \
  || fail "a page of the site's own docs/ beside the start page was refused without its line: $out"
rm "$repo/docs/extra.md"

# An entry of sources.toml whose key holds a number, such as a folder typed without its quotes, names no folder. A
# reader that tests each key's presence and never the value's kind hands the number on to a path join and ends in a
# traceback, where the run owes one line that names the file and the key.
fresh
cp "$repo/sources.toml" "$tmp/sources.toml"
printf '[[source]]\nfolder = 5\nrepository = "example/alpha"\ntitle = "Alpha"\n' > "$repo/sources.toml"
status=0
out=$(run 2>&1) || status=$?
cp "$tmp/sources.toml" "$repo/sources.toml"
[ "$status" = 1 ] || fail "a sources.toml whose folder is a number exited $status, where a refusal exits 1: $out"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "a sources.toml whose folder is a number printed more than one line: $out"
grep -qF 'sources.toml' <<< "$out" || fail "the line for a folder that is a number names no file: $out"
grep -qw 'folder' <<< "$out" || fail "the line for a folder that is a number names no key: $out"

# An entry of sources.toml that is no table, such as a folder's name where its table belongs, holds no key to read. A
# reader that tests each key and never the entry's kind ends in a traceback, where the run owes one line that names the
# file.
fresh
cp "$repo/sources.toml" "$tmp/sources.toml"
printf 'source = ["alpha"]\n' > "$repo/sources.toml"
status=0
out=$(run 2>&1) || status=$?
cp "$tmp/sources.toml" "$repo/sources.toml"
[ "$status" = 1 ] || fail "a sources.toml whose entry is no table exited $status, where a refusal exits 1: $out"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "a sources.toml whose entry is no table printed more than one line: $out"
grep -qF 'sources.toml' <<< "$out" || fail "the line for an entry that is no table names no file: $out"

# A sources.toml in the middle of an edit holds an entry without one of its keys. A reader that indexes the entry
# untested ends in a traceback, where the run owes one line that names the file and the key.
fresh
cp "$repo/sources.toml" "$tmp/sources.toml"
printf '[[source]]\nfolder = "alpha"\nrepository = "example/alpha"\n' > "$repo/sources.toml"
status=0
out=$(run 2>&1) || status=$?
cp "$tmp/sources.toml" "$repo/sources.toml"
[ "$status" = 1 ] || fail "a sources.toml whose entry lacks its title exited $status, where a refusal exits 1: $out"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "a sources.toml whose entry lacks its title printed more than one line: $out"
grep -qF 'sources.toml' <<< "$out" || fail "the line for an entry that lacks its title names no file: $out"
grep -qw 'title' <<< "$out" || fail "the line for an entry that lacks its title names no key: $out"

# An editor that truncates sources.toml and writes it again leaves an empty file for an instant, which is valid TOML
# with no source list. A reader that indexes the list untested ends a running preview there with a traceback, where the
# run owes one line that names the file.
fresh
cp "$repo/sources.toml" "$tmp/sources.toml"
: > "$repo/sources.toml"
status=0
out=$(run 2>&1) || status=$?
cp "$tmp/sources.toml" "$repo/sources.toml"
[ "$status" = 1 ] || fail "an empty sources.toml exited $status, where a refusal exits 1: $out"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || fail "an empty sources.toml printed more than one line: $out"
grep -qF 'sources.toml' <<< "$out" || fail "the line for an empty sources.toml names no file: $out"

echo "assemble: ok"
