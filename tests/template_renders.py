#!/usr/bin/env python3
"""The template renders: tests/template-renders/<name>.yml holds one render's non-default answers, on top of
tests/template-renders/fixtures.yml, and <name>.files is the list of files it renders. Every combination in
tests/template-renders/invalid/ must fail to render; a "# expect: <text>" first line names the error it must fail with.

Run with an interpreter that has copier (and so PyYAML), e.g. `uvx --from copier python tests/template_renders.py`.

    tests/template_renders.py                   make and check every template render, and check every invalid one fails
    tests/template_renders.py update            rewrite every <name>.files from a fresh render (make snapshots)
    tests/template_renders.py matrix            the render names, as JSON, for CI's matrix
    tests/template_renders.py render NAME DIR   a fresh render of NAME in DIR, replacing an earlier render there
    tests/template_renders.py example NAME DIR  add the example driver, with NAME's variants, to the render in DIR
    tests/template_renders.py check NAME DIR    check a render of NAME already in DIR
    tests/template_renders.py invalid           check every invalid combination fails
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
EXAMPLE_DRIVERS = ROOT / "example-driver" / "drivers"
RENDERS = ROOT / "tests" / "template-renders"
INVALID = RENDERS / "invalid"
FIXTURES = RENDERS / "fixtures.yml"


def names():
    return sorted(p.stem for p in RENDERS.glob("*.yml") if p != FIXTURES)


def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8")) or {}


def answers(path):
    merged = load(FIXTURES)
    merged.update(load(path))
    return merged


def render(data, dst):
    """Render the working tree, uncommitted edits included, as `copier copy --vcs-ref HEAD` does."""
    from copier import run_copy

    run_copy(str(ROOT), str(dst), data=data, defaults=True, vcs_ref="HEAD", unsafe=True, quiet=True)


def known(name):
    if name not in names():
        sys.exit(f"no render {name!r}: tests/template-renders has {', '.join(names())}")


def render_into(name, directory):
    directory = Path(directory)
    if directory.exists():
        if not (directory / ".copier-answers.yml").exists():
            sys.exit(f"{directory} is not a template render, so it is left alone")
        shutil.rmtree(directory)
    render(answers(RENDERS / f"{name}.yml"), directory)
    print(f"rendered {name} in {directory}")


def add_example(name, directory):
    """A render has no driver to build; example-driver/, outside template/ so never rendered, is one."""
    drivers = Path(directory) / "drivers"
    shutil.copytree(EXAMPLE_DRIVERS, drivers)
    variants = RENDERS / f"{name}.example-variants.json"
    if variants.exists():
        shutil.copy(variants, drivers / "example" / "variants.json")
    print(f"added the example driver to {directory}")
    # A driver the render's embedded_drivers puts in a host's package is a copy of the example, under its own name.
    for pair in answers(RENDERS / f"{name}.yml").get("embedded_drivers", "").split():
        for embedded in pair.split(":")[1].split(","):
            if (drivers / embedded).exists():
                continue
            shutil.copytree(drivers / "example", drivers / embedded)
            title = embedded.replace("_", " ").title()
            for file, old, new in (
                ("driver.c4zproj", 'name="example"', f'name="{embedded}"'),
                ("driver.xml", "<name>Example Driver</name>", f"<name>{title}</name>"),
                ("driver.xml", "<model>Example Driver</model>", f"<model>{title}</model>"),
            ):
                path = drivers / embedded / file
                text = path.read_text(encoding="utf-8")
                if old not in text:
                    sys.exit(f"{path} has no {old} to rename")
                path.write_text(text.replace(old, new, 1), encoding="utf-8")
            print(f"added {embedded}, a copy of the example driver, for {pair.split(':')[0]} to embed")


def file_list(directory):
    directory = Path(directory)
    return sorted(
        p.relative_to(directory).as_posix()
        for p in directory.rglob("*")
        if (p.is_file() or p.is_symlink()) and ".git" not in p.relative_to(directory).parts
    )


def snapshot(name):
    return RENDERS / f"{name}.files"


def drift(name, directory):
    """The snapshot's differences from the render, as +/- lines."""
    path = snapshot(name)
    want = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    got = file_list(directory)
    return [f"+ {f}" for f in got if f not in want] + [f"- {f}" for f in want if f not in got]


# Content checks. Each looks at the render and the answers it came from, never at a render's name.


