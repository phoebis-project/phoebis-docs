#!/usr/bin/env bash
# The backticks inside single quotes are literal Markdown the cases write and match, never expansions.
# shellcheck disable=SC2016
# The two checks have to fail on what they exist to catch: a dangling link, a fragment its page lacks and prose that
# breaks a rule, on a page of a product's folder as on one at the tree's top. Each case runs against a throwaway tree,
# never the real site. The script reads the site's path prefix from the configuration of its own repository, so the
# cases run a copy of it inside a throwaway repository that holds one.
set -euo pipefail

here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1" >&2; exit 1; }

mkdir -p "$tmp/repo/scripts"
cp "$here/scripts/check-site.py" "$tmp/repo/scripts/"
printf '[project]\nsite_url = "https://docs.example/manual/"\n' > "$tmp/repo/zensical.toml"
check="$tmp/repo/scripts/check-site.py"

mkdir -p "$tmp/site/good" "$tmp/site/assets"
: > "$tmp/site/assets/a.png"
cat > "$tmp/site/index.html" <<'HTML'
<h1 id="top">top</h1><a href="good/">ok</a><a href="#top">ok</a><a href="https://example.com/x">ok</a>
<img src="assets/a.png#only-light"><img src="assets/a.png#only-dark">
HTML
echo '<a href="../">ok</a><a href="/manual/assets/a.png">ok</a>' > "$tmp/site/good/index.html"
python3 "$check" links "$tmp/site" >/dev/null || fail "a site whose links all resolve was refused"
echo '<a href="missing/">gone</a>' >> "$tmp/site/good/index.html"
out=$(python3 "$check" links "$tmp/site" 2>&1) && fail "a dangling link passed"
echo "$out" | grep -q "resolves to nothing" || fail "dangling link did not report resolves to nothing: $out"

# Each case below runs against its own throwaway site so the finding it checks for cannot be satisfied by
# a leftover dangling link from an earlier case.

# A root-relative link whose first segment is not the site's own prefix must not fall back to site/, or
# every such link would resolve to the site root's index.html.
mkdir -p "$tmp/prefix-site"
echo '<a href="/anything/">gone</a>' > "$tmp/prefix-site/index.html"
out=$(python3 "$check" links "$tmp/prefix-site" 2>&1) && fail "a root-relative link with an unrelated prefix passed"
echo "$out" | grep -q "index.html: /anything/ resolves to nothing" || fail "wrong finding for unrelated prefix: $out"

# A root-relative link missing the site's own prefix must fail even when an unprefixed path of the same name
# exists directly under site/, which is exactly how the built tree is laid out locally.
mkdir -p "$tmp/unprefixed-site/installation"
: > "$tmp/unprefixed-site/installation/index.html"
echo '<a href="/installation/">gone</a>' > "$tmp/unprefixed-site/index.html"
out=$(python3 "$check" links "$tmp/unprefixed-site" 2>&1) && fail "a root-relative link without the site prefix passed"
echo "$out" | grep -q "index.html: /installation/ resolves to nothing" || fail "wrong finding for unprefixed link: $out"

# The same link, carrying the site's own prefix, must resolve.
mkdir -p "$tmp/prefixed-site/installation"
: > "$tmp/prefixed-site/installation/index.html"
echo '<a href="/manual/installation/">ok</a>' > "$tmp/prefixed-site/index.html"
python3 "$check" links "$tmp/prefixed-site" >/dev/null || fail "a root-relative link with the site prefix was refused"

# A root-relative link into a directory that has no index.html must not fall back past its own path.
mkdir -p "$tmp/missing-dir-site"
echo '<a href="/manual/x/index.html">gone</a>' > "$tmp/missing-dir-site/index.html"
out=$(python3 "$check" links "$tmp/missing-dir-site" 2>&1) && fail "a link into a missing directory passed"
echo "$out" | grep -q "index.html: /manual/x/index.html resolves to nothing" || fail "wrong finding for missing directory: $out"

