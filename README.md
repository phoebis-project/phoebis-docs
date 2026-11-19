# Phoebis documentation

This repository builds the one documentation site of Phoebis Router, Phoebis Companion and Phoebis Proxy. It holds the
site's configuration, its scripts, its start page, its theme and its workflows. The pages of a product stay in that
product's repository, and each build copies them into one tree. The site is published at
<https://phoebis-project.github.io/phoebis-docs/> once GitHub Pages is enabled for this repository.

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

## License

Released under the MIT license. See [`LICENSE`](LICENSE) for the full text.