def check_stale_workflow(data, directory):
    path = Path(directory) / ".github" / "workflows" / "stale.yml"
    if not data.get("stale_issues"):
        return []
    text = path.read_text(encoding="utf-8")
    problems = []
    if re.search(r"\{%|\{#|(^|[^$])\{\{", text, re.M):
        problems.append("stale.yml has unrendered Jinja")
    workflow = yaml.safe_load(text)
    condition = workflow["jobs"]["label-external"]["if"]
    exempt = re.search(r"fromJSON\('(.*)'\)", condition)
    want = str(data.get("stale_exempt_authors", "")).split()
    if not exempt or json.loads(exempt.group(1)) != want:
        problems.append(f"stale.yml exempts {exempt and exempt.group(1)}, want {json.dumps(want)}")
    step = workflow["jobs"]["stale"]["steps"][0]["with"]
    for key, answer, default in (
        ("days-before-issue-stale", "stale_days", 30),
        ("days-before-issue-close", "stale_close_days", 14),
    ):
        if step.get(key) != data.get(answer, default):
            problems.append(f"stale.yml {key} is {step.get(key)}, want {data.get(answer, default)}")
    return problems


def check_github_setup(data, directory):
    path = Path(directory) / "tools" / "github-setup"
    problems = []
    if not os.access(path, os.X_OK):
        problems.append("tools/github-setup is not executable")
    if f"NAME={data['project_name']}" not in path.read_text(encoding="utf-8").splitlines():
        problems.append(f"tools/github-setup does not set NAME={data['project_name']}")
    return problems


