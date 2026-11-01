#!/usr/bin/env python3
"""The checks CI's build leg runs in a template render that holds the example driver and has
had `make init` (make render render-example in-render-init). Run with an interpreter that has
PyYAML, e.g. `uvx --from copier python tests/build_checks.py CHECK DIR`.

    tests/build_checks.py idempotent DIR        make build, commit, make build: the second build changes nothing
    tests/build_checks.py readme-images DIR     README.md links an image, and every ./images/ link resolves
    tests/build_checks.py encrypted DIR         a build that substitutes a secret packages every distribution encrypted
    tests/build_checks.py cloud-monitoring DIR  Cloud Monitoring, wired as CONTRIBUTING.md says, reaches only DriverCentral

encrypted and cloud-monitoring each run `make build-nodocs` with probe edits and fake secrets,
and put the files they edit back afterwards.
"""

import contextlib
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

import yaml

EXAMPLE = Path("drivers") / "example"

CLOUD_MONITORING_PROPERTY = """\
    <properties>
      <!-- #ifdef DRIVERCENTRAL -->
      <property>
        <name>Cloud Monitoring</name>
        <type>LIST</type>
        <default>Enabled</default>
        <items>
          <item>Disabled</item>
          <item>Enabled</item>
        </items>
      </property>
      <!-- #endif -->
"""

CLOUD_MONITORING_ACTION = """\
    </properties>
    <!-- #ifdef DRIVERCENTRAL -->
    <actions>
      <action>
        <name>Diagnostics Snapshot</name>
        <command>DiagnosticsSnapshot</command>
      </action>
    </actions>
    <!-- #endif -->
"""

CLOUD_MONITORING_LUA = """
--#ifdef DRIVERCENTRAL
local diagnostics = require("lib.diagnostics")
function OPC.Cloud_Monitoring(propertyValue)
  diagnostics:setEnabled(propertyValue == "Enabled")
end
function EC.DiagnosticsSnapshot()
  diagnostics:dumpSnapshot()
end
--#endif
"""

CLOUD_MONITORING_SECRETS = {
    "INFLUXDB_URL": "https://influx.example.test",
    "INFLUXDB_TOKEN": "ci-token-value",
    "INFLUXDB_METRICS_DB": "ci_metrics_db",
    "INFLUXDB_LOGS_DB": "ci_logs_db",
}
SECRET_VALUES = rb"ci-token-value|ci_metrics_db|ci_logs_db"
CLOUD_MONITORING_TRACES = (
    rb"lib\.diagnostics|Cloud Monitoring|Diagnostics Snapshot|INFLUXDB_(URL|TOKEN|METRICS_DB|LOGS_DB)"
    rb"|influx\.example|ci-token-value|ci_metrics_db|ci_logs_db"
)


def run(args, render, **env):
    """Run a command in the render, exiting with its status if it fails."""
    result = subprocess.run(args, cwd=render, env={**os.environ, **env})
    if result.returncode != 0:
        print(f"::error::{' '.join(args)} failed in {render}")
        sys.exit(result.returncode)


def distributions(render):
    answers = yaml.safe_load((render / ".copier-answers.yml").read_text(encoding="utf-8"))
    return str(answers["distributions"]).split()


def packages(render, build):
    """Relative to the render, as messages name them."""
    return sorted(p.relative_to(render) for p in (render / "dist" / build / "c4z").glob("*.c4z"))


def contains(directory, pattern):
    """grep -raqE: does any file under directory match pattern."""
    return any(p.is_file() and re.search(pattern, p.read_bytes()) for p in directory.rglob("*"))


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


