# control4-driver-template

[Copier](https://copier.readthedocs.io/) template for Control4 driver projects. Contains shared
infrastructure, build tooling, and common Lua libraries used across all Finite Labs drivers.

The toolchain is Python + a few standalone binaries — **no Node/npm**. `make init` creates a local
`.venv` with everything the build needs (docs, formatters, and the driver packager's crypto/XML libs).

## What's Included

### Build Tooling (`tools/`)
- **preprocess.py** — C preprocessor-style `#ifdef`/`#ifndef` for Lua, XML, and Markdown. Supports
  variant expansion for generating multiple driver configurations from a single source.
- **docs.py** — documentation generation: Markdown → HTML (markdown-it-py + Pygments) → PDF
  (WeasyPrint, a CSS Paged Media engine — no browser), plus the repo README.
- **package.py** — packaging helpers: driver.xml version/modified stamping and zip bundling (stdlib).
- **gen-squishy.lua** — Auto-generates squishy files for squish (Lua module bundler) from driver.c4zproj.
- **github-markdown.css** — Vendored stylesheet for the rendered documentation.
- **github-setup** — Checks the GitHub repository against the standard settings and prints the
  drift; with `--apply` it creates the repository if needed and fixes the drift.

### Common Libraries (`src/lib/`, selected via `lib_modules`)
- **bindings.lua** — Binding management (add/remove/query Control4 driver bindings)
- **conditionals.lua** — Conditional/programming UI management
- **events.lua** — Event firing and management
- **http.lua** — HTTP client wrapper around C4:urlGet/urlPost/urlPut/urlDelete
- **lru.lua** — LRU cache utility
- **persist.lua** — Persistent storage abstraction over C4 PersistData
- **values.lua** — Value parsing, coercion, and formatting utilities
- **logging.lua** / **utils.lua** — Structured logging and general utilities (always included)
- **github-updater.lua** — GitHub Releases-based self-updater for non-DriverCentral (`oss`) builds

### Vendor Libraries (`vendor/`, selected via `vendor_modules`)
- **JSON.lua** — JSON encoder/decoder
- **deferred.lua** — Promise/deferred implementation for async workflows
- **version.lua** — Semantic version comparison
- **cloud-client-byte.lua** — DriverCentral cloud client
- **drivers-common-public/** — Control4's official shared libraries (handlers, lib, timer, url)
- **xml/** — XML parser (xml2lua)
- **bitn.lua** — bit manipulation library
- **crypto.lua** — cryptographic primitives (core build; requires `bitn`)
- **bthome.lua** — BTHome protocol support
- **noiseprotocol.lua** — Noise Protocol encryption
- **protobuf.lua** — Protocol Buffers

### Test Support (`test/`)
- **c4_shim.lua** — Shim layer replacing C4 API calls with native Lua equivalents for local testing
- **run_test.sh** — Test runner script with LuaJIT

### Project Files
- **Makefile** — build, format, docs, package, and clean targets
- **CONTRIBUTING.md** — explains how the template system works
- **.gitignore**, **LICENSE**, **CHANGELOG.md**, **README.md**

## Build Prerequisites

- Python 3.9+ (docs, formatters, preprocess, and the driver packager)
- [LuaJIT](https://luajit.org/) (`brew install luajit`) — squish and tests
- [stylua](https://github.com/JohnnyMorganz/StyLua) (`brew install stylua`) — Lua formatter
- [Pango](https://gtk.org/) (`brew install pango`) — WeasyPrint's PDF rendering engine

`make init` provisions the rest into a local `.venv` (WeasyPrint, markdown-it-py, Pygments, mdformat,
black, and the packager's M2Crypto + lxml).

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

- Projects and wiki disabled
- Squash merges only, auto-merge allowed, head branches deleted on merge
- Default branch `main` (an existing `master` gets renamed)
- Branch ruleset named `Default` on the default branch: no deletions or force
  pushes, PRs require one approval and a passing `build` check, squash merges
  only, org admins can bypass
- Dependabot alerts and security updates enabled

One step stays manual: add the repository to the project's VCS integration in
YouTrack so the webhook gets installed. YouTrack generates the webhook
endpoint, so it cannot be scripted from the GitHub side.

### Update an Existing Driver with Latest Template

Copier is only needed for this occasional sync — it is not a build dependency.
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
| `project_name` | Project name (e.g., `control4-esphome`) | — |
| `project_description` | Short description | `A Control4 driver` |
| `github_org` | GitHub organization | — |
| `distributions` | Space-separated build targets | `drivercentral oss` |
| `readme_driver_slug` | Driver slug for README generation (`root` for a suite README) | — |
| `readme_build` | Build distribution for README | `oss` |
| `primary_color` | Accent color for generated docs | `#109EFF` |
| `lib_modules` | Space-separated `src/lib` modules to include | — |
| `vendor_modules` | Space-separated `vendor` modules to include | `json deferred drivers-common-public xml` |
