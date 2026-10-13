# Changelog

Changes to the template. A driver repo picks up a release with `copier update`.

## v0.9.34 - 2026-10-13

### Added

- `tools/github-setup` keeps the GitHub repository description in sync with
  `project_description`. It reports a description that differs, showing both
  texts, and sets it with `--apply`, like its other settings. Before, it set the
  description only when it created the repository, so an existing repository
  could drift unnoticed.

### Changed

- `persist:get(key)` with no default returns nil for a key that is not stored.
  Before, it returned one table shared by every such key and every caller, which
  `persist:get(key) or {}` wrote into. Pass `{}` as the default where a table is
  wanted.
- Build artifacts are kept 14 days on a tag, 3 days on a push to `main` and 1
  day on a pull request. Before, every build kept them for the repository's
  maximum.

### Fixed

- `tools/github-setup` reads a copier answer in full. Copier wraps a long answer
  onto indented lines in `.copier-answers.yml` and single-quotes one that
  contains `": "`. The tool read only the first line and kept the quotes, so a
  repository it created got a truncated description.
- `lib.persist` no longer remembers a default passed to `get()` as the key's
  value. A table default comes back as a copy.
- `lib.persist` no longer runs a migration for a key that is not stored. Before,
  the migration was given the read's default, or the table shared by unset keys,
  and its answer was stored.
- The test shim's `string.pack` packs a NaN and the infinities as a controller
  does. It packed a NaN and `+inf` as 0.5 and `-inf` as -0.5, without an error.
