#!/usr/bin/env bash
# The selection has to hand each build the commit of a product's newest run that a push to main started, that ended
# green and whose commit main still holds, with each test read from the run and the comparison themselves. A deploy has
# to wait for a run in progress and to stop with an empty standard output where a product has no green run, while each
# other build reads such a product at main. A failed read stops each build. The script reads the API through gh and
# finds its repository from its own path, so each case runs a copy of it in a throwaway repository with a gh of the
# case's own first on the PATH.
set -euo pipefail

here=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $1" >&2; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo/scripts" "$tmp/bin"
cp "$here/scripts/green-commits.py" "$here/scripts/assemble.py" "$repo/scripts/"
printf '[[source]]\nfolder = "alpha"\nrepository = "example/alpha"\ntitle = "Alpha"\n\n' > "$repo/sources.toml"
printf '[[source]]\nfolder = "beta"\nrepository = "example/beta"\ntitle = "Beta"\n' >> "$repo/sources.toml"

# The case's gh answers a path with the answers the case wrote for it, in their order and with the last one again for
# each further call. A call of another form ends with exit 2 and a path without an answer with exit 1, each with a line
# that gh also records. A script that stops on such an answer can still end as the case expects, so each case fails on a
# record, and a script that calls gh another way or reads a path the case did not expect fails the case.
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
refuse() { echo "$2" >> "$(dirname "$0")/../refused"; echo "$2" >&2; exit "$1"; }
if [ "$#" != 4 ] || [ "$1" != api ] || [ "$2" != --method ] || [ "$3" != GET ]; then
  refuse 2 "the case's gh takes api --method GET <path> alone, not: $*"
fi
dir="$(dirname "$0")/../answers/$(printf '%s' "$4" | sha256sum | cut -d ' ' -f 1)"
[ -d "$dir" ] || refuse 1 "the case wrote no answer for $4"
call=$(( $(cat "$dir/calls") + 1 ))
echo "$call" > "$dir/calls"
[ -e "$dir/$call.exit" ] || call=$(cat "$dir/count")
cat "$dir/$call.body"
cat "$dir/$call.err" >&2
exit "$(cat "$dir/$call.exit")"
GH
chmod +x "$tmp/bin/gh"

# Appends an answer for a path: the exit status of gh, its line on the error output, which a success leaves empty, and
# the body on its standard output.
answer() {
  local dir n
  dir="$tmp/answers/$(printf '%s' "$1" | sha256sum | cut -d ' ' -f 1)"
  mkdir -p "$dir"
  [ -e "$dir/count" ] || { echo 0 > "$dir/count"; echo 0 > "$dir/calls"; }
  n=$(( $(cat "$dir/count") + 1 ))
  echo "$n" > "$dir/count"
  echo "$2" > "$dir/$n.exit"
  if [ -n "$3" ]; then printf '%s\n' "$3"; fi > "$dir/$n.err"
  printf '%s\n' "$4" > "$dir/$n.body"
}
runs_path() { echo "repos/$1/actions/workflows/docs.yml/runs?branch=main&event=push&per_page=100"; }
compare_path() { echo "repos/$1/compare/$2...main?per_page=1"; }
# A run with the fields the selection reads: its id, its event, its branch, its commit and, once complete, its
# conclusion.
ended() {
  printf '{"id":%s,"event":"%s","head_branch":"%s","head_sha":"%s","status":"completed","conclusion":"%s"}' "$@"
}
running() {
  printf '{"id":%s,"event":"push","head_branch":"main","head_sha":"%s","status":"in_progress","conclusion":null}' "$@"
}
# The runs of a product's docs.yml, the newest first, as one answer to a read of them.
runs() {
  local path list
  path=$(runs_path "$1")
  shift
  list=$(IFS=,; echo "$*")
  answer "$path" 0 "" "{\"total_count\":$#,\"workflow_runs\":[$list]}"
}
compared() { answer "$(compare_path "$1" "$2")" 0 "" "{\"status\":\"$3\"}"; }
# A refusal as gh gives it: exit 1, the body of GitHub's answer on the standard output and gh's own line with the status
# on the error output.
refused() {
  answer "$1" 1 "gh: $3 (HTTP $2)" \
    "{\"message\":\"$3\",\"documentation_url\":\"https://docs.github.com/rest\",\"status\":\"$2\"}"
}
# The product beside the one a case is about: one complete green run of a push to main on the head of main.
one_green() { runs "$1" "$(ended "$2" push main "$3" success)"; compared "$1" "$3" identical; }

