#!/usr/bin/env python3
"""Build, lint and run native tests on dedicated iPhone and iPad simulators."""

import argparse
import codecs
import concurrent.futures
import json
import os
import plistlib
import re
import selectors
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SIMULATORS = {
    "iPhone": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
    "iPad": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
    "iPhoneDuo": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
}
TEST_TARGETS = {"unit": "MarkdownItTests", "ui": "MarkdownItUITests"}
TEST_PLANS = ROOT / "MarkdownIt.xcodeproj/xcshareddata/xctestplans"


def validate_test_plan(live=False):
    """Each shared plan must enable every test in its complete set of targets."""
    plan = json.loads((TEST_PLANS / ("Live.xctestplan" if live else "Full.xctestplan")).read_text())
    targets = plan["testTargets"]
    expected = {"MarkdownItLiveTests"} if live else set(TEST_TARGETS.values())
    if len(targets) != len(expected) or {item["target"]["name"] for item in targets} != expected:
        raise ValueError("The test plan must contain all requested targets")
    for target in targets:
        if (
            target.get("enabled") is False
            or target.get("skippedTests")
            or "selectedTests" in target
        ):
            raise ValueError("The offline test plan must run every test")


def test_run_specification(products, live=False):
    """Reject prebuilt products that silently narrow the full test plan."""
    specifications = list(products.glob("*.xctestrun"))
    if len(specifications) != 1:
        raise ValueError("Test products must contain exactly one .xctestrun specification")
    specification = specifications[0]
    metadata = plistlib.loads(specification.read_bytes())
    plan = "Live" if live else "Full"
    if metadata.get("TestPlan", {}).get("Name") != plan:
        raise ValueError(f"Test products must be built with the {plan} test plan")
    configurations = metadata.get("TestConfigurations")
    if not configurations or any(not item.get("IsEnabled") for item in configurations):
        raise ValueError("Compiled test configurations must all be enabled")
    for configuration in configurations:
        targets = configuration["TestTargets"]
        expected = {"MarkdownItLiveTests"} if live else set(TEST_TARGETS.values())
        if (
            len(targets) != len(expected)
            or {target["BlueprintName"] for target in targets} != expected
        ):
            raise ValueError("Compiled test products must contain all requested targets")
        if any(
            target.get("SkipTestIdentifiers") or "OnlyTestIdentifiers" in target
            for target in targets
        ):
            raise ValueError("Compiled test products must run every test")
    return specification


def validate_test_product_signatures(specification):
    """Reject linker-only signatures before installing a Keychain-using app."""
    metadata = plistlib.loads(specification.read_bytes())
    bundles = set()
    for configuration in metadata["TestConfigurations"]:
        for target in configuration["TestTargets"]:
            host = target["TestHostPath"].replace("__TESTROOT__", str(specification.parent))
            for key in ["TestHostPath", "TestBundlePath", "UITargetAppPath"]:
                if key not in target:
                    continue
                path = target[key].replace("__TESTHOST__", host)
                path = path.replace("__TESTROOT__", str(specification.parent))
                bundles.add(Path(path))
    for bundle in sorted(bundles):
        try:
            run(["codesign", "--verify", "--strict", str(bundle)], capture_output=True)
        except subprocess.CalledProcessError as error:
            raise ValueError(
                f"Invalid code signature: {bundle.name}. Rebuild with verify_ios.py; "
                "do not disable code signing for simulator tests."
            ) from error


def test_case_selector(value):
    """Accept explicit offline test methods, never exclusion or target overrides."""
    if not re.fullmatch(
        r"(MarkdownItTests|MarkdownItUITests)/[A-Za-z_]\w*/test\w+(?:\(\))?", value
    ):
        raise argparse.ArgumentTypeError("Use Target/TestClass/testMethod for an offline test")
    return value.removesuffix("()")


def run(arguments, **options):
    return subprocess.run(arguments, cwd=ROOT, check=True, **options)


