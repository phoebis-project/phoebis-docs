# Phoebis documentation

This repository builds the one documentation site of Phoebis Router, Phoebis Companion and Phoebis Proxy. It holds the
site's configuration, its scripts, its start page, its theme and its workflows. The pages of a product stay in that
product's repository, and each build copies them into one tree. The site is published at
<https://phoebis-project.github.io/phoebis-docs/>.

## What a product repository holds

| Path | Content |
| --- | --- |
| `.github/workflows/docs.yml` | the workflow that calls this repository's build |
| `docs/nav.toml` | the navigation of the product's pages |
| `docs/site/` | the pages and their images, with `index.md` as the part's first page |

`docs/nav.toml` holds one key, `nav`, an array of pages and sections in the shape of Zensical's `nav`, with each path
relative to `docs/site/`:

```toml
nav = [
  { "Overview" = "index.md" },
  { "Guides" = [
    { "Install" = "install.md" },
  ] },
]
```

A page that is added, renamed or removed changes `docs/nav.toml` in the same pull request. `sources.toml` in this
repository names each product with its folder, its repository and the title of its tab, in the order of the tabs.

`scripts/assemble.py` takes one checkout per product and writes the build tree, `build/`, which git ignores: this
repository's `docs/` and `overrides/`, each product's `docs/site/` under the product's folder, and `zensical.toml` with
the merged navigation. It removes from the tree what its sources no longer hold, so it leaves the file
`.phoebis-docs-build` at the tree's top and writes into a directory that does not exist, that is empty or that holds
that file, and into no other. It writes nothing, removes nothing and prints one line per problem where:

- a `--checkout` flag names a folder that `sources.toml` does not hold
- a folder of `sources.toml` has no checkout
- a nav path leaves the product's folder
- a page of this repository's own `docs/` is not the start page, the one entry of the site's own nav
- a page under `docs/site/` has no entry in the product's nav
- a product has no `docs/site/index.md` or no `docs/nav.toml`
- a product's `docs/`, `docs/nav.toml` or `docs/site/`, this repository's `docs/` or `overrides/`, or a path under a
  tree it copies is a symbolic link
- a product's `docs/nav.toml` does not read as a nav of the shape above
- a product's folder is taken by a path of this repository's own `docs/`
- the output directory holds a file and is no tree the script wrote
- `zensical.toml` holds no `[project]` line

## The preview

A local run needs Python 3.11 or later and `pipx`, which runs the pinned version of Zensical. One command assembles the
tree from local checkouts of the three products and serves it:

```sh
python3 scripts/preview.py --checkout router=../phoebis --checkout companion=../phoebis-companion --checkout proxy=../phoebis-proxy
```

A local directory can have another name than its repository, so each path comes from its flag or from `checkouts.toml`
at this repository's root, which git ignores and which the preview reads once, at its start. A flag wins over the file,
and a relative path in the file is read from the file's folder:

```toml
companion = "../phoebis-companion"
proxy = "../phoebis-proxy"
router = "../phoebis"
```

The command runs `zensical serve` in the build tree and hands it each argument behind `--`. While it serves, it looks at
the sources once a second and assembles again when a file changed, so an edit of a page in a product's checkout shows in
the browser without a commit. A change the assembly refuses prints its lines and leaves the served tree as it was.

The build that a pull request gets is the strict one, with the two checks behind it:

```sh
python3 scripts/assemble.py --checkout router=../phoebis --checkout companion=../phoebis-companion --checkout proxy=../phoebis-proxy
(cd build && pipx run zensical==0.0.62 build --clean --strict)
python3 scripts/check-site.py links
python3 scripts/check-site.py prose build/docs README.md ../phoebis/README.md ../phoebis-companion/README.md ../phoebis-proxy/README.md
```

`links` walks the built site for an internal link or an image that resolves to nothing and for a fragment that names no
heading or anchor on the page it lands on. `prose` holds each page of the build tree and the four READMEs to the site's
writing rules, which apply to the pages of each product: no bare `api_key` outside a code span, no em-dash and no
en-dash, no line over 120 columns outside a table or a fenced code block, no semicolon on a prose line, and no word from
its list of words a reference page does not use. With a path, `prose` reads that file or walks that folder.

