#!/usr/bin/env python3
"""Prints the commit at which a build reads each product: its newest commit on main whose docs.yml run ended green.

A product's commit is that of its newest run that a push to main started, that is complete with the conclusion `success`
and whose commit main still holds. The script tests the event and the branch of each run itself, since the API drops a
query parameter it does not know, and it compares each green commit with main, since the list of runs keeps the runs of
commits that a rewrite of main dropped. Each read is one call of `gh api`, which holds the API's address and the token.

`--own FOLDER=COMMIT` hands the caller's product through at its own commit, and the script reads none of its runs. With
`--wait`, the script reads a product again every `--every` seconds while a run in progress stands above its newest green
run, until it has slept `--wait` seconds in all, and then passes over that run with a notice. A product without a green
run stops the script, or reads main with `--or-main`. A failed read stops it either way.

On success the script prints one `folder=commit` line per product to its standard output, in the order of sources.toml
and all at once, and exits 0. A stop prints none of them and exits 1. Each other line goes to the error output, which is
the log of a workflow's job.
"""
import argparse
import json
import subprocess
import sys
import time

from assemble import ROOT, read_sources

USAGE = "green-commits.py [--own FOLDER=COMMIT] [--or-main] [--wait SECONDS] [--every SECONDS]"
WORKFLOW = "docs.yml"
BRANCH = "main"
# One page of runs. A product whose newest runs on that page hold no green one has no green run in reach.
REACH = 100
# A run that lacks one of these is an answer the script cannot read, which stops the build as a failed read does.
FIELDS = {"conclusion", "event", "head_branch", "head_sha", "id", "status"}
# The comparison's answers for a commit at main's head or below it.
HELD = ("ahead", "identical")


class Stop(Exception):
    """A stop of the build, with its one line."""


def gh(path: str) -> tuple[int, object]:
    """One GET of the API, as gh's exit status and the body read as JSON, or None for a body that does not read.

    gh writes the body of a refused read to its standard output too, which carries GitHub's status and message. Its
    error output stays the script's own, so the line of gh reaches the log as gh writes it.
    """
    done = subprocess.run(["gh", "api", "--method", "GET", path], stdout=subprocess.PIPE)
    try:
        return done.returncode, json.loads(done.stdout)
    except ValueError:
        return done.returncode, None


def unreadable(repository: str, path: str, code: int) -> Stop:
    return Stop(f"::error::{repository}: GET {path} gave no answer the script can read (gh exit {code})")


def failed(repository: str, path: str, code: int, body: object) -> Stop:
    """The stop for a read that gh ended with another exit status than 0. The status and the message come from the body
    of GitHub's answer, and a read that brought no such body, as after a lost connection, gets the line of an answer the
    script cannot read."""
    if isinstance(body, dict) and "status" in body and "message" in body:
        return Stop(f"::error::{repository}: GET {path} failed with HTTP {body['status']}: {body['message']}")
    return unreadable(repository, path, code)


def read_runs(repository: str) -> list[dict]:
    """The newest runs of the product's workflow that a push to main started, the newest first."""
    path = f"repos/{repository}/actions/workflows/{WORKFLOW}/runs?branch={BRANCH}&event=push&per_page={REACH}"
    code, body = gh(path)
    if code != 0:
        raise failed(repository, path, code, body)
    runs = body.get("workflow_runs") if isinstance(body, dict) else None
    if not isinstance(runs, list) or not all(isinstance(run, dict) and FIELDS <= run.keys() for run in runs):
        raise unreadable(repository, path, code)
    return runs


def held(repository: str, commit: str) -> bool:
    """Whether main holds the commit."""
    path = f"repos/{repository}/compare/{commit}...{BRANCH}?per_page=1"
    code, body = gh(path)
    if code != 0:
        # The read of this repository's runs has passed, so the token reaches the repository, and a missing permission
        # answers 403. A 404 names a commit that the repository no longer holds, so main does not hold it either, and a
        # stop on it would hold back each build of each product for one lost commit.
        if isinstance(body, dict) and str(body.get("status")) == "404":
            return False
        raise failed(repository, path, code, body)
    status = body.get("status") if isinstance(body, dict) else None
    if not isinstance(status, str):
        raise unreadable(repository, path, code)
    return status in HELD


