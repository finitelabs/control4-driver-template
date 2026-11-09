#!/usr/bin/env python3
"""The checks CI's build leg runs in a template render that holds the example driver and has had
`make init` (make render render-example in-render-init). Run with an interpreter that has PyYAML,
e.g. `uvx --from copier python tests/build_checks.py CHECK DIR`.

    tests/build_checks.py driverless DIR        before its first driver, make build and make verify pass as no-ops
    tests/build_checks.py doc-alerts DIR        docs.py renders each GitHub alert as GitHub does, and fmt keeps it
    tests/build_checks.py idempotent DIR        make build, commit, make build: the second build changes nothing
    tests/build_checks.py readme-images DIR     README.md links an image, and every ./images/ link resolves
    tests/build_checks.py encrypted DIR         a build that substitutes a secret packages every distribution encrypted
    tests/build_checks.py cloud-monitoring DIR  Cloud Monitoring as CONTRIBUTING.md wires it reaches only DriverCentral
    tests/build_checks.py ui-page DIR           a page that embeds lib/ui ships it inline, in every distribution

encrypted, cloud-monitoring and ui-page each wire a probe into the example driver, run `make build-nodocs` with fake
secrets, and put the files they edit back afterwards. Neither depends on how those files are formatted.
"""

import contextlib
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from xml.etree import ElementTree


EXAMPLE = Path("drivers") / "example"
DISTRIBUTIONS = ["drivercentral", "oss"]
DIAGNOSTICS = Path("src") / "lib" / "diagnostics.lua"
UI_KIT = Path("src") / "lib" / "ui"
UI_PAGE = EXAMPLE / "www" / "html" / "index.html"
UI_PAGE_HTML = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
<!-- #embed ../../../../src/lib/ui/style.css -->
</style>
</head>
<body>
<div class="nav"><div class="nav-tab active" data-panel="status">Status</div></div>
<div class="panel active" id="panel-status"></div>
<script>
<!-- #embed ../../../../src/lib/ui/page.js -->
Kit.initTabs();
</script>
</body>
</html>
"""

EXAMPLE_SECRET = "EXAMPLE_SECRET"
EXAMPLE_SECRET_VALUE = "ci-secret-value"

CLOUD_MONITORING_PROPERTY = "Cloud Monitoring"
CLOUD_MONITORING_ACTION = "Diagnostics Snapshot"

# The build secrets CONTRIBUTING.md tells a driver to declare, each with a fake value nothing else in a build holds.
CLOUD_MONITORING_SECRETS = {
    "INFLUXDB_URL": "https://influx.example.test",
    "INFLUXDB_TOKEN": "ci-token-value",
    "INFLUXDB_METRICS_DB": "ci_metrics_db",
    "INFLUXDB_LOGS_DB": "ci_logs_db",
}

# The property, action, handlers and late-init wrap CONTRIBUTING.md's Cloud Monitoring section gives, in #ifdefs.
CLOUD_MONITORING_PROPERTY_XML = f"""
<!-- #ifdef DRIVERCENTRAL -->
<property>
  <name>{CLOUD_MONITORING_PROPERTY}</name>
  <type>LIST</type>
  <default>Enabled</default>
  <items>
    <item>Disabled</item>
    <item>Enabled</item>
  </items>
  <description>Sends memory and error reports to Finite Labs so we can fix driver problems.</description>
</property>
<!-- #endif -->"""

CLOUD_MONITORING_ACTIONS_XML = f"""
<!-- #ifdef DRIVERCENTRAL -->
<actions>
  <action>
    <name>{CLOUD_MONITORING_ACTION}</name>
    <command>DiagnosticsSnapshot</command>
  </action>
</actions>
<!-- #endif -->"""

CLOUD_MONITORING_LUA = """
--#ifdef DRIVERCENTRAL
local diagnostics = require("lib.diagnostics")

function OPC.Cloud_Monitoring(propertyValue)
  diagnostics:setEnabled(propertyValue == "Enabled")
end

function EC.DiagnosticsSnapshot()
  diagnostics:dumpSnapshot()
end

OnDriverLateInit = diagnostics:wrapLateInit(OnDriverLateInit)
--#endif
"""