def start_simulator_client():
    """Initialize simulator input services before running onscreen-keyboard checks."""
    developer = Path(run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip())
    client = developer.parent / "Applications/DeviceHub.app"
    if not client.is_dir():
        raise ValueError(f"Missing simulator client: {client}. Use Xcode 27.1 or newer.")
    process_prefix = "^" + re.escape(str(client / "Contents/MacOS")) + "/"
    run(["open", "-g", "-j", "-a", str(client)])
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if (
            subprocess.run(
                ["pgrep", "-f", process_prefix],
                stdout=subprocess.DEVNULL,
                check=False,
            ).returncode
            == 0
        ):
            print("Device Hub is running in the background for simulator input.", flush=True)
            return
        time.sleep(0.1)
    raise ValueError("Device Hub did not start; simulator input is not ready for testing.")


def simulator_data(kind):
    return json.loads(
        run(
            ["xcrun", "simctl", "list", kind, "available", "-j"],
            capture_output=True,
            text=True,
        ).stdout
    )


def compatible_runtime(family, runtimes):
    """Duo-only runtimes must not be paired with a conventional phone or iPad."""
    compatible = [
        runtime
        for runtime in runtimes
        if SIMULATORS[family]
        in {item["identifier"] for item in runtime.get("supportedDeviceTypes", [])}
    ]
    if not compatible:
        raise ValueError(f"Install a simulator runtime supporting {family} in Xcode.")
    return max(compatible, key=lambda item: tuple(map(int, item["version"].split("."))))


class TestProgress:
    """Retain the first failed XCTest synchronization boundary, including split output."""

    def __init__(self):
        self.pending = ""
        self.test = None
        self.action = None

    def feed(self, text):
        self.pending += text
        lines = self.pending.split("\n")
        self.pending = lines.pop()
        for line in lines:
            started = re.search(r"Test Case '(.+)' started\.", line)
            if started:
                self.test = started[1]
                self.action = None
            if "App animations complete notification not received" in line:
                return {"test": self.test, "action": self.action, "warning": line.strip()}
            if re.search(r"t =\s*[\d.]+s\s", line):
                self.action = line.strip()
        return None


def run_tests(arguments, log, inactivity_timeout=600, cancel=None, label=None, on_stall=None):
    """Stream Xcode output while preserving a complete log and detecting silence."""
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    progress = TestProgress()
    with (
        log.open("wb") as stream,
        subprocess.Popen(
            arguments,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        ) as process,
        selectors.DefaultSelector() as selector,
    ):
        selector.register(process.stdout, selectors.EVENT_READ)
        completed = False
        last_output = time.monotonic()

        def display(value):
            if label:
                value = "".join(f"[{label}] {line}" for line in value.splitlines(keepends=True))
            print(value, end="", flush=True)

        try:
            while True:
                if cancel is not None and cancel.is_set():
                    return 130
                if time.monotonic() - last_output >= inactivity_timeout:
                    message = (
                        f"\nNo Xcode output for {inactivity_timeout} seconds; "
                        "interrupting the test process and retaining diagnostics.\n"
                    )
                    stream.write(message.encode())
                    stream.flush()
                    print(message, end="", flush=True)
                    return 1
                if not selector.select(timeout=min(1, inactivity_timeout)):
                    continue
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                last_output = time.monotonic()
                stream.write(chunk)
                stream.flush()
                text = decoder.decode(chunk)
                display(text)
                stalled = progress.feed(text)
                if stalled is not None and on_stall is not None:
                    print(
                        "XCTest failed to synchronize animations; capturing the first stalled "
                        "operation before interrupting this failed run.",
                        flush=True,
                    )
                    on_stall(stalled)
                    return 1
            display(decoder.decode(b"", final=True))
            try:
                code = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                print("Xcode closed its output without exiting; interrupting tests.", flush=True)
                return 1
            completed = True
            return code
        finally:
            if not completed:
                # SIGINT lets Xcode finish its result bundle before a forced stop.
                try:
                    os.killpg(process.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                try:
                    remaining, _ = process.communicate(timeout=30)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    remaining, _ = process.communicate()
                if remaining:
                    stream.write(remaining)
                    stream.flush()
                    display(decoder.decode(remaining, final=True))


def stall_details(device, output, context):
    """Sample the live app and runner before cancellation destroys the failed state."""
    (output / f"{device}-stall.json").write_text(json.dumps(context, indent=2) + "\n")
    try:
        processes = subprocess.run(
            ["xcrun", "simctl", "spawn", device, "launchctl", "list"],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        ).stdout
        for line in processes.splitlines():
            columns = line.split()
            if (
                len(columns) < 3
                or not columns[0].isdigit()
                or "UIKitApplication:dev.catli.MarkdownIt" not in columns[2]
            ):
                continue
            pid = columns[0]
            subprocess.run(
                ["/usr/bin/sample", pid, "2", "-file", str(output / f"{device}-{pid}.sample.log")],
                capture_output=True,
                timeout=8,
                check=False,
            )
    except (OSError, subprocess.SubprocessError) as error:
        print(f"Unable to sample the stalled test: {type(error).__name__}", flush=True)


def failure_details(bundle, device, output):
    summary = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if summary.returncode == 0:
        for failure in json.loads(summary.stdout).get("testFailures", []):
            print(f"{failure['testName']}: {failure['failureText']}", flush=True)
    # Collect the app's document error domains and codes without document contents or credentials.
    diagnostics = output / f"{device}-documents.log"
    try:
        with diagnostics.open("w") as stream:
            subprocess.run(
                [
                    "xcrun",
                    "simctl",
                    "spawn",
                    device,
                    "log",
                    "show",
                    "--style",
                    "compact",
                    "--last",
                    "45m",
                    "--predicate",
                    'subsystem == "dev.catli.MarkdownIt" AND category == "Documents"',
                ],
                stdout=stream,
                stderr=subprocess.STDOUT,
                timeout=30,
                check=False,
            )
        print(diagnostics.read_text(errors="replace"), flush=True)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"Unable to collect document diagnostics: {type(error).__name__}", flush=True)


