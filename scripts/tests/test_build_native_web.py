import io
import json
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

from scripts import build_native_web


class DependencyAdvisories(unittest.TestCase):
    assets = [
        {
            "package": "reader-plugin",
            "version": "3.0.0",
            "bundledDependencies": [{"package": "unicode-helper", "version": "1.4.0"}],
        },
        {"target": "native", "file": "font.ttf"},
    ]

    def audit(self, results):
        with (
            patch.object(build_native_web, "vendor_assets", return_value=self.assets),
            patch.object(build_native_web.urllib.request, "urlopen") as request,
            redirect_stdout(io.StringIO()),
        ):
            request.return_value.__enter__.return_value = io.StringIO(
                json.dumps({"results": results})
            )
            build_native_web.audit_dependencies()
            return json.loads(request.call_args.args[0].data)

    def test_bundled_runtime_packages_are_included_in_advisory_requests(self):
        payload = self.audit([{}, {}])
        self.assertEqual(
            payload["queries"],
            [
                {"version": "3.0.0", "package": {"name": "reader-plugin", "ecosystem": "npm"}},
                {"version": "1.4.0", "package": {"name": "unicode-helper", "ecosystem": "npm"}},
            ],
        )

    def test_a_bundled_package_advisory_fails_the_check(self):
        with self.assertRaisesRegex(SystemExit, "unicode-helper 1.4.0: GHSA-example"):
            self.audit([{}, {"vulns": [{"id": "GHSA-example"}]}])

    def test_missing_bundled_package_results_do_not_count_as_clean(self):
        with self.assertRaisesRegex(SystemExit, "Dependency advisory check failed"):
            self.audit([{}])