def check_upload_retention(data, directory):
    text = (Path(directory) / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")
    uploads = text.count("uses: actions/upload-artifact")
    retention = [line for line in text.splitlines() if "retention-days:" in line]
    counts = [
        len(retention),
        sum("github.ref_type == 'tag' && 14" in line for line in retention),
        sum("github.event_name == 'pull_request' && 1" in line for line in retention),
        sum("|| 3 }}" in line for line in retention),
    ]
    if uploads == 0 or any(n != uploads for n in counts):
        return [
            "every actions/upload-artifact step in build.yml needs retention-days naming the tag, pull request and "
            f"otherwise cases ({uploads} uploads, retention lines {counts})"
        ]
    skipped = text.count("if: always() && hashFiles('drivers/*/driver.xml') != ''")
    if skipped != uploads:
        return [f"every upload step in build.yml must skip a repo with no driver yet ({skipped} of {uploads} do)"]
    return []


def check_contributing(data, directory):
    text = (Path(directory) / "CONTRIBUTING.md").read_text(encoding="utf-8")
    has = "\n### Cloud Monitoring\n" in text
    if has != bool(data.get("cloud_diagnostics")):
        return [
            f"CONTRIBUTING.md's Cloud Monitoring section is {'there' if has else 'missing'} with cloud_diagnostics {data.get('cloud_diagnostics', False)}"
        ]
    return []


def check_build_secrets(data, directory):
    """tools/preprocess.py takes each declared secret from the environment, then .env, and prints no value."""
    with tempfile.TemporaryDirectory() as tmp:
        render_copy = Path(tmp) / "render"
        shutil.copytree(directory, render_copy, symlinks=True)
        probe = render_copy / "drivers" / "probe"
        probe.mkdir(parents=True, exist_ok=True)
        (probe / "driver.lua").write_text('A="__CI_SECRET_A__" B="__CI_SECRET_B__" D="__CI_SECRET_D__"\n')
        (render_copy / ".env.default").write_text("# CI probe\nCI_SECRET_A=\nCI_SECRET_B=\nCI_SECRET_D=\n")
        (render_copy / ".env").write_text("CI_SECRET_A=from-dotenv\nCI_SECRET_B=from-dotenv\n")
        env = {k: v for k, v in os.environ.items() if not k.startswith("CI_SECRET_") and k != "REQUIRE_SECRETS"}
        preprocess = [sys.executable, "tools/preprocess.py"]

        def run(args, **extra):
            return subprocess.run(
                preprocess + args, cwd=render_copy, env={**env, **extra}, capture_output=True, text=True
            )

        problems = []
        out = run(["--oss"], CI_SECRET_A="from-env")
        got = (render_copy / "build" / "oss" / "drivers" / "probe" / "driver.lua").read_text().strip()
        if got != 'A="from-env" B="from-dotenv" D=""':
            problems.append(f"build secrets substituted as {got}")
        if "from-" in out.stdout:
            problems.append("preprocess.py printed a secret's value")
        if "CI_SECRET_D is not set" not in out.stdout:
            problems.append("preprocess.py did not warn that CI_SECRET_D is not set")
        if run(["--oss"], REQUIRE_SECRETS="1").returncode == 0:
            problems.append("REQUIRE_SECRETS passed with CI_SECRET_D missing")
        if "/.env" not in (render_copy / ".gitignore").read_text().splitlines():
            problems.append(".gitignore does not ignore /.env")
        return problems


def check_named_secrets(data, directory):
    """build.yml passes each build secret by name, exactly the ones .env.default declares, and never toJSON(secrets)."""
    want = ["SUPPORT_CODE_SECRET", "SUPPORT_PHONE"] + (
        ["INFLUXDB_URL", "INFLUXDB_TOKEN", "INFLUXDB_METRICS_DB", "INFLUXDB_LOGS_DB"]
        if data.get("cloud_diagnostics")
        else []
    )
    want += [name for name in str(data.get("extra_build_secrets", "")).split() if name not in want]
    workflow = (Path(directory) / ".github" / "workflows" / "build.yml").read_text(encoding="utf-8")
    passed = re.findall(r"\$\{\{\s*secrets\.([A-Za-z_][A-Za-z0-9_]*)\s*\}\}", workflow)
    declared = re.findall(r"^([A-Z_][A-Z0-9_]*)=", (Path(directory) / ".env.default").read_text(encoding="utf-8"), re.M)
    problems = []
    if "toJSON(secrets)" in workflow:
        problems.append("build.yml hands toJSON(secrets) to a step")
    if sorted(passed) != sorted(want):
        problems.append(f"build.yml passes {sorted(passed)}, want {sorted(want)}")
    if sorted(declared) != sorted(want):
        problems.append(f".env.default declares {sorted(declared)}, want {sorted(want)}")
    check = subprocess.run(
        [sys.executable, "tools/preprocess.py", "--check-secrets"], cwd=directory, capture_output=True, text=True
    )
    if check.returncode != 0:
        problems.append(f"preprocess.py --check-secrets fails on the render: {check.stderr.strip()}")
    return problems


def check_icon_style(data, directory):
    want = data.get("icon_style", "shaped")
    lines = (Path(directory) / "Makefile").read_text(encoding="utf-8").splitlines()
    if f"ICON_STYLE ?= {want}" not in lines:
        return [f"the Makefile does not set ICON_STYLE ?= {want}"]
    return []


def check_product_id(data, directory):
    want = int(data.get("dc_pid", 0))
    lines = (Path(directory) / "src" / "lib" / "drivercentral.lua").read_text(encoding="utf-8").splitlines()
    if f"DriverCentral.PRODUCT_ID = {want}" not in lines:
        return [f"src/lib/drivercentral.lua does not set DriverCentral.PRODUCT_ID = {want}"]
    return []


CHECKS = [
    check_stale_workflow,
    check_github_setup,
    check_upload_retention,
    check_contributing,
    check_build_secrets,
    check_named_secrets,
    check_icon_style,
    check_product_id,
]


def check(name, directory):
    data = answers(RENDERS / f"{name}.yml")
    problems = [
        f"file list differs from tests/template-renders/{name}.files (make snapshots): {line}"
        for line in drift(name, directory)
    ]
    for fn in CHECKS:
        problems += fn(data, directory)
    return problems


def invalid_failures():
    """Each invalid combination's problem, if it rendered or failed for another reason."""
    problems = []
    for path in sorted(INVALID.glob("*.yml")):
        first = path.read_text(encoding="utf-8").splitlines()[0]
        expect = first[len("# expect:") :].strip() if first.startswith("# expect:") else None
        with tempfile.TemporaryDirectory() as tmp:
            try:
                render(answers(path), Path(tmp) / "render")
            except Exception as err:  # copier raises its own validation errors and ValueError
                if expect and expect not in str(err):
                    problems.append(f"invalid/{path.name} failed, but not with {expect!r}: {err}")
                continue
        problems.append(f"invalid/{path.name} rendered")
    return problems


class RendersTest(unittest.TestCase):
    def test_every_render_matches_its_snapshot_and_checks(self):
        for name in names():
            with self.subTest(render=name), tempfile.TemporaryDirectory() as tmp:
                render(answers(RENDERS / f"{name}.yml"), Path(tmp) / "render")
                self.assertEqual(check(name, Path(tmp) / "render"), [])

    def test_every_invalid_combination_fails(self):
        self.assertTrue(list(INVALID.glob("*.yml")), "tests/template-renders/invalid has no combinations")
        self.assertEqual(invalid_failures(), [])


def update():
    for name in names():
        with tempfile.TemporaryDirectory() as tmp:
            render(answers(RENDERS / f"{name}.yml"), Path(tmp) / "render")
            snapshot(name).write_text("\n".join(file_list(Path(tmp) / "render")) + "\n", encoding="utf-8")
        print(f"wrote tests/template-renders/{name}.files")


def main(argv):
    if not argv:
        unittest.main(argv=[sys.argv[0], "-v"])
    command = argv[0]
    if command == "update":
        update()
    elif command == "matrix":
        print(json.dumps(names()))
    elif command == "render" and len(argv) == 3:
        known(argv[1])
        render_into(argv[1], argv[2])
    elif command == "example" and len(argv) == 3:
        known(argv[1])
        add_example(argv[1], argv[2])
    elif command == "check" and len(argv) == 3:
        problems = check(argv[1], argv[2])
        for problem in problems:
            print(f"::error::{problem}")
        sys.exit(1 if problems else 0)
    elif command == "invalid":
        problems = invalid_failures()
        for problem in problems:
            print(f"::error::{problem}")
        sys.exit(1 if problems else 0)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
