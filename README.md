# control4-driver-template

[Copier](https://copier.readthedocs.io/) template for Control4 driver projects. Contains shared
infrastructure, build tooling, and common Lua libraries used across all Finite Labs drivers.

The toolchain is Python + a few standalone binaries, with **no Node/npm**. `make init` creates a local
`.venv` from `requirements.txt` with everything the build needs (docs, formatters, and the driver
packager's crypto/XML libs), and re-installs whenever that list changes.

## What's Included

### Build Tooling (`tools/`)
- **preprocess.py**: C preprocessor-style `#ifdef`/`#ifndef` for Lua, XML, and Markdown. Supports
  variant expansion for generating multiple driver configurations from a single source.
  Also substitutes build secrets: `__NAME__` placeholders for the names `.env.default` declares, from
  the environment, a gitignored `.env` or the macOS Keychain. `--check-secrets`, run by `make check`, checks
  the Build workflow passes each of them by name (see the rendered CONTRIBUTING.md).
- **docs.py**: documentation generation, Markdown -> HTML (markdown-it-py + Pygments) -> PDF
  (WeasyPrint, a CSS Paged Media engine, no browser), plus the repo README.
- **package.py**: packaging helpers for driver.xml version/modified stamping and zip bundling, and the
  package checks `make package` and CI run (stdlib).
- **deps.py**: build preflight, checks the `.venv` against `requirements.txt` and names what is
  missing instead of failing later with a bare `ImportError` (stdlib).
- **gen-squishy.lua**: auto-generates squishy files for squish (Lua module bundler) from driver.c4zproj.
- **github-markdown.css**: vendored stylesheet for the rendered documentation.
- **github-setup**: checks the GitHub repository against the standard settings and prints the
  drift; with `--apply` it creates the repository if needed and fixes the drift.
- **icons.py**: `make icons`, which exports the icons and doc images from
  `resources/Driver Icons.sketch` with Sketch's `sketchtool`. Needs Sketch; no build runs it.
- **test_preprocess.py**: tests for preprocess.py's directives, shared doc images, build encryption and
  secrets check, run by `make test`.

### Common Libraries (`src/lib/`)
- **bindings.lua**: binding management (add/remove/query Control4 driver bindings)
- **conditionals.lua**: conditional/programming UI management
- **events.lua**: event firing and management
- **http.lua**: HTTP client wrapper around C4:urlGet/urlPost/urlPut/urlDelete
- **lru.lua**: LRU cache utility
- **persist.lua**: persistent storage abstraction over C4 PersistData
- **redact.lua**: masks credentials in log lines and diagnostics reports
- **values.lua**: value parsing, coercion, and formatting utilities
- **logging.lua** / **utils.lua**: structured logging and general utilities (always included)
- **github-updater.lua**: GitHub Releases-based self-updater for non-DriverCentral (`oss`) builds
- **diagnostics.lua**: Cloud Monitoring, a DriverCentral build's hourly memory and error reports to InfluxDB (only with `cloud_diagnostics`)

### Vendor Libraries (`vendor/`, some selected via `vendor_modules`)
- **JSON.lua**: JSON encoder/decoder
- **deferred.lua**: promise/deferred implementation for async workflows
- **version.lua**: semantic version comparison
- **cloud-client-byte.lua**: DriverCentral cloud client
- **drivers-common-public/**: Control4's official shared libraries (handlers, lib, timer, url, websocket), in every repo; each file's header lists our changes to it
- **xml/**: XML parser (xml2lua)
- **bitn.lua**: bit manipulation library
- **crypto.lua**: cryptographic primitives (core build; requires `bitn`)
- **bthome.lua**: BTHome protocol support
- **noiseprotocol.lua**: Noise Protocol encryption
- **protobuf.lua**: Protocol Buffers
- **drivers-common-public/module/auth_code_grant.lua** + **global/make_short_link.lua** (`oauth`): Control4's OAuth authorization-code grant through its redirect service, and its short links. Both need API keys from Control4

### Test Support (`test/`)
- **c4_shim.lua**: shim layer replacing C4 API calls with native Lua equivalents for local testing
- **run_test.sh**: test runner script with LuaJIT

### Driver Icons and Shared Doc Images (`resources/`)
- **Driver Icons.sketch**: Control4's OS 3 device and service icon template, plus the Finite Labs
  frames: the documentation header, the DriverCentral card and the light and dark website cards.
  Copied once when a project is created; `copier update` never touches it after that.
- **documentation/images/**: images every driver's docs share: `finite-labs-logo.png` and
  `check-drivers.png` (the DriverCentral Cloud driver's Check Drivers action). `preprocess.py` copies
  one into a built driver doc's `images/` when the doc links it and has no copy of its own.
- **drivercentral/**: the DriverCentral marketing set: the spotlight banner, the launch-post image, the description's facts strip and
  the listing photo frame, as HTML pages that `render.sh` renders to PNG with Chrome. Copied once,
  like the Sketch file; its README says how to fill it in. No make target runs it.

### Project Files
- **Makefile**: build, format, docs, package, verify, and clean targets
- **CONTRIBUTING.md**: explains how the template system works
- **.gitignore**, **LICENSE**, **CHANGELOG.md**, **README.md**

## Build Prerequisites

- Python 3.9+ (docs, formatters, preprocess, and the driver packager)
- Git, since `make init` clones the driverpackager into `dist/`
- [LuaJIT](https://luajit.org/) (`brew install luajit`), for gen-squishy and the tests
- [stylua](https://github.com/JohnnyMorganz/StyLua) (`brew install stylua`), the Lua formatter
- [Pango](https://gtk.org/) (`brew install pango`), WeasyPrint's PDF rendering engine
- `swig` and OpenSSL headers (`brew install swig openssl`), which M2Crypto compiles against

`make init` provisions the rest into a local `.venv` (WeasyPrint, markdown-it-py, mdit-py-plugins,
Pygments, mdformat, black, and the packager's M2Crypto + lxml).

## Usage

### Create a New Driver Project

```bash
uvx copier copy --trust gh:finitelabs/control4-driver-template my-new-driver
```

### Set Up the GitHub Repository

After scaffolding, create the GitHub repository and apply the standard settings:

```bash
cd my-new-driver
./tools/github-setup           # dry run: prints the changes it would make
./tools/github-setup --apply   # make the changes (add --public for a public repo)
```

The repository is `<github_org>/<project_name>` from the copier answers, so
the script works against whatever organization or personal account the
project was scaffolded for. It is idempotent and can be re-run on existing
repositories to check for or fix drift. The standard is:

- Description is `project_description` from the copier answers
- Projects and wiki disabled
- Squash merges only, auto-merge allowed, head branches deleted on merge
- Default branch `main` (an existing `master` gets renamed)
- Branch ruleset named `Default` on the default branch: no deletions or force
  pushes, PRs require one approval and a passing `build` check, plus any
  checks named in `extra_required_checks`, squash merges only, org admins can
  bypass
- Dependabot alerts and security updates enabled

One step stays manual: add the repository to the project's VCS integration in
YouTrack so the webhook gets installed. YouTrack generates the webhook
endpoint, so it cannot be scripted from the GitHub side.

### Make the Driver's Icons

In `resources/Driver Icons.sketch`:

1. Set the `Brand/Accent` color variable to the repo's `primary_color` (in `.copier-answers.yml`),
   so the icons match the docs' headings. The accent tiles fade from it to `Brand/Accent Dark`, so
   make that about 15% darker.
2. Replace the circle in the `Icon` and `Icon White` symbols with the brand's icon mark, taken
   from its official SVG kit.
3. In `Documentation Header`, replace `Brand Logo` with the brand's logo and set the driver name.
4. Leave the grids hidden, or they end up in the exports.

Then `make icons` exports everything to `dist/icons/`:

- `www/icons/`: Control4's Shadow Shaped or Shadow Square icon, as `icon_style` picks, at the 18
  sizes the drivers ship
- `www/documentation/images/`: `header.png`
- `cards/`: the DriverCentral card and the light and dark website cards, which carry no badges;
  the DriverCentral card's tile is centered at 264 px in its 300 px frame

It also refreshes each of those files a driver already has under `drivers/*/www/`, and the
repo-root `documentation/images/header.png` a root-docs README is built from. Run
`make docs-readme`, then commit what both refreshed, so `make icons` leaves a clean tree. For a new driver,
copy the ones it uses from `dist/icons/www/` into `drivers/<name>/www/` once.

### Update an Existing Driver with Latest Template

Copier is only needed for this occasional sync. It is not a build dependency.
Run it without installing anything:

```bash
cd my-existing-driver
uvx copier update --trust        # using uv
# or: pipx run copier update --trust
```

Copier will show diffs for any files that changed in the template and let you resolve conflicts.

### Template Variables

| Variable | Description | Default |
|---|---|---|
| `project_name` | Project name (e.g., `control4-esphome`) | (required) |
| `project_description` | Short description | `A Control4 driver` |
| `github_org` | GitHub organization | (required) |
| `dc_pid` | DriverCentral product id; 0 until the product exists. Every repo builds both `drivercentral` and `oss` | `0` |
| `readme_driver_slug` | Driver slug for README generation (`root` for a suite README) | (required) |
| `readme_build` | Build distribution for README | `oss` |
| `primary_color` | Accent color for generated docs | `#109EFF` |
| `icon_style` | Control4 icon artboard `make icons` exports: `shaped` (Shadow Shaped) or `square` (Shadow Square) | `shaped` |
| `vendor_modules` | Space-separated *optional* `vendor` modules (bitn crypto bthome noiseprotocol protobuf oauth) | (empty) |
| `cloud_diagnostics` | Ship `lib.diagnostics` (Cloud Monitoring), which reports a DriverCentral build's memory use and errors to InfluxDB; needs four build secrets | `false` |
| `extra_build_secrets` | Space-separated build secrets `.env.default` declares besides the template's own (`SUPPORT_CODE_SECRET`, and the four `INFLUXDB_*` with `cloud_diagnostics`); the Build workflow passes each by name | (empty) |
| `extra_required_checks` | Space-separated status checks a PR must pass besides `build`, each a job name from the repo's own workflows; `tools/github-setup` puts them in the branch ruleset | (empty) |
| `stale_issues` | Ping inactive issues, then close them, unless an exempt author opened them | `false` |
| `stale_exempt_authors` | Space-separated GitHub logins whose issues are left alone; a GitHub App is `name[bot]` (asked when `stale_issues` is true) | (empty) |
| `stale_days` | Days without activity before the ping (asked when `stale_issues` is true) | `30` |
| `stale_close_days` | Days after the ping before the issue closes (asked when `stale_issues` is true) | `14` |
