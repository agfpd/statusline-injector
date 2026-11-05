"""Catalog contract checks; CLI install smoke tests are run separately."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PublicMarketplace(unittest.TestCase):
    def test_catalogs_pin_the_same_public_release(self):
        entries = []
        for path in (".claude-plugin/marketplace.json",
                     ".agents/plugins/marketplace.json"):
            catalog = json.loads((ROOT / path).read_text())
            self.assertEqual(catalog["name"], "statusline-injector")
            self.assertEqual(len(catalog["plugins"]), 1)
            plugin = catalog["plugins"][0]
            self.assertEqual(plugin["name"], "statusline-injector")
            source = plugin["source"]
            self.assertEqual(source["source"], "url")
            self.assertEqual(source["url"],
                             "https://github.com/agfpd/statusline-injector.git")
            self.assertEqual(source["ref"], "v" + plugin["version"])
            self.assertRegex(source["sha"], r"^[0-9a-f]{40}$")
            entries.append((source, plugin["version"]))
        self.assertEqual(entries[0], entries[1])

    def test_both_readmes_use_the_public_install_id(self):
        for path in ("README.md", "README.ru.md"):
            doc = (ROOT / path).read_text()
            for runtime, action in (("claude", "install"), ("codex", "add")):
                self.assertIn(runtime + " plugin marketplace add "
                              "https://github.com/agfpd/statusline-injector.git", doc)
                self.assertIn(runtime + " plugin " + action +
                              " statusline-injector@statusline-injector", doc)


if __name__ == "__main__":
    unittest.main()
