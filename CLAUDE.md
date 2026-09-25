# control4-driver-template

The Copier template every Control4 driver repo is cut from. Editing `template/`
is editing every driver at once.

## This is not a driver repo

Driver conventions — repo structure, Lua style, LuaDoc, polling, auto-update,
distribution, proxy conformance, state reconciliation, auth — are owned by the
**`review-driver` skill** (`finitelabs/claude-skills`), across sixteen dimensions
and its `references/*.md`. Those are ground truth. Do not re-derive them here and
do not restate them in this file.

The skill does not apply *to this repo*: its preflight requires
`.copier-answers.yml` and a `*.c4zproj`, and this repo has neither. So it will
stop rather than review, and nothing it knows covers the template mechanics
below. That is what this file is for.

## CI renders the template rather than running it

`.github/workflows/template.yml` renders several answer sets and runs each
render's tests and format checks. Not to be confused with
`template/.github/workflows/`, which renders *into* driver repos and never runs
here.

Every gating defect so far passed a default render and appeared only under a
non-default one, so when you add an `_exclude` entry, add the leg that exercises
it — and check that leg is distinct with `diff -r`.

## Rendering, and the default that lies

```bash
copier copy --trust --defaults --vcs-ref HEAD \
  --data project_name=control4-probe \
  --data github_org=finitelabs \
  --data readme_driver_slug=probe \
  . /tmp/render
```

Two things about that command are not optional:

- **`--vcs-ref HEAD` or you test the wrong tree.** Copier renders from the latest
  **tag** by default, not from your checkout. Omit the flag today and you render
  v0.9.14 while HEAD is three commits ahead — the render succeeds and tells you
  nothing about your change. `HEAD` is special-cased to mean the working tree, so
  it picks up uncommitted edits too.
- **`--defaults` alone is not enough.** `project_name`, `github_org` and
  `readme_driver_slug` have no defaults and Copier hard-fails on the first one it
  reaches. The other six answer themselves.

To reproduce a *specific* repo rather than a generic one, feed it that repo's own
answers: take its `.copier-answers.yml`, drop the `_`-prefixed keys, and pass it
with `--data-file`. Rendering the old and new refs with the same answers and
diffing the two trees is what turns "this looks right" into evidence.

## Merging propagates nothing

A merged PR reaches zero drivers. The sequence is **merge → tag → `copier update`
per repo**, and each of those is a separate step someone has to do.

Ten repos carry `.copier-answers.yml`. Enumerate them live rather than trusting a
list — the count has been wrong before, and a stale local clone is not evidence:

```bash
gh api repos/finitelabs/<repo>/contents/.copier-answers.yml \
  --jq .content | base64 -d | grep ^_commit
```

against `git tag --sort=-v:refname | head -1` tells you which repos are behind.
A template ticket is not done at merge; it is done when the drift is closed.

## `_exclude` gates files on answers

`copier.yml`'s `_exclude` list drops files the answers did not select —
`distributions` controls OSS versus DriverCentral, `vendor_modules` the optional
vendored libraries. There is no module-to-module gating: every `src/lib/*.lua`
renders unconditionally, and `gen-squishy` bundles only what a driver actually
requires, so a rendered-but-unused module is zero bytes in the `.c4z`. A new
`src/lib` file needs no `_exclude` entry.

`github-updater.lua` and its alias test are gated on `oss`, the distribution
whose update mechanism they are.

`_skip_if_exists` holds `CHANGELOG.md` and `src/constants.lua`, so existing repos
never receive changes to them — only newly created ones do. This is why the
template can seed `src/constants.lua` (with the property-visibility keys its lib
requires) without clobbering the constants a driver has since added.

## Jinja

**Only `.jinja` files have their contents rendered**, with the suffix stripped on
the way out — currently `Makefile`, `CONTRIBUTING.md`, `CHANGELOG.md`, the build
workflow, and the answers file. Everything else is copied byte for byte, so `{{`
in a `.lua` or `.py` file passes straight through and is not a template error.
The corollary is the one that bites: adding `{{ project_name }}` to a file that
is not named `.jinja` silently ships the literal braces to ten repos.

File *paths* are templated regardless of suffix, which is how
`template/{{ _copier_conf.answers_file }}.jinja` becomes each repo's
`.copier-answers.yml`. That file is Copier's own bookkeeping; do not hand-edit its
output in driver repos.

`jinja2.ext.do` is enabled.