def weigh(repository: str, runs: list[dict]) -> tuple[dict | None, dict | None, dict | None]:
    """The newest run that a push to main started, the newest run in progress above the green run, and the newest run
    that passes the four tests, each None where the runs hold none. The tests run in their order, so a commit is
    compared with main for a complete green run alone."""
    newest = running = None
    # An answer holds for this round of reads alone, so a rewrite of main during the wait shows in the next round.
    holds: dict[str, bool] = {}
    for run in runs:
        if run["event"] != "push" or run["head_branch"] != BRANCH:
            continue
        if newest is None:
            newest = run
        if run["status"] != "completed":
            if running is None:
                running = run
        elif run["conclusion"] == "success":
            commit = run["head_sha"]
            if commit not in holds:
                holds[commit] = held(repository, commit)
            if holds[commit]:
                return newest, running, run
    return newest, running, None


def passed_over(run: dict, slept: int) -> str:
    """Why the build reads another commit than that of a product's newest run."""
    if run["status"] != "completed":
        return f"is still {run['status']} after {slept} seconds"
    if run["conclusion"] != "success":
        return f"ended in {run['conclusion']}"
    return "is green on a commit that main no longer holds"


def say(line: str) -> None:
    # The lines of gh go to the same log between two of these, so each one has to be written before the next read.
    print(line, file=sys.stderr, flush=True)


def settle(
    folder: str, repository: str, runs: list[dict], newest: dict | None, green: dict | None, slept: int, or_main: bool
) -> str:
    """The commit the build reads for a product that waits no longer."""
    if green is None:
        among = f"no green run of {WORKFLOW} on {BRANCH} among the {len(runs)} newest"
        if not or_main:
            raise Stop(f"::error::{repository}: {among}, so the deploy stops")
        say(f"::notice::{repository}: {among}, so the build reads {BRANCH}")
        return BRANCH
    commit = green["head_sha"]
    say(f"{folder}: {commit}, run {green['id']}")
    if newest is not green:
        say(f"::notice::{repository}: run {newest['id']} {passed_over(newest, slept)}, so the build reads {commit} of"
            f" run {green['id']}")
    return commit


def own_pair(value: str) -> tuple[str, str]:
    """A `FOLDER=COMMIT` argument as its two halves. argparse reports any other value as a usage error."""
    folder, sep, commit = value.partition("=")
    if not sep or not folder or not commit:
        raise argparse.ArgumentTypeError(f"{value!r} is no FOLDER=COMMIT")
    return folder, commit


def seconds(least: int):
    """A parser type for a whole number of seconds of `least` or more. With a pause of 0 between two reads, a run in
    progress would keep the script reading without an end."""

    def parse(value: str) -> int:
        try:
            number = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError(f"{value!r} is no whole number") from None
        if number < least:
            raise argparse.ArgumentTypeError(f"{number} is below {least}")
        return number

    return parse


def main(argv: list[str]) -> int:
    # `python -OO` strips the docstring, and the help then goes without a description.
    parser = argparse.ArgumentParser(
        prog="green-commits.py", usage=USAGE, description=__doc__.splitlines()[0] if __doc__ else None
    )
    parser.add_argument(
        "--own", type=own_pair, metavar="FOLDER=COMMIT", help="the caller's product, read at its own commit"
    )
    parser.add_argument(
        "--or-main", action="store_true", help="read a product without a green run at main, where the script stops"
    )
    parser.add_argument(
        "--wait",
        type=seconds(0),
        default=0,
        metavar="SECONDS",
        help="the seconds to sleep in all while a run is in progress, 0 by default",
    )
    parser.add_argument(
        "--every",
        type=seconds(1),
        default=10,
        metavar="SECONDS",
        help="the seconds between two reads of a product that waits, 10 by default",
    )
    args = parser.parse_args(argv)
    sources = read_sources(ROOT)
    if args.own and args.own[0] not in {source.folder for source in sources}:
        parser.error(f"--own: sources.toml names no folder {args.own[0]}")
    commits = {}
    pending = []
    for source in sources:
        if args.own and source.folder == args.own[0]:
            commits[source.folder] = args.own[1]
            say(f"{source.folder}: {args.own[1]}, the caller's commit")
        else:
            pending.append(source)
    slept = 0
    try:
        while pending:
            waiting = []
            for source in pending:
                runs = read_runs(source.repository)
                newest, running, green = weigh(source.repository, runs)
                if running is not None and slept < args.wait:
                    waiting.append(source)
                    continue
                commits[source.folder] = settle(
                    source.folder, source.repository, runs, newest, green, slept, args.or_main
                )
            pending = waiting
            if pending:
                time.sleep(args.every)
                slept += args.every
    except Stop as stop:
        say(str(stop))
        return 1
    sys.stdout.write("".join(f"{source.folder}={commits[source.folder]}\n" for source in sources))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