# A relative link must not be allowed to climb out of site/ onto the repository tree.
mkdir -p "$tmp/escape/site"
echo '# Outside the site' > "$tmp/escape/README.md"
echo '<a href="../README.md">gone</a>' > "$tmp/escape/site/index.html"
out=$(python3 "$check" links "$tmp/escape/site" 2>&1) && fail "a relative link escaping site/ passed"
echo "$out" | grep -q "index.html: ../README.md resolves to nothing" || fail "wrong finding for escaping link: $out"

# A fragment is read against the ids of the page it lands on: the linked page's for `other/#x`, its own for `#x`.
mkdir -p "$tmp/fragment-site/other"
echo '<h3 id="here">here</h3><a href="other/#there">ok</a><a href="#here">ok</a>' > "$tmp/fragment-site/index.html"
echo '<h2 id="there">there</h2>' > "$tmp/fragment-site/other/index.html"
python3 "$check" links "$tmp/fragment-site" >/dev/null || fail "a site whose fragments all resolve was refused"
echo '<a href="other/#missing">gone</a>' >> "$tmp/fragment-site/index.html"
out=$(python3 "$check" links "$tmp/fragment-site" 2>&1) && fail "a fragment the linked page lacks passed"
echo "$out" | grep -q "index.html: other/#missing names no heading or anchor in other/index.html" \
  || fail "wrong finding for a fragment the linked page lacks: $out"

# A bare fragment stays on its own page, so that page's ids are the ones it must name.
mkdir -p "$tmp/bare-fragment-site"
echo '<h2 id="here">here</h2><a href="#nowhere">gone</a>' > "$tmp/bare-fragment-site/index.html"
out=$(python3 "$check" links "$tmp/bare-fragment-site" 2>&1) && fail "a bare fragment its own page lacks passed"
echo "$out" | grep -q "index.html: #nowhere names no heading or anchor in index.html" \
  || fail "wrong finding for a bare fragment its own page lacks: $out"

# A file that is not a page carries no ids, and a binary one would not decode, so the checker skips its fragment.
mkdir -p "$tmp/asset-fragment-site/assets"
printf '\x89PNG\r\n\x1a\n' > "$tmp/asset-fragment-site/assets/a.png"
echo '<h1 id="top">top</h1><a href="assets/a.png#x">ok</a>' > "$tmp/asset-fragment-site/index.html"
out=$(python3 "$check" links "$tmp/asset-fragment-site" 2>&1) \
  || fail "a fragment on a link to a file that is not a page was read: $out"

# The theme writes its skip link as `#__skip` on a page with no heading to point at, so the checker exempts it.
mkdir -p "$tmp/skip-link-site"
echo '<a href="#__skip">skip</a><p>not found</p>' > "$tmp/skip-link-site/404.html"
out=$(python3 "$check" links "$tmp/skip-link-site" 2>&1) || fail "the theme's skip link was refused: $out"

# A lost or misspelled setting brings back the theme's request to Google's font hosts, which hands Google each reader's
# address, and the strict build passes such a page. The first site's link to another host is the side that passes.
mkdir -p "$tmp/font-host-site"
echo '<link rel="stylesheet" href="https://fonts.googleapis.com/css?family=Inter">' > "$tmp/font-host-site/index.html"
out=$(python3 "$check" links "$tmp/font-host-site" 2>&1) && fail "a page that links a font host of Google passed"
echo "$out" | grep -qF "index.html: https://fonts.googleapis.com/css?family=Inter" \
  || fail "wrong finding for a page that links a font host of Google: $out"