def run(args, render, **env):
    """Run a command in the render, exiting with its status if it fails."""
    result = subprocess.run(args, cwd=render, env={**os.environ, **env})
    if result.returncode != 0:
        print(f"::error::{' '.join(args)} failed in {render}")
        sys.exit(result.returncode)


def packages(render, build):
    """Relative to the render, as messages name them."""
    return sorted(p.relative_to(render) for p in (render / "dist" / build / "c4z").glob("*.c4z"))


def members(render, c4z):
    """Each file in the package, by name."""
    with zipfile.ZipFile(render / c4z) as zf:
        return {name: zf.read(name) for name in zf.namelist() if not name.endswith("/")}


def parse(xml):
    try:
        return ElementTree.fromstring(xml)
    except ElementTree.ParseError:
        return None


def encryption_problems(c4z, files):
    """What keeps the package from holding its Lua encrypted, as the packager encrypts it."""
    root = parse(files.get("driver.xml", b""))
    problems = []
    if "driver.lua.encrypted" not in files:
        problems.append(f"{c4z} has no driver.lua.encrypted")
    if "driver.lua" in files:
        problems.append(f"{c4z} holds driver.lua in plain text")
    if root is None or root.find('config/script[@encryption="2"]') is None:
        problems.append(f"{c4z} driver.xml does not ask for encryption")
    return problems


def property_names(xml):
    root = parse(xml)
    return [] if root is None else [(p.findtext("name") or "").strip() for p in root.iter("property")]


def holds(files, pattern):
    return any(re.search(pattern, data) for data in files.values())


def alternatives(*words):
    return "|".join(re.escape(word) for word in words).encode()


def env_default(names):
    return "# CI probe\n" + "".join(f"{name}=\n" for name in names)


def insert_after(text, tag, snippet, path):
    """Put snippet right after the file's one tag, whatever its indentation or line breaks."""
    found = list(re.finditer(tag, text))
    if len(found) != 1:
        sys.exit(f"::error::the probe needs exactly one {tag} in {path}, which has {len(found)}")
    return text[: found[0].end()] + snippet + text[found[0].end() :]


@contextlib.contextmanager
def restored(render, *paths):
    """Put each path back as it was, or remove it if it was not there."""
    saved = {path: (render / path).read_bytes() if (render / path).exists() else None for path in paths}
    try:
        yield
    finally:
        for path, data in saved.items():
            if data is None:
                (render / path).unlink(missing_ok=True)
            else:
                (render / path).write_bytes(data)


def report(problems, passed):
    for problem in problems:
        print(f"::error::{problem}")
    if problems:
        return 1
    print(passed)
    return 0


def driverless(render):
    """A new repo has no driver until its first lands, and its build and CI must still pass."""
    if (render / "drivers").exists():
        return report(["the render already has drivers/, so this check tests nothing"], "")
    problems = []
    for target, says in (
        ("build", "nothing to build"),
        ("build-nodocs", "nothing to build"),
        ("verify", "nothing to verify"),
    ):
        result = subprocess.run(["make", target], cwd=render, capture_output=True, text=True)
        if result.returncode != 0:
            lines = (result.stdout + result.stderr).splitlines()
            why = next((line for line in reversed(lines) if "Error" in line), lines[-1] if lines else "")
            problems.append(f"make {target} fails with no drivers: {why.strip()[:200]}")
        elif says not in result.stdout:
            problems.append(f"make {target} with no drivers does not say {says}")
    if (render / "dist").exists():
        problems.append("make build with no drivers made dist/")
    return report(problems, "A repo with no driver yet builds and verifies nothing")