A second build tree, such as one for a strict build while the preview serves `build/`, comes from two arguments:
`scripts/assemble.py --out DIR` writes into that directory under the same rule as `build/`, and `scripts/check-site.py
links DIR/site` reads the site built there.

## The commits a build reads

Each build reads this repository at `main`, the caller's product at the caller's commit, and each other product at its
newest commit on `main` whose `Documentation` run ended green. A pull request of this repository reads its own commit
and each product that way. So a product's commit whose `Documentation` run failed is not published. No other build reads
it either, with one exception: a product with no green run, the second case below. `scripts/green-commits.py` picks the
commits, as a step of `build.yml`:

```sh
python3 scripts/green-commits.py
```

The command changes nothing and prints one `folder=commit` line per product. It needs the GitHub CLI, signed in as an
account that reads the Actions and the contents of each repository of `sources.toml`. For each product it reads the 100
newest runs of `.github/workflows/docs.yml` that a push to `main` started, and it takes the commit of the newest run
that is complete with the conclusion `success` and whose commit `main` still holds. It passes over a run that was
cancelled, that failed, that was skipped or that timed out, a run that is queued or in progress, and a green run on a
commit that `main` no longer holds. That is a commit that a rewrite of `main` dropped, and one that the repository no
longer has, for which the comparison answers 404. A run that was started again counts with the result of its last
attempt. The file name `docs.yml` and the branch `main` are therefore part of the contract between the repositories.

With `--own FOLDER=COMMIT` the command prints that product at that commit and reads none of its runs. A product's
workflow hands over its own commit this way, through the inputs `product` and `ref` of `build.yml`.

The `Deploy` workflow differs from each other build in two cases:

- A run that is queued or in progress. The deploy calls the script with `--wait 300 --every 10`, so the script reads
  again every 10 seconds until it has slept 300 seconds. The time of its reads comes on top. A product's push starts the
  deploy from the last job of its own `Documentation` run, which is seconds from its end at that moment. When the time
  is over, the script takes the newest green commit below that run and prints a notice that names the product's newest
  run. A run that was passed over starts a deploy of its own once it ends green. The run that started this deploy does
  not, so its commit then waits for the next start of a deploy. Each other build waits for no run.
- A product with no green run on `main` among its 100 newest. The deploy stops, and the site keeps its last state. Each
  other build calls the script with `--or-main`, reads that product at `main` and prints a notice. Such a build
  publishes nothing, and two products without a green run could otherwise never get one.

A build also stops where a read fails and where the workflow gets no token for it. A failed read prints the repository
and the path, and GitHub's status and message where GitHub answered. `HTTP 403` with `Resource not accessible by
integration` says that the token lacks read access to Actions or to contents, and `HTTP 404` that the token does not
reach the repository or that the repository holds no `docs.yml`. The workflow gets no token where the GitHub App behind
`DOCS_APP_CLIENT_ID` has lost one of the two permissions.

A run that failed for a reason outside its commit stays red until someone starts it again. That is the case for a commit
that links to a page which another product's newest green commit does not hold yet: once that product's run is green,
start the failed run again, and its last job starts the deploy.

## Links between products

A page links to a page of another product with a relative path through the built tree, such as
`../router/keepalive.md#the-ceilings` from a page of the companion. The strict build checks the page and the anchor, and
a failure names the linking file with its product's folder. In GitHub's own view of a Markdown file such a link leads
nowhere, so each product's README points at the site.

The three folder names, `companion`, `proxy` and `router`, are therefore a contract between the repositories, and so is
each page and each anchor that another product links to. The site's mark and favicon belong to the same contract: they
are the router's files `docs/site/assets/favicon.svg`, `docs/site/assets/phoebis-router-light.svg` and
`docs/site/assets/phoebis-router.svg`, which `zensical.toml` and `overrides/partials/logo.html` name under
`router/assets/`. A change to such a target stays green in one repository at a time under two rules:

- A heading that another product links to keeps its anchor when its text changes, through an explicit id on the heading,
  as in `## The limits of warming { #the-ceilings }`.
- A page or an anchor that is renamed or removed goes in three steps: the new target beside the old one, then the links
  in the other repository, then the removal of the old one.

Each step waits for the green `Documentation` run of the step before it, since a build reads the other products at their
newest green commits.

## License

Released under the MIT license. See [`LICENSE`](LICENSE) for the full text.