# A font file that a style sheet misnames shows the reader a fallback face, and no page's link names that file. A style
# sheet's url() or @import can also load from Google's font hosts with no link to them on a page, and CSS reads URL( as
# it reads url(. The build reads the exit status alone, so each kind of report gets a run in which it is the one
# finding, and a report that prints its line without counting it fails there. The passing run holds the base of the
# read, since a url() read against the site's top refuses it.
mkdir -p "$tmp/style-site/assets/fonts"
: > "$tmp/style-site/index.html"
: > "$tmp/style-site/assets/fonts/a.woff2"
echo '@font-face { font-family: "A"; src: url("fonts/a.woff2") format("woff2"); }' > "$tmp/style-site/assets/site.css"
out=$(python3 "$check" links "$tmp/style-site" 2>&1) || fail "a style sheet whose url() resolves was refused: $out"
echo '@font-face { font-family: "B"; src: url("fonts/b.woff2") format("woff2"); }' >> "$tmp/style-site/assets/site.css"
out=$(python3 "$check" links "$tmp/style-site" 2>&1) && fail "a style sheet that names a missing file passed"
echo "$out" | grep -qF 'assets/site.css: fonts/b.woff2 resolves to nothing' \
  || fail "links did not report the missing file of a style sheet: $out"
{
  echo '@font-face { font-family: "A"; src: url("fonts/a.woff2") format("woff2"); }'
  echo '@font-face { font-family: "C"; src: URL(https://fonts.gstatic.com/s/inter/a.woff2) format("woff2"); }'
  echo '@import "https://fonts.googleapis.com/css?family=Inter";'
} > "$tmp/style-site/assets/site.css"
out=$(python3 "$check" links "$tmp/style-site" 2>&1) && fail "a style sheet that loads from two font hosts passed"
for finding in 'assets/site.css: https://fonts.gstatic.com/s/inter/a.woff2' \
  'assets/site.css: https://fonts.googleapis.com/css?family=Inter'; do
  echo "$out" | grep -qF "$finding" || fail "links did not report $finding: $out"
done

# urlsplit refuses an address with an unclosed `[`, and such a link at another host names no font host, so the skip
# passes it as another host's link. A host test that lets the refusal through ends the link check with a traceback.
mkdir -p "$tmp/malformed-site"
echo '<a href="https://[x">x</a>' > "$tmp/malformed-site/index.html"
out=$(python3 "$check" links "$tmp/malformed-site" 2>&1) || fail "a link to a malformed address was refused: $out"
[ -z "$out" ] || fail "links printed a line for a link to a malformed address: $out"

# The prose rules: each rule fires outside a code span and a fenced block and stays quiet inside them, a fence
# closes only on its own character and length, and a span wrapped across two lines is code on both.
mkdir -p "$tmp/prose"
{
  echo '# A page'
  echo
  echo 'A `code; span`, an `api_key` in a span, a `task` in a span and the shape a client sends all pass.'
  printf '| %s |\n' "$(printf 'x%.0s' $(seq 1 117))"
  echo '<!-- a comment; with a semicolon and a task -->'
  echo
  echo '```sh'
  echo 'echo "a fenced line; with a semicolon, an em-dash — and a task"'
  echo '```'
  echo '````markdown'
  echo '```sh'
  echo 'a line; inside a four-backtick block, with a task'
  echo '```'
  echo '````'
  echo 'A span that wraps `git'
  echo 'worktree list; with a semicolon` and ends.'
} > "$tmp/prose/pass.md"
[ "$(sed -n 4p "$tmp/prose/pass.md" | wc -c)" = 122 ] || fail "the table row case is not 121 columns"
python3 "$check" prose "$tmp/prose/pass.md" >/dev/null || fail "prose refused a page that obeys every rule"
{
  echo 'A prose line; with a semicolon.'
  printf '%s\n' "$(printf 'x%.0s' $(seq 1 121))"
  echo 'An em-dash — here.'
  echo 'An en-dash – here.'
  echo 'An api_key account.'
  echo 'A span that wraps `git'
  echo 'worktree list` and then; a semicolon after the close.'
} > "$tmp/prose/fail.md"
out=$(python3 "$check" prose "$tmp/prose/fail.md" 2>&1) && fail "prose passed a page that breaks the rules"
for finding in 'fail.md:1: semicolon:' 'fail.md:2: columns: 121' 'fail.md:3: dash:' 'fail.md:4: dash:' 'fail.md:5: api_key:' 'fail.md:7: semicolon:'; do
  echo "$out" | grep -q "$finding" || fail "prose did not report $finding: $out"
