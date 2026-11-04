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

`.github/workflows/template.yml` renders every answer set in `tests/template-renders/`
and runs each render's tests and format checks, and builds the example driver in
each. Not to be confused with `template/.github/workflows/`, which renders
*into* driver repos and never runs here.

Each `tests/template-renders/<name>.yml` holds one render's non-default answers, on top
of `tests/template-renders/fixtures.yml`, and `<name>.files` lists the files it renders.
`tests/template_renders.py` checks each render against its list, and checks the content
that depends on the answers: stale.yml's exempt list and days, CONTRIBUTING's
Cloud Monitoring section, build-secret substitution, and the build secrets
build.yml passes by name. Every combination in
`tests/template-renders/invalid/` must fail to render, with the error its `# expect:`
line names.

Every gating defect so far passed a default render and appeared only under a
non-default one, so when you add an `_exclude` entry or a question, add a
render that exercises it and run `make snapshots`: the `.files` diff is what to
review. `make template-renders` runs the snapshot and content checks for every
render locally.

CI runs each leg as one make target, so a leg runs the same locally:
`make render-checks NAME=<name>` is the render leg and `make build-checks
NAME=<name>` the build leg, rendered into a temp folder (`RENDER=` to move it).
Each step is a target of its own, which `make help` lists; the build leg's
checks are `tests/build_checks.py`.

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
vendored libraries, `stale_issues` the stale-issue workflow, and
`cloud_diagnostics` the Cloud Monitoring library and its tests, since a repo
opts in to reporting. There is no other module-to-module gating: every other
`src/lib/*.lua` renders unconditionally, and `gen-squishy` bundles only what a
driver actually requires, so a rendered-but-unused module is zero bytes in the
`.c4z`. A new `src/lib` file needs no `_exclude` entry.

`github-updater.lua` and its tests are gated on `oss`, the distribution whose
update mechanism they are.

`_skip_if_exists` holds `CHANGELOG.md`, `src/constants.lua`, `.env.default`,
`resources/Driver Icons.sketch` and `resources/drivercentral/**`, so existing repos
never receive changes to them; only newly created ones do, and a repo gets any of
them it lacks. This is why the template can seed `src/constants.lua`
(with the property-visibility keys its lib requires) and `.env.default` (with the
build secrets it passes) without clobbering what a driver has since added. A repo
without `resources/Driver Icons.sketch` gets the template's on its next `copier
update`, even when it keeps its own icons under another name.

## Jinja

**Only `.jinja` files have their contents rendered**, with the suffix stripped on
the way out — currently `Makefile`, `CONTRIBUTING.md`, `CHANGELOG.md`,
`.env.default`, the build and stale workflows, `tools/github-setup`, the
DriverCentral marketing pages under `resources/drivercentral/`, and the
answers file. Everything else
is copied byte for byte, so `{{` in a `.lua` or `.py` file passes straight
through and is not a template error. In `tools/github-setup.jinja` a bash
`${#var}` would open a Jinja comment.
The corollary is the one that bites: adding `{{ project_name }}` to a file that
is not named `.jinja` silently ships the literal braces to ten repos.

File *paths* are templated regardless of suffix, which is how
`template/{{ _copier_conf.answers_file }}.jinja` becomes each repo's
`.copier-answers.yml`. That file is Copier's own bookkeeping; do not hand-edit its
output in driver repos.

`jinja2.ext.do` is enabled.
