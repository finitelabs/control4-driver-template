# Changelog

Changes to the template. A driver repo picks up a release with `copier update`.

## v0.9.34 - 2026-10-13

### Added

- `tools/github-setup` keeps the GitHub repository description in sync with
  `project_description`. It reports a description that differs, showing both
  texts, and sets it with `--apply`, like its other settings. Before, it set the
  description only when it created the repository, so an existing repository
  could drift unnoticed.
- `lib.persist` gains `peek()`, which returns a stored table without copying it,
  `commit()`, which stores a table without copying it, and `durable()`, which
  writes a key now, or once when the outermost `defer()` closes.
- `lib.events`, `lib.conditionals` and `lib.bindings` gain `setWriteBehind(ms)`
  and `flush()`, like `lib.values`, so a driver can batch their writes.

### Changed

- `lib.values`, `lib.events`, `lib.conditionals` and `lib.bindings` no longer
  copy their whole table to read or add a record, which grew slow past a few
  hundred records. Their getters still return copies. With `setWriteBehind()`, a
  batch of adds inside `persist:defer()` is saved once per library. Without it,
  or outside `defer()`, every change is still saved as it is made.
- Stored events, conditionals or bindings that do not read back as a table start
  over empty, with a warning in the log. Before, the library raised.
  `lib.values` already started over, and now logs the warning too.
- Build artifacts are kept 14 days on a tag, 3 days on a push to `main` and 1
  day on a pull request. Before, every build kept them for the repository's
  maximum.

### Fixed

- `tools/github-setup` reads a copier answer in full. Copier wraps a long answer
  onto indented lines in `.copier-answers.yml` and single-quotes one that
  contains `": "`. The tool read only the first line and kept the quotes, so a
  repository it created got a truncated description.
- `lib.persist` no longer remembers a default passed to `get()` as the key's
  value.
- `get()` of a missing key in `lib.persist` no longer hands every caller one
  shared table.
- `flush()` in `lib.persist` keeps a key pending when its write raises, and
  writes the other keys before it raises the error. It dropped the key's pending
  mark first and stopped at that write.
- The test shim's `string.pack` packs a NaN and the infinities as a controller
  does. It packed a NaN and `+inf` as 0.5 and `-inf` as -0.5, without an error.