def test_summary(bundle, expected_targets, expected_cases=()):
    """Require every requested offline test to execute; skips fail verification."""
    try:
        summary = json.loads(
            run(
                ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)],
                capture_output=True,
                text=True,
            ).stdout
        )
        counts = {
            key: summary[key]
            for key in ["totalTestCount", "passedTests", "failedTests", "skippedTests"]
        }
        if not all(type(value) is int and value >= 0 for value in counts.values()):
            raise ValueError("Invalid test counts")
        if summary.get("expectedFailures", 0):
            raise ValueError("Expected failures require explicit maintainer approval")
        tree = json.loads(
            run(
                ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)],
                capture_output=True,
                text=True,
            ).stdout
        )
        bundles = [
            node
            for root in tree["testNodes"]
            for node in root.get("children", [])
            if node.get("nodeType") in {"Unit test bundle", "UI test bundle"}
        ]
        if {node["name"] for node in bundles} != set(expected_targets):
            raise ValueError("XCTest did not execute every requested target")
        executed = set()

        def collect(node, target):
            if node.get("nodeType") == "Test Case":
                executed.add(f"{target}/{node['nodeIdentifier'].removesuffix('()')}")
            for child in node.get("children", []):
                collect(child, target)

        for bundle_node in bundles:
            collect(bundle_node, bundle_node["name"])
        if not set(expected_cases).issubset(executed):
            raise ValueError("XCTest did not execute every requested test case")
    except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
        print(f"Unable to verify XCTest results: {type(error).__name__}", flush=True)
        return None
    if counts["skippedTests"]:
        print(
            f"Verification incomplete: {counts['skippedTests']} test(s) were skipped.", flush=True
        )
    return counts