done
echo "$out" | grep -q 'fail.md:6:' && fail "prose reported the line that opens a wrapped span: $out"
# A word from each of the two vocabulary patterns, a working document's word and a shape letter. The code span that
# exempts such a word is pass.md's `task`.
for word in task 'shape B'; do
  echo "The $word is named here." > "$tmp/prose/word.md"
  out=$(python3 "$check" prose "$tmp/prose/word.md" 2>&1) && fail "prose passed the word $word in prose"
  echo "$out" | grep -q "word.md:1: vocabulary:" || fail "prose did not report $word as vocabulary: $out"
done
# A span left open ends with its paragraph: a blank line or a fence line closes it, so the prose after either is read.
{
  echo 'A span opened here `and never closed'
  echo
  echo 'A prose line after the blank; with a semicolon.'
} > "$tmp/prose/open-span.md"
out=$(python3 "$check" prose "$tmp/prose/open-span.md" 2>&1) && fail "prose passed the semicolon after a span left open before a blank line"
echo "$out" | grep -q 'open-span.md:3: semicolon:' || fail "prose did not report the line after a blank that ends an open span: $out"
{
  echo 'A span opened here `and never closed'
  echo '```sh'
  echo 'echo fenced'
  echo '```'
  echo 'A prose line after the block; with a semicolon.'
} > "$tmp/prose/open-span-fence.md"
out=$(python3 "$check" prose "$tmp/prose/open-span-fence.md" 2>&1) && fail "prose passed the semicolon after a span left open before a fence"
echo "$out" | grep -q 'open-span-fence.md:5: semicolon:' || fail "prose did not report the line after a block that ends an open span: $out"
# A fence line with an info string inside an open block is content, so only a bare fence line closes the block.
{
  echo '```markdown'
  echo '```sh'
  echo 'a line inside the block'
  echo '```'
  echo 'A prose line after the block; with a semicolon.'
} > "$tmp/prose/inner-fence.md"
out=$(python3 "$check" prose "$tmp/prose/inner-fence.md" 2>&1) && fail "prose passed the prose after a block holding a fence line with an info string"
echo "$out" | grep -q 'inner-fence.md:5: semicolon:' || fail "prose did not report the line after the block's bare closing fence: $out"

# A walk that reads a folder's top level alone passes a tree whose product pages, one folder down, all break a rule,
# and a walk that reads below the top alone passes the start page. Both pages here break a rule.
mkdir -p "$tmp/tree/router"
echo 'A top line; with a semicolon.' > "$tmp/tree/index.md"
echo 'A nested line; with a semicolon.' > "$tmp/tree/router/page.md"
out=$(python3 "$check" prose "$tmp/tree" 2>&1) && fail "prose passed a tree whose top page and nested page break a rule"
echo "$out" | grep -q 'router/page.md:1: semicolon:' || fail "prose did not report the page one folder below the top: $out"
echo "$out" | grep -q 'tree/index.md:1: semicolon:' || fail "prose did not report the page at the tree's top: $out"

# A prefix read that expects one path segment refuses each root-relative link of a site whose address has no path,
# such as one on a domain of its own.
mkdir -p "$tmp/bare/scripts" "$tmp/bare-site/installation"
cp "$here/scripts/check-site.py" "$tmp/bare/scripts/"
printf '[project]\nsite_url = "https://docs.example/"\n' > "$tmp/bare/zensical.toml"
: > "$tmp/bare-site/installation/index.html"
echo '<a href="/installation/">ok</a>' > "$tmp/bare-site/index.html"
python3 "$tmp/bare/scripts/check-site.py" links "$tmp/bare-site" >/dev/null \
  || fail "a root-relative link of a site without a path prefix was refused"
echo '<a href="/missing/">gone</a>' >> "$tmp/bare-site/index.html"
out=$(python3 "$tmp/bare/scripts/check-site.py" links "$tmp/bare-site" 2>&1) && fail "a dangling root-relative link passed without a prefix"
echo "$out" | grep -q "index.html: /missing/ resolves to nothing" || fail "wrong finding without a prefix: $out"

echo "check-site: ok"
