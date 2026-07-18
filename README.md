# control4-driver-template

[Copier](https://copier.readthedocs.io/) template for Control4 driver projects. Contains shared
infrastructure, build tooling, and common Lua libraries used across all Finite Labs drivers.

## What's Included

### Build Tooling (`tools/`)
- **preprocess** — C preprocessor-style `#ifdef`/`#ifndef` for Lua, XML, and Markdown. Supports variant
  expansion for generating multiple driver configurations from a single source.
- **gen-squishy.lua** — Auto-generates squishy files for squish (Lua module bundler) from driver.c4zproj.
- **pandoc-remove-style.lua** — Pandoc filter for cleaning up markdown when generating README from docs.
- **github-setup** - Creates the GitHub repository if it does not exist and converges it to the
  standard repository settings. Safe to re-run.

### Common Libraries (`src/lib/`)
- **bindings.lua** — Binding management (add/remove/query Control4 driver bindings)
- **conditionals.lua** — Conditional/programming UI management
- **events.lua** — Event firing and management
- **http.lua** — HTTP client wrapper around C4:urlGet/urlPost/urlPut/urlDelete
- **logging.lua** — Structured logging with configurable levels (Fatal through Ultra)
- **persist.lua** — Persistent storage abstraction over C4 PersistData
- **utils.lua** — General utilities (XML parsing, device queries, table helpers, type coercion, etc.)
- **values.lua** *(optional)* — Value parsing, coercion, and formatting utilities
- **github-updater.lua** *(optional)* — GitHub Releases-based self-updater for non-DriverCentral builds

### Vendor Libraries (`vendor/`)
- **JSON.lua** — JSON encoder/decoder
- **deferred.lua** — Promise/deferred implementation for async workflows
- **version.lua** — Semantic version comparison
- **cloud-client-byte.lua** — DriverCentral cloud client
- **drivers-common-public/** — Control4's official shared libraries (handlers, lib, timer, url)
- **xml/** — XML parser (xml2lua)

### Test Support (`test/`)
- **c4_shim.lua** — Shim layer replacing C4 API calls with native Lua equivalents for local testing
- **run_test.sh** — Test runner script with LuaJIT

### Project Files
- **Makefile** — build, format, docs, package, and clean targets
- **package.json** — npm dependency declarations only (no scripts)
- **CONTRIBUTING.md** — explains how the template system works
- **.gitignore**, **LICENSE**, **CHANGELOG.md**, **README.md**

## Usage

### Create a New Driver Project

```bash
copier copy gh:finitelabs/control4-driver-template my-new-driver
```

### Set Up the GitHub Repository

After scaffolding, create the GitHub repository and apply the standard settings:

```bash
cd my-new-driver
make github-setup            # creates a private repo
./tools/github-setup --public
```

The script is idempotent and can be re-run on existing repositories to bring
them back to the standard. The standard is:

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

```bash
cd my-existing-driver
copier update
```

Copier will show diffs for any files that changed in the template and let you resolve conflicts.

### Template Variables

| Variable | Description | Default |
|---|---|---|
| `project_name` | Project name (e.g., `control4-esphome`) | — |
| `project_description` | Short description | `A Control4 driver` |
| `github_org` | GitHub organization | — |
| `distributions` | Space-separated build targets | `drivercentral oss` |
| `has_github_updater` | Include GitHub self-updater? | `true` |
| `has_tests` | Include test directory? | `true` |
| `readme_driver_slug` | Driver slug for README generation | — |
| `readme_build` | Build distribution for README | `oss` |

## Source Repos

This template was created by unifying shared code from:
- [control4-home-connect](https://github.com/finitelabs/control4-home-connect)
- [control4-esphome](https://github.com/finitelabs/control4-esphome)
- [control4-mqtt](https://github.com/finitelabs/control4-mqtt)

When the "best" version of a shared file differed across repos, the most complete/modern version was chosen:
- **HC/ES version** (identical, most complete): conditionals, http, logging, gen-squishy, pandoc-remove-style, drivers-common-public (handlers, timer, url)
- **ES version** (most advanced): preprocess (variant support), deferred (modern annotations), utils (core + binary serialization), drivers-common-public/lib
- **ES/MQ version** (identical): values, github-updater, version
- **HC version** (most complete): persist