def doc_alerts(render):
    """The driver docs use GitHub's alerts, and nothing else checks how they render."""
    python = str(render / ".venv" / "bin" / "python3")
    kinds = ("NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION")
    problems = []
    with tempfile.TemporaryDirectory() as tmp:
        md = Path(tmp) / "index.md"
        md.write_text("# Alerts\n\n" + "\n".join(f"> [!{kind}]\n> A {kind.lower()} alert.\n" for kind in kinds))
        if (
            subprocess.run([python, "tools/docs.py", "fmt", "--check", "--wrap", "80", str(md)], cwd=render).returncode
            != 0
        ):
            problems.append("docs.py fmt would rewrite a GitHub alert")
        run([python, "tools/docs.py", "md2html", str(md), tmp], render)
        html = (Path(tmp) / "index.html").read_text(encoding="utf-8")
    for kind in kinds:
        if f"markdown-alert markdown-alert-{kind.lower()}" not in html:
            problems.append(f"a [!{kind}] alert does not render as an alert")
    titles = html.count('class="markdown-alert-title"')
    if titles != len(kinds):
        problems.append(f"the HTML has {titles} alert titles, want {len(kinds)}")
    if "[!" in html:
        problems.append("an alert's [!KIND] marker shows as text")
    return report(problems, f"docs.py renders all {len(kinds)} GitHub alerts")


def idempotent(render):
    run(["git", "init", "-q"], render)
    run(["git", "config", "user.email", "ci@example.com"], render)
    run(["git", "config", "user.name", "ci"], render)
    run(["make", "build"], render)
    run(["git", "add", "-A"], render)
    run(["git", "commit", "-q", "-m", "first build"], render)
    run(["make", "build"], render)
    if subprocess.run(["make", "verify-clean"], cwd=render).returncode != 0:
        return report(["make build is not idempotent: the second build changed the tree"], "")
    print("make build is idempotent")
    return 0


def readme_images(render):
    """A README image that docs-readme failed to copy breaks nothing else in the build."""
    readme = render / "README.md"
    refs = sorted(set(re.findall(rb'\./images/[^")\s]+', readme.read_bytes() if readme.is_file() else b"")))
    if not refs:
        return report(["README.md links no images, so this check tests nothing"], "")
    missing = [os.fsdecode(ref) for ref in refs if not (render / os.fsdecode(ref)).is_file()]
    return report(
        [f"README.md links {ref}, which does not exist" for ref in missing], f"README.md's {len(refs)} images resolve"
    )


def encrypted(render):
    problems = []
    with restored(render, Path(".env.default"), EXAMPLE / "driver.lua"):
        (render / ".env.default").write_text(env_default([EXAMPLE_SECRET]))
        with open(render / EXAMPLE / "driver.lua", "a") as lua:
            lua.write(f'\nEXAMPLE_BUILD_SECRET = "__{EXAMPLE_SECRET}__"\n')
        run(["make", "build-nodocs"], render, **{EXAMPLE_SECRET: EXAMPLE_SECRET_VALUE})
        for build in DISTRIBUTIONS:
            if not packages(render, build):
                problems.append(f"the {build} build made no package")
            for c4z in packages(render, build):
                files = members(render, c4z)
                problems += encryption_problems(c4z, files)
                if holds(files, alternatives(EXAMPLE_SECRET_VALUE)):
                    problems.append(f"{c4z} holds the secret in plain text")
            if (render / "dist" / build / "source").exists():
                problems.append(f"dist/{build}/source was kept with a secret in it")
    return report(problems, "A build with a secret is encrypted in every distribution")