def verify_family(
    family,
    runtime,
    devices,
    specification,
    output,
    suite,
    prefix,
    cancel,
    test_cases=(),
    live=False,
):
    """Execute one explicit test scope on a dedicated simulator."""
    started = time.monotonic()
    name = f"{prefix} {family}"
    device = next((item for item in devices if item["name"] == name), None)
    if device is None:
        identifier = run(
            ["xcrun", "simctl", "create", name, SIMULATORS[family], runtime["identifier"]],
            capture_output=True,
            text=True,
        ).stdout.strip()
        device = {"udid": identifier, "state": "Shutdown"}
    identifier = device["udid"]
    print(f"{family}: preparing simulator {identifier} on {runtime['name']}", flush=True)
    if device["state"] != "Booted":
        run(["xcrun", "simctl", "boot", identifier])
    boot = run(["xcrun", "simctl", "bootstatus", identifier, "-b"], capture_output=True, text=True)
    print(boot.stdout, end="", flush=True)
    if "Data Migration Failed" in boot.stdout:
        raise ValueError("Simulator data migration failed; the test environment is not ready")
    preparation_seconds = time.monotonic() - started
    print(f"{family}: simulator ready after {preparation_seconds:.1f}s", flush=True)
    bundle = output / f"{family}.xcresult"
    log = output / f"{family}.log"
    selected = (
        list(dict.fromkeys(test_cases))
        if test_cases
        else ["MarkdownItLiveTests"]
        if live
        else list(TEST_TARGETS.values())
        if suite == "all"
        else [TEST_TARGETS[suite]]
    )
    scope = "live" if live else "targeted" if test_cases else suite
    print(f"{family}: running {scope}: {', '.join(selected)}", flush=True)
    started = time.monotonic()
    code = run_tests(
        [
            "xcodebuild",
            "test-without-building",
            "-xctestrun",
            str(specification),
            "-destination",
            f"platform=iOS Simulator,id={identifier}",
            "-resultBundlePath",
            str(bundle),
            "-parallel-testing-enabled",
            "NO",
            "-test-timeouts-enabled",
            "YES",
            "-collect-test-diagnostics",
            "never",
            *[f"-only-testing:{target}" for target in selected],
        ],
        log,
        cancel=cancel,
        label=family,
        on_stall=lambda context: stall_details(identifier, output, context),
    )
    execution_seconds = time.monotonic() - started
    counts = test_summary(
        bundle, {item.split("/")[0] for item in selected}, expected_cases=test_cases
    )
    passed = (
        code == 0
        and counts is not None
        and counts["totalTestCount"] > 0
        and counts["passedTests"] == counts["totalTestCount"]
        and counts["failedTests"] == 0
        and counts["skippedTests"] == 0
    )
    print(
        f"{family}: {'passed' if passed else 'failed'} after {execution_seconds:.1f}s", flush=True
    )
    if not passed:
        failure_details(bundle, identifier, output)
    return {
        "family": family,
        "device": identifier,
        "runtime": runtime["name"],
        "passed": passed,
        "testCounts": counts,
        "suite": suite,
        "scope": scope,
        "testPlan": "Live" if live else "Full",
        "preparationSeconds": round(preparation_seconds, 1),
        "executionSeconds": round(execution_seconds, 1),
        "testSelectors": selected,
        "resultBundle": str(bundle),
        "log": str(log),
    }


def verify_families(families, **options):
    """Run each family once; a failure must not suppress the other family's result."""
    results = {}

    def verify(family):
        selected = dict(options)
        if "runtimes" in selected:
            runtime = compatible_runtime(family, selected.pop("runtimes"))
            selected["runtime"] = runtime
            selected["devices"] = selected.pop("devices_by_runtime").get(runtime["identifier"], [])
        return verify_family(family, **selected)

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(families)) as executor:
        futures = {executor.submit(verify, family): family for family in families}
        for future in concurrent.futures.as_completed(futures):
            family = futures[future]
            try:
                results[family] = future.result()
            except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
                print(f"{family}: verification failed: {error}", flush=True)
                results[family] = {"family": family, "passed": False, "error": str(error)}
    return [results[family] for family in families]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", choices=SIMULATORS, help="Verify one simulator family")
    parser.add_argument(
        "--output", type=Path, help="Directory for disposable build and test artifacts"
    )
    parser.add_argument("--test-products", type=Path, help="Use prebuilt simulator test products")
    parser.add_argument("--suite", choices=["all", *TEST_TARGETS], default="all")
    parser.add_argument("--runtime", help="Use an explicitly installed iOS version for comparison")
    parser.add_argument(
        "--test-case",
        type=test_case_selector,
        action="append",
        default=[],
        help="Run an explicit test method for diagnosis; repeat for multiple methods",
    )
    parser.add_argument(
        "--simulator-prefix", default="MarkdownIt", help="Name prefix for dedicated simulators"
    )
    parser.add_argument(
        "--live-config",
        type=Path,
        help="Explicitly run the separate real-service target using a private external JSON configuration",
    )
    args = parser.parse_args()
    if args.live_config:
        if args.test_case or args.suite != "all" or args.test_products:
            parser.error("Live verification runs its complete target with a fresh signed build")
        args.live_config = args.live_config.expanduser().resolve()
        if not args.live_config.is_file() or args.live_config.stat().st_mode & 0o077:
            parser.error("Live configuration must be an existing private file (0600)")
    if not args.simulator_prefix.strip():
        parser.error("simulator-prefix must not be empty")
    if args.test_case and args.suite != "all":
        parser.error("Use either --test-case or --suite, not both")
    validate_test_plan(live=bool(args.live_config))
    if not (ROOT / "MarkdownIt.xcodeproj/project.pbxproj").is_file():
        raise SystemExit("Missing MarkdownIt.xcodeproj. Use a complete project checkout.")
    cancel = threading.Event()
    previous_handlers = {
        sig: signal.signal(sig, lambda _signal, _frame: cancel.set())
        for sig in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        return verify(args, cancel)
    finally:
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)