# Each case starts from no answer and no refused call, so nothing of an earlier case can satisfy it or fail it.
fresh() { name=$1; rm -rf "$tmp/answers" "$tmp/refused"; mkdir -p "$tmp/answers"; }
pick() {
  status=0
  out=$(PATH="$tmp/bin:$PATH" python3 "$repo/scripts/green-commits.py" "$@" 2> "$tmp/err") || status=$?
  err=$(cat "$tmp/err")
}
ends() {
  [ "$status" = "$1" ] || fail "$name: exit $status, where $1 was due: $err"
  [ "$out" = "$2" ] || fail "$name: the standard output was '$out', where '$2' was due"
  [ ! -e "$tmp/refused" ] || fail "$name: the case's gh refused a call: $(cat "$tmp/refused")"
}
# Each value has to stand as a word of its own, so an id does not match inside a longer number.
logged() {
  local lines=$err value
  for value in "$@"; do
    lines=$(grep -wF -- "$value" <<< "$lines") || fail "$name: no line of the error output holds $*: $err"
  done
}

# A commit is 40 hex digits. The digit of c1 to c4 is the run's place in the case, the newest first, and ca and cb are
# the commits of the one green run of alpha and of beta.
c1=1111111111111111111111111111111111111111
c2=2222222222222222222222222222222222222222
c3=3333333333333333333333333333333333333333
c4=4444444444444444444444444444444444444444
ca=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cb=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# A selection that takes the newest run's commit whatever its result builds a commit that failed its own checks, and the
# build passes on it, since those checks run in the product's own workflow alone. The newest run was cancelled, so a
# test that passes over a failure alone takes it. main holds each of the three commits, so the test of the conclusion
# alone stands between the two red runs and the build.
fresh "a red newest run"
runs example/alpha "$(ended 101 push main "$c1" cancelled)" "$(ended 102 push main "$c2" failure)" \
  "$(ended 103 push main "$c3" success)"
compared example/alpha "$c1" identical
compared example/alpha "$c2" ahead
compared example/alpha "$c3" ahead
one_green example/beta 201 "$cb"
pick
ends 0 "alpha=$c3
beta=$cb"

# The API drops a query parameter it does not know, so a mistyped query hands back a pull request's run, and a selection
# that trusts the filter builds a commit that no one merged. Above the push to main stand a pull request's green run on
# a branch named main and a green push to another branch, and main holds both commits, so the test of the event and the
# branch alone passes them over.
fresh "a green run that is no push to main"
runs example/alpha "$(ended 101 pull_request main "$c1" success)" "$(ended 102 push feature "$c2" success)" \
  "$(ended 103 push main "$c3" success)"
compared example/alpha "$c1" ahead
compared example/alpha "$c2" ahead
compared example/alpha "$c3" identical
one_green example/beta 201 "$cb"
pick
ends 0 "alpha=$c3
beta=$cb"

# The list of runs keeps the runs of commits that a rewrite of main dropped, and GitHub still hands such a commit to a
# checkout. Three green commits that main does not hold stand above one it holds: one the repository no longer has,
# whose comparison answers 404 as gh gives it, one behind main and one that diverged from it. A 404 read as a failed
# read would stop each build of each product for one lost commit.
fresh "a green run on a commit that main dropped"
runs example/alpha "$(ended 101 push main "$c1" success)" "$(ended 102 push main "$c2" success)" \
  "$(ended 103 push main "$c3" success)" "$(ended 104 push main "$c4" success)"
refused "$(compare_path example/alpha "$c1")" 404 "Not Found"
compared example/alpha "$c2" behind
compared example/alpha "$c3" diverged
compared example/alpha "$c4" ahead
one_green example/beta 201 "$cb"
pick
ends 0 "alpha=$c4
beta=$cb"
# The read of the runs has passed, so the token reaches the repository, and a refused comparison is a missing
# permission. A script that reads each refusal as a dropped commit passes over each green run without a word of it.
fresh "a green run on a commit that main dropped, with 403 in the place of the 404"
runs example/alpha "$(ended 101 push main "$c1" success)" "$(ended 102 push main "$c2" success)" \
  "$(ended 103 push main "$c3" success)" "$(ended 104 push main "$c4" success)"
refused "$(compare_path example/alpha "$c1")" 403 "Resource not accessible by integration"
compared example/alpha "$c2" behind
compared example/alpha "$c3" diverged
compared example/alpha "$c4" ahead
one_green example/beta 201 "$cb"
pick
ends 1 ""
logged example/alpha "HTTP 403"

