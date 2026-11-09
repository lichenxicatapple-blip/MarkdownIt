import unittest

from scripts import update_model_catalog


class ModelCapacityCatalog(unittest.TestCase):
    def test_provider_limits_override_base_and_omitted_fields_stay_unknown(self):
        bases = {"lab/model": {"limit": {"context": 1000, "input": 900, "output": 200}}}
        value = update_model_catalog.model_limits(
            {
                "base_model": "lab/model",
                "limit": {"context": 800},
                "base_model_omit": ["limit.input"],
            },
            bases,
        )
        self.assertEqual(value, {"contextWindow": 800, "maxOutputTokens": 200})
        with self.assertRaisesRegex(ValueError, "Missing canonical model"):
            update_model_catalog.model_limits({"base_model": "missing"}, bases)

    def test_unknown_invalid_and_non_token_values_are_not_invented(self):
        for invalid in [None, -1, 0, True, "128000", 1.5]:
            self.assertEqual(
                update_model_catalog.model_limits({"limit": {"context": invalid}}, {}), {}
            )
        self.assertEqual(update_model_catalog.model_limits({}, {}), {})

    def test_exact_provider_ids_and_host_overrides_survive_generation(self):
        files = {
            "models/lab/model.toml": "schema=2\n[limit]\ncontext=1000\noutput=200",
            "providers/host/provider.toml": 'api="https://host.example/v1"',
            "providers/host/models/lab/model.toml": 'schema=2\nbase_model="lab/model"\n[limit]\ncontext=800',
            "providers/other/provider.toml": 'api="https://other.example/v1"',
            "providers/other/models/lab/model.toml": 'schema=2\nbase_model="lab/model"',
            "providers/local/provider.toml": 'api="http://localhost:1234"',
            "providers/local/models/model.toml": "schema=2\n[limit]\ncontext=200",
        }
        result = update_model_catalog.catalog(files, "a" * 40)
        self.assertEqual(result["revision"], "a" * 40)
        providers = result["providers"]
        self.assertEqual(set(providers), {"host", "other"})
        self.assertEqual(providers["host"]["models"]["lab/model"]["contextWindow"], 800)
        self.assertEqual(providers["other"]["models"]["lab/model"]["contextWindow"], 1000)


if __name__ == "__main__":
    unittest.main()