def idempotent(render):
    run(["git", "init", "-q"], render)
    run(["git", "config", "user.email", "ci@example.com"], render)
    run(["git", "config", "user.name", "ci"], render)
    run(["make", "build"], render)
    run(["git", "add", "-A"], render)
    run(["git", "commit", "-q", "-m", "first build"], render)
    run(["make", "build"], render)
    if subprocess.run(["make", "verify-clean"], cwd=render).returncode != 0:
        print("::error::make build is not idempotent: the second build changed the tree")
        return 1
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
        (render / ".env.default").write_text("# CI probe\nEXAMPLE_SECRET=\n")
        with open(render / EXAMPLE / "driver.lua", "a") as lua:
            lua.write('\nEXAMPLE_BUILD_SECRET = "__EXAMPLE_SECRET__"\n')
        run(["make", "build-nodocs"], render, EXAMPLE_SECRET="ci-secret-value")
        for build in distributions(render):
            if not packages(render, build):
                problems.append(f"the {build} build made no package")
            for c4z in packages(render, build):
                with zipfile.ZipFile(render / c4z) as zf:
                    names = zf.namelist()
                    if not any("driver.lua.encrypted" in name for name in names):
                        problems.append(f"{c4z} has no driver.lua.encrypted")
                    if "driver.xml" not in names or b'encryption="2"' not in zf.read("driver.xml"):
                        problems.append(f"{c4z} driver.xml does not ask for encryption")
                    if any(b"ci-secret-value" in zf.read(name) for name in names):
                        problems.append(f"{c4z} holds the secret in plain text")
            if (render / "dist" / build / "source").exists():
                problems.append(f"dist/{build}/source was kept with a secret in it")
    return report(problems, "A build with a secret is encrypted in every distribution")


def cloud_monitoring(render):
    if not (render / "src" / "lib" / "diagnostics.lua").is_file():
        print("This render has no lib.diagnostics.")
        return 0
    problems = []
    with restored(render, Path(".env.default"), EXAMPLE / "driver.xml", EXAMPLE / "driver.lua"):
        (render / ".env.default").write_text(
            "# CI probe\nINFLUXDB_URL=\nINFLUXDB_TOKEN=\nINFLUXDB_METRICS_DB=\nINFLUXDB_LOGS_DB=\n"
        )
        xml = render / EXAMPLE / "driver.xml"
        s = xml.read_text()
        s = s.replace("    <properties>\n", CLOUD_MONITORING_PROPERTY, 1)
        s = s.replace("    </properties>\n", CLOUD_MONITORING_ACTION, 1)
        xml.write_text(s)
        with open(render / EXAMPLE / "driver.lua", "a") as lua:
            lua.write(CLOUD_MONITORING_LUA)
        run(["make", "build-nodocs"], render, **CLOUD_MONITORING_SECRETS)
        for build in distributions(render):
            if not packages(render, build):
                problems.append(f"the {build} build made no package")
            for c4z in packages(render, build):
                with tempfile.TemporaryDirectory() as tmp:
                    unpacked = Path(tmp)
                    with zipfile.ZipFile(render / c4z) as zf:
                        zf.extractall(unpacked)
                    if build.startswith("drivercentral"):
                        if not (unpacked / "driver.lua.encrypted").is_file() or (unpacked / "driver.lua").exists():
                            problems.append(f"{c4z} is not encrypted")
                        driver_xml = unpacked / "driver.xml"
                        if not driver_xml.is_file() or b"<name>Cloud Monitoring</name>" not in driver_xml.read_bytes():
                            problems.append(f"{c4z} has no Cloud Monitoring property")
                        if contains(unpacked, SECRET_VALUES):
                            problems.append(f"{c4z} holds a secret in plain text")
                    else:
                        if not (unpacked / "driver.lua").is_file() or (unpacked / "driver.lua.encrypted").exists():
                            problems.append(f"{c4z} is encrypted: a Cloud Monitoring secret reached the {build} build")
                        if contains(unpacked, CLOUD_MONITORING_TRACES):
                            problems.append(f"{c4z} carries Cloud Monitoring")
        diagnostics = render / "build" / "drivercentral" / "src" / "lib" / "diagnostics.lua"
        if not diagnostics.is_file() or b'local INFLUXDB_TOKEN = "ci-token-value"' not in diagnostics.read_bytes():
            problems.append("the DriverCentral build did not substitute the token")
    return report(problems, "Cloud Monitoring: DriverCentral encrypted with the values, OSS plain without it")


CHECKS = {
    "idempotent": idempotent,
    "readme-images": readme_images,
    "encrypted": encrypted,
    "cloud-monitoring": cloud_monitoring,
}


def main(argv):
    if len(argv) != 2 or argv[0] not in CHECKS:
        sys.exit(__doc__)
    sys.exit(CHECKS[argv[0]](Path(argv[1]).resolve()))


if __name__ == "__main__":
    main(sys.argv[1:])