# A deploy that falls back to main or to the newest run publishes a commit that no check passed. A stop prints no
# assignment, and alpha comes first with its green head, so a script that prints each assignment as it finds it puts
# alpha's line in front of the stop.
fresh "a product without a green run in a deploy"
one_green example/alpha 101 "$ca"
runs example/beta "$(ended 201 push main "$c1" failure)" "$(ended 202 push main "$c2" cancelled)"
pick
ends 1 ""
logged example/beta

# After a rewrite of two main branches neither product has a green run on main, and a stop in a build that publishes
# nothing would leave each product's run stopping on the other's, so neither could end green again. The runs are those
# of the deploy's case above.
fresh "a product without a green run in a build that publishes nothing"
one_green example/alpha 101 "$ca"
runs example/beta "$(ended 201 push main "$c1" failure)" "$(ended 202 push main "$c2" cancelled)"
pick --or-main
ends 0 "alpha=$ca
beta=main"
logged example/beta

# A refused read stops each build, with --or-main too. A script that reads the refusal's body as a list of no runs, or
# the missing list as an empty one, builds each product at main in each product's run, green and without a word of the
# fault.
fresh "a refused read"
refused "$(runs_path example/alpha)" 403 "Resource not accessible by integration"
one_green example/beta 201 "$cb"
pick --or-main
ends 1 ""
logged example/alpha "HTTP 403"
fresh "a refused read, with exit 0 and no list of runs"
answer "$(runs_path example/alpha)" 0 "" '{"total_count":0}'
one_green example/beta 201 "$cb"
pick --or-main
ends 1 ""
logged example/alpha

# A product's run builds its own product at the pushed commit, whose run is the one in progress that is building. A
# selection for it reads the commit below, so the run passes without its own change.
fresh "the caller's own commit"
runs example/alpha "$(running 101 "$c1")" "$(ended 102 push main "$c2" success)"
compared example/alpha "$c2" ahead
one_green example/beta 201 "$cb"
pick --own "alpha=$c1"
ends 0 "alpha=$c1
beta=$cb"

# Right after a push the newest run is still in progress, and a selection that reads once and counts that run as red
# publishes the commit before the pushed one, which no later deploy follows. The run ends green at the second read, so
# this is also the case whose result is the newest run, which a selection that passes over each newest run misses.
fresh "a run in progress that ends green within the wait"
runs example/alpha "$(running 101 "$c1")" "$(ended 102 push main "$c2" success)"
runs example/alpha "$(ended 101 push main "$c1" success)" "$(ended 102 push main "$c2" success)"
compared example/alpha "$c1" identical
compared example/alpha "$c2" ahead
one_green example/beta 201 "$cb"
pick --wait 2 --every 1
ends 0 "alpha=$c1
beta=$cb"

# A script that stops at the end of the wait lets one stuck run hold back the two other products, and each product's
# run, which waits for no run, would turn red while another product's run is in progress. The run it passes over has to
# show in the log. The wait has to end where its two arguments put the end, after two reads here. The run ends green at
# a third read, so a script that does not count the seconds it slept, or that sleeps once more at the end, prints the
# newest run's commit. Without the count a deploy beside a stuck run reads until the job's time is over.
fresh "a run still in progress at the end of the wait"
runs example/alpha "$(running 101 "$c1")" "$(ended 102 push main "$c2" success)"
runs example/alpha "$(running 101 "$c1")" "$(ended 102 push main "$c2" success)"
runs example/alpha "$(ended 101 push main "$c1" success)" "$(ended 102 push main "$c2" success)"
compared example/alpha "$c1" identical
compared example/alpha "$c2" ahead
one_green example/beta 201 "$cb"
pick --wait 1 --every 1
ends 0 "alpha=$c2
beta=$cb"
logged 101

# A script that keeps a comparison's answer for its whole run reads no rewrite of main that falls into the wait, so it
# can build a commit that main dropped in that time. Each script compares the newest green commit in both rounds, so
# that commit turns from diverged at the first read to held at the second, and the run in progress below it keeps the
# product waiting for that second read.
fresh "a comparison that changes during the wait"
runs example/alpha "$(ended 101 push main "$c1" success)" "$(running 102 "$c2")" "$(ended 103 push main "$c3" success)"
compared example/alpha "$c1" diverged
compared example/alpha "$c1" ahead
compared example/alpha "$c3" ahead
one_green example/beta 201 "$cb"
pick --wait 1 --every 1
ends 0 "alpha=$c1
beta=$cb"

# --every 0 reads without a pause, and without an end while a run is in progress. The case writes no answer, so a script
# that takes the value and reads fails by its exit status.
fresh "a refused value of the interval"
pick --wait 30 --every 0
ends 2 ""

echo "green-commits: ok"