def verify(args, cancel):
    if args.test_products is None:
        run([sys.executable, "scripts/build_native_web.py"])
        for script in ["reader.js", "agent.js", "localization.js"]:
            run(["node", "--check", f"MarkdownIt/Resources/Web/{script}"])
        run(
            [
                "xcrun",
                "swift-format",
                "lint",
                "--strict",
                "--recursive",
                "--configuration",
                ".swift-format",
                "MarkdownIt",
                "MarkdownItTests",
                "MarkdownItUITests",
                "MarkdownItLiveTests",
                "scripts",
            ]
        )
    runtimes = [
        item
        for item in simulator_data("runtimes")["runtimes"]
        if item["isAvailable"]
        and item.get("platform") == "iOS"
        and int(item["version"].split(".")[0]) >= 26
        and (args.runtime is None or item["version"] == args.runtime)
    ]
    if not runtimes:
        raise SystemExit(
            f"No installed iOS 26+ runtime matches {args.runtime or 'the requested platform'}."
        )
    devices = simulator_data("devices")["devices"]
    output = (
        args.output
        or ROOT / "output/native" / datetime.now().strftime("validation-%Y%m%d-%H%M%S-%f")
    ).resolve()
    output.mkdir(parents=True, exist_ok=False)
    products = (
        args.test_products.resolve()
        if args.test_products
        else output / "DerivedData/Build/Products"
    )
    if args.test_products is None:
        code = run_tests(
            [
                "xcodebuild",
                "-project",
                "MarkdownIt.xcodeproj",
                "-scheme",
                "MarkdownItLive" if args.live_config else "MarkdownIt",
                "-testPlan",
                "Live" if args.live_config else "Full",
                "-destination",
                "generic/platform=iOS Simulator",
                "-derivedDataPath",
                str(output / "DerivedData"),
                "build-for-testing",
            ],
            output / "build.log",
            cancel=cancel,
        )
        if code:
            return code
    specification = test_run_specification(products, live=bool(args.live_config))
    validate_test_product_signatures(specification)
    if args.live_config:
        metadata = plistlib.loads(specification.read_bytes())
        for configuration in metadata["TestConfigurations"]:
            for target in configuration["TestTargets"]:
                target.setdefault("EnvironmentVariables", {}).update(
                    {
                        "MARKDOWNIT_LIVE_CONFIG": str(args.live_config),
                        "CFNETWORK_DIAGNOSTICS": "0",
                    }
                )
        specification.write_bytes(plistlib.dumps(metadata))
    start_simulator_client()
    families = [args.family] if args.family else ["iPhone", "iPad"]
    results = verify_families(
        families,
        runtimes=runtimes,
        devices_by_runtime=devices,
        specification=specification,
        output=output,
        suite=args.suite,
        prefix=args.simulator_prefix,
        cancel=cancel,
        test_cases=args.test_case,
        live=bool(args.live_config),
    )
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(output, flush=True)
    return 0 if all(item["passed"] for item in results) else 1


if __name__ == "__main__":
    sys.exit(main())
