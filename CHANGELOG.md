# Changelog

Changes to the template. A driver repo picks up a release with `copier update`.

## v0.9.32 - 2026-10-02

### Added

- `tools/github-setup` keeps the GitHub repository description in sync with
  `project_description`. It reports a description that differs and sets it with
  `--apply`, like its other settings. Before, it set the description only when
  it created the repository, so an existing repository could drift unnoticed.

### Fixed

- `tools/github-setup` reads a copier answer in full. Copier wraps a long answer
  onto indented lines in `.copier-answers.yml` and single-quotes one that
  contains `": "`. The tool read only the first line and kept the quotes, so a
  repository it created got a truncated description.
