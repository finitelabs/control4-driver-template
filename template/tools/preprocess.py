#!/usr/bin/env python3

# PEP 604 annotations (`str | None`) raise TypeError at import on the documented 3.9 floor.
from __future__ import annotations

import argparse
import itertools
import json
import os
import shutil
import re
import sys
import zipfile
from pathlib import Path

# Cannot collide with the %%VAR%% variant substitution, whose \w+ names have no colon.
SECRET_PATTERN = re.compile(r"%%SECRET:([A-Za-z_][A-Za-z0-9_]*)%%")
SECRET_PATTERN_BYTES = re.compile(SECRET_PATTERN.pattern.encode())
SECRET_PREFIX_BYTES = re.compile(rb"%%SECRET:")
MALFORMED_EXCERPT_BYTES = re.compile(rb"%%SECRET:[^\s\"']*")
SECRET_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
SUBSTITUTED_RECORD = "secrets-substituted"


def process_file(
    file_path: Path,
    conditions: set[str],
    variant_map: dict[str, list[str]] = {},
    passthrough_unknown: bool = False,
) -> None:
    """
    Process a file for conditional directives.

    Args:
        file_path: Path to the file to process
        conditions: Set of conditions to check against, e.g., {"DRIVERCENTRAL"} or {"DRIVERCENTRAL", "DRIVERCENTRAL_DEV"}
        variant_map: Dict mapping template names to generated variant names
        passthrough_unknown: If True, directives referencing conditions not in
            the conditions set are passed through unchanged (directive lines and
            content preserved). Used during variant expansion so that
            distribution-level conditions survive for the next processing pass.
    """
    # Stack to track nested conditions: (condition, parent_including, transparent)
    # transparent=True means this condition is unknown and should be passed through
    condition_stack = []
    # Whether we're currently including lines
    including = True
    # Lines to keep
    output_lines = []

    try:
        with open(file_path, "tr", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return

    # Regular expressions for different file types
    xml_ifdef_pattern = re.compile(r"^\s*<!--\s*#ifdef\s+(\w+)\s*-->\s*$")
    xml_ifndef_pattern = re.compile(r"^\s*<!--\s*#ifndef\s+(\w+)\s*-->\s*$")
    xml_else_pattern = re.compile(r"^\s*<!--\s*#else\s*-->\s*$")
    xml_endif_pattern = re.compile(r"^\s*<!--\s*#endif\s*-->\s*$")

    lua_ifdef_pattern = re.compile(r"^\s*--\s*#ifdef\s+(\w+)\s*$")
    lua_ifndef_pattern = re.compile(r"^\s*--\s*#ifndef\s+(\w+)\s*$")
    lua_else_pattern = re.compile(r"^\s*--\s*#else\s*$")
    lua_endif_pattern = re.compile(r"^\s*--\s*#endif\s*$")

    slash_ifdef_pattern = re.compile(r"^\s*//\s*#ifdef\s+(\w+)\s*$")
    slash_ifndef_pattern = re.compile(r"^\s*//\s*#ifndef\s+(\w+)\s*$")
    slash_else_pattern = re.compile(r"^\s*//\s*#else\s*$")
    slash_endif_pattern = re.compile(r"^\s*//\s*#endif\s*$")

    # Generic patterns (for other file types)
    generic_ifdef_pattern = re.compile(r"^\s*#ifdef\s+(\w+)\s*$")
    generic_ifndef_pattern = re.compile(r"^\s*#ifndef\s+(\w+)\s*$")
    generic_else_pattern = re.compile(r"^\s*#else\s*$")
    generic_endif_pattern = re.compile(r"^\s*#endif\s*$")

    # Embed changelog pattern, resolved in a pre-pass so that directives
    # inside the changelog are handled by the main processing loop.
    changelog_pattern = re.compile(r"^\s*<!--\s*#embed-changelog\s*-->\s*$")

    # Embed a generated fragment by path (relative to this file's directory),
    # e.g. `<!-- #embed generated/binding_keys.xml -->`. Resolved in the same
    # pre-pass so directives inside the fragment are handled by the main loop.
    embed_pattern = re.compile(r"^\s*<!--\s*#embed\s+(\S+)\s*-->\s*$")

    # Variant filenames pattern (Lua comment style)
    variant_filenames_pattern = re.compile(r"^(\s*)--\s*#variant-filenames\s+(\w+)\s*$")

    ifdef_patterns = [
        xml_ifdef_pattern,
        lua_ifdef_pattern,
        slash_ifdef_pattern,
        generic_ifdef_pattern,
    ]
    ifndef_patterns = [
        xml_ifndef_pattern,
        lua_ifndef_pattern,
        slash_ifndef_pattern,
        generic_ifndef_pattern,
    ]
    else_patterns = [
        xml_else_pattern,
        lua_else_pattern,
        slash_else_pattern,
        generic_else_pattern,
    ]
    endif_patterns = [
        xml_endif_pattern,
        lua_endif_pattern,
        slash_endif_pattern,
        generic_endif_pattern,
    ]

    # Pre-pass: expand #embed-changelog directives inline so that any
    # conditional directives inside the changelog are processed by the
    # main loop below (no duplicated ifdef/ifndef logic needed).
    expanded_lines = []
    for line in lines:
        embed_match = embed_pattern.match(line)
        if changelog_pattern.match(line):
            try:
                changelog_path = Path(__file__).parent.parent / "CHANGELOG.md"
                with open(changelog_path, "r", encoding="utf-8") as cf:
                    expanded_lines.extend(cf.readlines())
            except Exception as e:
                print(f"Error embedding changelog in {file_path}: {e}")
        elif embed_match:
            rel_path = embed_match.group(1)
            embed_path = file_path.parent / rel_path
            try:
                with open(embed_path, "r", encoding="utf-8") as ef:
                    expanded_lines.extend(ef.readlines())
            except Exception as e:
                raise ValueError(f"Error embedding {rel_path} in {file_path}: {e}")
        else:
            expanded_lines.append(line)
    lines = expanded_lines

    # The pre-pass doesn't recurse, so an #embed inside an embedded fragment is never
    # expanded. Raise rather than pass it through as a literal comment, matching the
    # missing-fragment raise above.
    for line in lines:
        if embed_pattern.match(line):
            raise ValueError(
                f"Nested #embed is not supported (in a fragment embedded into {file_path})"
            )

    for line in lines:
        # Check for conditional directives
        ifdef_match = next(
            (m for pattern in ifdef_patterns if (m := pattern.match(line))), None
        )
        ifndef_match = next(
            (m for pattern in ifndef_patterns if (m := pattern.match(line))), None
        )
        else_match = next(
            (m for pattern in else_patterns if (m := pattern.match(line))), None
        )
        endif_match = next(
            (m for pattern in endif_patterns if (m := pattern.match(line))), None
        )
        variant_filenames_match = variant_filenames_pattern.match(line)

        # Check for #ifdef
        if ifdef_match:
            line_condition = ifdef_match.group(1)
            transparent = passthrough_unknown and line_condition not in conditions
            condition_stack.append((line_condition, including, transparent))
            if transparent:
                if including:
                    output_lines.append(line)
            else:
                including = including and line_condition in conditions
            continue

        # Check for #ifndef
        if ifndef_match:
            line_condition = ifndef_match.group(1)
            transparent = passthrough_unknown and line_condition not in conditions
            condition_stack.append((line_condition, including, transparent))
            if transparent:
                if including:
                    output_lines.append(line)
            else:
                including = including and line_condition not in conditions
            continue

        # Check for #else
        if else_match:
            if not condition_stack:
                print(f"Error: #else without matching #ifdef/#ifndef in {file_path}")
                continue
            line_condition, parent_including, transparent = condition_stack[-1]
            if transparent:
                if including:
                    output_lines.append(line)
            else:
                including = parent_including and not including
            continue

        # Check for #endif
        if endif_match:
            if not condition_stack:
                print(f"Error: #endif without matching #ifdef/#ifndef in {file_path}")
                continue
            _, parent_including, transparent = condition_stack.pop()
            if transparent:
                if including:
                    output_lines.append(line)
            else:
                including = parent_including if condition_stack else True
            continue

        # Check for #variant-filenames <template_name>
        if variant_filenames_match and including:
            indent = variant_filenames_match.group(1)
            template_name = variant_filenames_match.group(2)
            names = variant_map.get(template_name)
            if names is None:
                raise ValueError(
                    f"Unknown variant template '{template_name}' in {file_path}. "
                    f"Known templates: {list(variant_map.keys())}"
                )
            for name in names:
                output_lines.append(f'{indent}"{name}.c4z",\n')
            continue

        # If we're including this line, add it to the output
        if including:
            output_lines.append(line)

    # Check if we have unmatched conditionals
    if condition_stack:
        print(
            f"Warning: Unmatched conditional directives in {file_path}: {condition_stack}"
        )

    # Write the processed content back to the file
    with open(file_path, "w", encoding="utf-8") as f:
        f.writelines(output_lines)


def replace_template_variables(file_path: Path, variables: dict) -> None:
    """
    Replace __VAR_NAME__ placeholders in a file with variant-specific values.

    Args:
        file_path: Path to the file to process
        variables: Dict of variable name -> value (e.g., {"FAN_SPEED_COUNT": "3"})
    """
    try:
        with open(file_path, "tr", encoding="utf-8") as f:
            content = f.read()
    except Exception:
        return

    for var_name, var_value in variables.items():
        content = content.replace(f"__{var_name}__", var_value)
        # Also replace %%VAR%% syntax (for use in markdown files where __X__
        # is interpreted as bold by markdown formatters)
        content = content.replace(f"%%{var_name}%%", var_value)

    with open(file_path, "w", encoding="utf-8") as f:
        f.write(content)


def load_dotenv(repo_root: Path) -> set[str]:
    """
    Seed the environment from a repo-root .env, without overriding a variable that is
    already set to a non-empty value. Each line is NAME=value, optionally prefixed with
    `export `; a line starting with # is a comment, and one pair of matching surrounding
    quotes is stripped from a value.

    Args:
        repo_root: Repository root to look for .env in

    Returns:
        The names whose value now comes from .env

    Raises:
        SystemExit: The file is not UTF-8, a line is not a comment, blank, or
            NAME=value, or a name is repeated
    """
    dotenv_path = repo_root / ".env"
    if not dotenv_path.is_file():
        return set()

    try:
        lines = dotenv_path.read_text(encoding="utf-8-sig").splitlines()
    except UnicodeDecodeError as e:
        raise SystemExit(f"Error: .env is not UTF-8 ({e.reason} at byte {e.start}).")

    seen = {}
    from_dotenv = set()
    for number, line in enumerate(lines, 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].lstrip()
        name, separator, value = line.partition("=")
        name = name.strip()
        if not separator or not SECRET_NAME.fullmatch(name):
            raise SystemExit(f"Error: .env line {number} is not NAME=value.")
        if name in seen:
            raise SystemExit(
                f"Error: .env sets {name} on line {seen[name]} and again on line {number}."
            )
        seen[name] = number
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if not os.environ.get(name):
            os.environ[name] = value
            from_dotenv.add(name)
    return from_dotenv


def secret_value(name: str) -> str | None:
    """
    The value to substitute for a secret, or None when it is unset or empty. GitHub
    gives an unset repository secret as an empty string.

    Raises:
        SystemExit: The value cannot be spliced into a Lua string literal as-is
    """
    value = os.environ.get(name)
    if not value:
        return None
    if any(c in value for c in "\\\"'\n\r"):
        raise SystemExit(
            f"Error: build secret {name} contains a backslash, quote or newline, "
            "which a Lua string literal would not carry unchanged."
        )
    return value


def substitute_secrets(build_dir: Path, from_dotenv: set[str]) -> None:
    """
    Replace %%SECRET:NAME%% placeholders in the Lua files of the build output with the
    environment variable of the same name. An unset or empty one is left in place, as is
    a placeholder in any other file, and the scan of the packaged output reports it if
    it ships.

    Writes the names it substituted to build_dir/secrets-substituted, one per line, so
    the scan looks for the values of exactly those, including a placeholder that only
    variant expansion produced.

    Args:
        build_dir: Build directory to walk
        from_dotenv: Names whose value came from .env, for the report
    """
    substituted_names = set()

    def replace(match: re.Match) -> str:
        value = secret_value(match.group(1))
        if value is None:
            return match.group(0)
        substituted_names.add(match.group(1))
        return value

    for file_path in sorted(build_dir.rglob("*.lua")):
        if not file_path.is_file():
            continue
        content = file_path.read_text(encoding="utf-8")
        substituted = SECRET_PATTERN.sub(replace, content)
        if substituted != content:
            file_path.write_text(substituted, encoding="utf-8")

    write_substituted_record(build_dir, substituted_names)
    if substituted_names:
        print(
            f"Build secrets substituted in {build_dir.name}: "
            + ", ".join(
                f"{name} (from {'.env' if name in from_dotenv else 'the environment'})"
                for name in sorted(substituted_names)
            )
        )


def write_substituted_record(build_dir: Path, names: set[str]) -> None:
    (build_dir / SUBSTITUTED_RECORD).write_text(
        "".join(f"{name}\n" for name in sorted(names)), encoding="utf-8"
    )


def shipped_files(dist_dir: Path):
    """
    Yield (label, bytes) for every file under dist_dir, and for every member of a .c4z
    or .zip in it.
    """
    for path in sorted(p for p in dist_dir.rglob("*") if p.is_file()):
        label = str(path)
        data = path.read_bytes()
        yield label, data
        if path.suffix in (".c4z", ".zip") and zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                for member in archive.namelist():
                    if not member.endswith("/"):
                        yield f"{label}:{member}", archive.read(member)


def scan_shipped_secrets(
    repo_root: Path, distribution: str, takes_secrets: bool, unresolved_secrets: str
) -> None:
    """
    Scan what a distribution ships (dist/<distribution>) for placeholders that were not
    substituted. A placeholder in a module no driver requires never reaches dist/, so it
    needs no value.

    Writes build/<distribution>/secrets-scan-clean when the output carries neither a
    placeholder nor the value of a secret the preprocess step substituted, which
    build.yml requires to upload from a public repository, and secrets-scan-unresolved
    when a placeholder survives, in either mode.

    Args:
        repo_root: Repository root
        distribution: Distribution name
        takes_secrets: Whether the preprocess step substitutes into this distribution
        unresolved_secrets: "fail" to exit 1 on a placeholder no value was set for,
            "skip" to report it and mark the distribution as not to be uploaded
    """
    dist_dir = repo_root / "dist" / distribution
    marker_dir = repo_root / "build" / distribution
    clean_marker = marker_dir / "secrets-scan-clean"
    unresolved_marker = marker_dir / "secrets-scan-unresolved"
    clean_marker.unlink(missing_ok=True)
    unresolved_marker.unlink(missing_ok=True)

    if not dist_dir.is_dir():
        raise SystemExit(f"Error: {dist_dir} does not exist; package it first.")

    record = marker_dir / SUBSTITUTED_RECORD
    if not record.is_file():
        raise SystemExit(f"Error: {record} does not exist; preprocess it first.")
    names = record.read_text(encoding="utf-8").split()
    values = [os.environ.get(name) for name in names]

    # Setting a variable fixes only a missing value, so skip mode tolerates nothing else.
    unset, unguarded, not_lua, malformed = [], [], [], []
    carries_secret = False
    for label, data in shipped_files(dist_dir):
        label = os.path.relpath(label, repo_root)
        for position in (m.start() for m in SECRET_PREFIX_BYTES.finditer(data)):
            match = SECRET_PATTERN_BYTES.match(data, position)
            if not match:
                text = MALFORMED_EXCERPT_BYTES.match(data, position).group(0)[:60]
                malformed.append(f"{label}: {text.decode(errors='replace')}")
                continue
            entry = f"{label}: {match.group(1).decode()}"
            if not label.endswith(".lua"):
                not_lua.append(entry)
            elif not takes_secrets:
                unguarded.append(entry)
            else:
                unset.append(entry)
        carries_secret = carries_secret or any(
            v is None or v.encode() in data for v in values
        )

    marker_dir.mkdir(parents=True, exist_ok=True)
    errors = [
        (
            f"Build secret placeholders in dist/{distribution}, which never takes a "
            "secret:",
            unguarded,
            "Guard each placeholder with #ifdef DRIVERCENTRAL.",
        ),
        (
            f"Build secret placeholders in files of dist/{distribution} that are not "
            "Lua:",
            not_lua,
            "Only Lua source takes a secret; move the placeholder into a .lua file.",
        ),
        (
            f"Malformed build secret placeholders in dist/{distribution}:",
            malformed,
            "Write each one as %%SECRET:NAME%%, NAME being letters, digits and "
            "underscores.",
        ),
        (
            f"Unresolved build secrets in dist/{distribution}:",
            unset,
            "Set each name in the environment or a repo-root .env, then rebuild. "
            "For CI, list it in the build_secrets copier answer and add a "
            "repository Actions secret of the same name.",
        ),
    ]
    failing = [e for e in errors if e[1]]
    for heading, entries, remedy in failing:
        print(heading)
        for entry in sorted(set(entries)):
            print(f"  {entry}")
        print(remedy)
    if failing:
        unresolved_marker.touch()
        if unresolved_secrets != "skip" or unguarded or not_lua or malformed:
            sys.exit(1)
        print(f"Skipping {distribution}: it is built but marked not to be uploaded.")
        return

    if carries_secret:
        print(
            f"Build secrets scan of dist/{distribution}: OK, but it carries "
            f"{', '.join(names)}, so it is not marked clean and a public repository "
            "does not upload it."
        )
        return
    clean_marker.touch()
    print(f"Build secrets scan of dist/{distribution}: OK, marked clean")


def compute_cross_product(dimensions: list[list[dict]]) -> list[dict]:
    """
    Compute the cross-product of multiple variant dimensions.

    Each dimension is a list of partial variant definitions. The cross-product
    concatenates suffixes, merges variables, and unions conditions.

    Args:
        dimensions: List of dimension arrays, each containing partial variant dicts

    Returns:
        List of fully-merged variant dicts
    """
    variants = []
    for combo in itertools.product(*dimensions):
        merged = {"suffix": "", "conditions": []}
        for part in combo:
            part = dict(part)  # avoid mutating original
            merged["suffix"] += part.pop("suffix", "")
            merged["conditions"] += part.pop("conditions", [])
            merged.update(part)
        variants.append(merged)
    return variants


def expand_variants(drivers_dir: Path) -> dict[str, list[str]]:
    """
    Expand driver template directories that contain a variants.json file.

    For each variant defined in variants.json (either as a flat "variants" list
    or a "dimensions" cross-product), copies the template directory to
    {driver_name}_{suffix}/ and replaces __VAR_NAME__ placeholders with
    variant-specific values. Variant-level conditions are processed via #ifdef
    directives. The original template directory is then removed.

    If variants.json contains a "pdf" key, a .variant_pdf marker file is
    written to each variant directory for downstream PDF consolidation.

    Args:
        drivers_dir: Path to the drivers directory in the build output

    Returns:
        Dict mapping template driver names to lists of generated variant names.
        e.g., {"esphome_fan": ["esphome_fan_1_speed", "esphome_fan_2_speed", ...]}
    """
    variant_map = {}

    for driver_dir in sorted(drivers_dir.iterdir()):
        if not driver_dir.is_dir():
            continue
        variants_file = driver_dir / "variants.json"
        if not variants_file.exists():
            continue

        with open(variants_file, "r", encoding="utf-8") as f:
            variants_config = json.load(f)

        # Support "dimensions" (cross-product) or flat "variants" list
        dimensions = variants_config.get("dimensions")
        if dimensions:
            variants = compute_cross_product(dimensions)
        else:
            variants = variants_config.get("variants", [])

        if not variants:
            continue

        pdf_name = variants_config.get("pdf")
        driver_name = driver_dir.name
        generated_names = []
        print(f"Expanding {len(variants)} variants for {driver_name}")

        # Separate empty-suffix variant from the rest. Non-empty suffixes must
        # be processed first (they copy from unmodified source). An empty-suffix
        # variant is processed last, in place.
        empty_suffix_variant = None
        suffixed_variants = []
        for variant in variants:
            if variant.get("suffix"):
                suffixed_variants.append(variant)
            else:
                empty_suffix_variant = variant

        # Process non-empty suffixes first (copy from clean source)
        for variant in suffixed_variants:
            suffix = variant.pop("suffix")
            conditions = set(variant.pop("conditions", []))
            variant_name = f"{driver_name}_{suffix}"
            variant_dir = drivers_dir / variant_name
            generated_names.append(variant_name)

            # Copy the template directory to the variant directory
            shutil.copytree(driver_dir, variant_dir)

            # Remove the variants.json from the copy
            (variant_dir / "variants.json").unlink()

            # Replace template variables and process variant conditions
            for root, _, files in os.walk(variant_dir):
                for filename in files:
                    file_path = Path(root) / filename
                    replace_template_variables(file_path, variant)
                    if conditions:
                        process_file(file_path, conditions, passthrough_unknown=True)

            # Write PDF marker if configured
            if pdf_name:
                (variant_dir / ".variant_pdf").write_text(pdf_name, encoding="utf-8")

            print(f"  Generated {variant_dir.name}")

        # Process empty-suffix variant last (in place) or remove original
        if empty_suffix_variant is not None:
            empty_suffix_variant.pop("suffix")
            conditions = set(empty_suffix_variant.pop("conditions", []))
            generated_names.insert(0, driver_name)
            (driver_dir / "variants.json").unlink(missing_ok=True)

            for root, _, files in os.walk(driver_dir):
                for filename in files:
                    file_path = Path(root) / filename
                    replace_template_variables(file_path, empty_suffix_variant)
                    if conditions:
                        process_file(file_path, conditions, passthrough_unknown=True)

            if pdf_name:
                (driver_dir / ".variant_pdf").write_text(pdf_name, encoding="utf-8")

            print(f"  Generated {driver_dir.name}")
        else:
            shutil.rmtree(driver_dir)

        variant_map[driver_name] = generated_names

    return variant_map


def process_directory(
    build_dir: Path, conditions: set[str], variant_map: dict[str, list[str]] = {}
):
    """
    Copy a directory and process all files for conditional directives.

    Args:
        build_dir: Build directory
        conditions: Set of enabled conditions
        variant_map: Dict mapping template names to generated variant names
    """
    # Copy and process all files and subdirectories
    for item in os.listdir(build_dir):
        build_item_path = build_dir / item

        if build_item_path.is_dir():
            # Recursively copy and process subdirectories
            process_directory(build_item_path, conditions, variant_map)
        else:
            # Process the file for conditional directives
            process_file(build_item_path, conditions, variant_map)


def main():
    parser = argparse.ArgumentParser(
        description="Build the project with conditional directives."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument(
        "--drivercentral", action="store_true", help="Enable DRIVERCENTRAL build"
    )
    group.add_argument(
        "--drivercentral-dev",
        action="store_true",
        help="Enable DRIVERCENTRAL + DRIVERCENTRAL_DEV build",
    )
    group.add_argument("--oss", action="store_true", help="Enable OSS build")
    parser.add_argument(
        "--scan",
        action="store_true",
        help="Scan the packaged dist/<distribution> for unresolved build secrets",
    )
    parser.add_argument(
        "--unresolved-secrets",
        choices=("fail", "skip"),
        default="fail",
        help="With --scan: fail on an unresolved secret, or mark it not to upload",
    )
    args = parser.parse_args()

    if args.drivercentral:
        distribution = "drivercentral"
        conditions = {"DRIVERCENTRAL"}
    elif args.drivercentral_dev:
        distribution = "drivercentral-dev"
        conditions = {"DRIVERCENTRAL", "DRIVERCENTRAL_DEV"}
    elif args.oss:
        distribution = "oss"
        conditions = {"OSS"}
    else:
        distribution = None
        conditions = set()
    assert distribution, "No distribution specified"

    # Define source and build directories
    repo_root = Path(__file__).parent.parent
    src_dir = repo_root / "src"
    drivers_dir = repo_root / "drivers"
    vendor_dir = repo_root / "vendor"
    documentation_dir = repo_root / "documentation"
    build_dir = repo_root / "build" / distribution

    takes_secrets = "DRIVERCENTRAL" in conditions
    if args.scan:
        load_dotenv(repo_root)
        scan_shipped_secrets(
            repo_root, distribution, takes_secrets, args.unresolved_secrets
        )
        return

    print(f"Building distribution: {distribution} (conditions: {conditions})")
    os.makedirs(build_dir, exist_ok=True)

    # Clean previous builds
    shutil.rmtree(build_dir / "src", ignore_errors=True)
    shutil.rmtree(build_dir / "drivers", ignore_errors=True)
    shutil.rmtree(build_dir / "vendor", ignore_errors=True)
    shutil.rmtree(build_dir / "documentation", ignore_errors=True)

    shutil.copytree(src_dir, build_dir / "src")
    shutil.copytree(drivers_dir, build_dir / "drivers")
    shutil.copytree(vendor_dir, build_dir / "vendor")

    # Copy documentation if present (optional)
    if documentation_dir.is_dir():
        shutil.copytree(documentation_dir, build_dir / "documentation")

    # Expand template variants before processing conditionals
    variant_map = expand_variants(build_dir / "drivers")

    # Copy and process src directory
    process_directory(build_dir, conditions, variant_map)

    # After the conditionals, so a placeholder in a stripped branch needs no value.
    if takes_secrets:
        substitute_secrets(build_dir, load_dotenv(repo_root))
    else:
        write_substituted_record(build_dir, set())

    print(f"Build completed successfully. Output in {build_dir}")


if __name__ == "__main__":
    main()