def cloud_monitoring(render):
    if not (render / DIAGNOSTICS).is_file():
        print("This render has no lib.diagnostics.")
        return 0
    secrets = CLOUD_MONITORING_SECRETS
    values = alternatives(*secrets.values())
    traces = alternatives(
        "lib.diagnostics", CLOUD_MONITORING_PROPERTY, CLOUD_MONITORING_ACTION, *secrets, *secrets.values()
    )
    problems = []
    with restored(render, Path(".env.default"), EXAMPLE / "driver.xml", EXAMPLE / "driver.lua"):
        (render / ".env.default").write_text(env_default(secrets))
        xml_path = render / EXAMPLE / "driver.xml"
        xml = xml_path.read_text(encoding="utf-8")
        if re.search(r"<actions[\s>/]", xml):
            sys.exit(f"::error::the probe adds <actions>, and {EXAMPLE / 'driver.xml'} already has one")
        xml = insert_after(xml, r"<properties\s*>", CLOUD_MONITORING_PROPERTY_XML, EXAMPLE / "driver.xml")
        xml = insert_after(xml, r"</properties\s*>", CLOUD_MONITORING_ACTIONS_XML, EXAMPLE / "driver.xml")
        xml_path.write_text(xml, encoding="utf-8")
        with open(render / EXAMPLE / "driver.lua", "a") as lua:
            lua.write(CLOUD_MONITORING_LUA)
        run(["make", "build-nodocs"], render, **secrets)
        for build in DISTRIBUTIONS:
            if not packages(render, build):
                problems.append(f"the {build} build made no package")
            for c4z in packages(render, build):
                files = members(render, c4z)
                if build.startswith("drivercentral"):
                    problems += encryption_problems(c4z, files)
                    if CLOUD_MONITORING_PROPERTY not in property_names(files.get("driver.xml", b"")):
                        problems.append(f"{c4z} has no {CLOUD_MONITORING_PROPERTY} property")
                    if holds(files, values):
                        problems.append(f"{c4z} holds a secret in plain text")
                else:
                    if "driver.lua" not in files or "driver.lua.encrypted" in files:
                        problems.append(f"{c4z} is encrypted: a Cloud Monitoring secret reached the {build} build")
                    if holds(files, traces):
                        problems.append(f"{c4z} carries Cloud Monitoring")
            built = render / "build" / build / DIAGNOSTICS
            if build.startswith("drivercentral"):
                text = built.read_text(encoding="utf-8") if built.is_file() else ""
                for name, value in secrets.items():
                    if value not in text:
                        problems.append(f"the {build} build did not substitute {name} into {DIAGNOSTICS}")
                # A placeholder no declared secret replaced: the library and CONTRIBUTING.md disagree.
                for left in sorted(set(re.findall(r"__[A-Z][A-Z0-9_]*__", text))):
                    problems.append(f"the {build} build left {left} in {DIAGNOSTICS}")
    return report(problems, "Cloud Monitoring: DriverCentral encrypted with the values, OSS plain without it")


def ui_page(render):
    if not (render / UI_KIT).is_dir():
        print("This render has no lib/ui.")
        return 0
    kit = {name: (render / UI_KIT / name).read_text(encoding="utf-8") for name in ("style.css", "page.js")}
    problems = []
    with restored(render, UI_PAGE):
        (render / UI_PAGE).parent.mkdir(parents=True, exist_ok=True)
        (render / UI_PAGE).write_text(UI_PAGE_HTML, encoding="utf-8")
        # The render's own page test finds the probe and resolves its embeds.
        run(["test/run_test.sh", "test_ui_pages.lua"], render)
        run(["make", "build-nodocs"], render)
        for build in DISTRIBUTIONS:
            if not packages(render, build):
                problems.append(f"the {build} build made no package")
            for c4z in packages(render, build):
                page = members(render, c4z).get("www/html/index.html", b"").decode("utf-8")
                if not page:
                    problems.append(f"{c4z} has no www/html/index.html")
                    continue
                if re.search(r"^\s*<!--\s*#embed\s", page, re.MULTILINE):
                    problems.append(f"{c4z}'s page still holds an #embed line")
                for name, text in kit.items():
                    if text.strip() not in page:
                        problems.append(f"{c4z}'s page does not hold {name} whole")
    return report(problems, "A page that embeds lib/ui ships style.css and page.js inline in every distribution")


CHECKS = {
    "doc-alerts": doc_alerts,
    "driverless": driverless,
    "idempotent": idempotent,
    "readme-images": readme_images,
    "encrypted": encrypted,
    "cloud-monitoring": cloud_monitoring,
    "ui-page": ui_page,
}


def main(argv):
    if len(argv) != 2 or argv[0] not in CHECKS:
        sys.exit(__doc__)
    sys.exit(CHECKS[argv[0]](Path(argv[1]).resolve()))


if __name__ == "__main__":
    main(sys.argv[1:])
