import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_algorithm_page as check  # noqa: E402

ROUTER = "RightLayout/Sources/Core/ConfidenceRouter.swift"
MONITOR = "RightLayout/Sources/Engine/EventMonitor.swift"
DIAGRAM = "RightLayout/Sources/UI/AlgorithmDiagram.swift"


class CheckAlgorithmPageTests(unittest.TestCase):
    def test_an_algorithm_change_without_the_page_fails(self):
        problem = check.check([MONITOR, "RightLayout/Tests/AutoCorrectionSwitchTests.swift"], "## Why\n\nBecause.")
        self.assertIsNotNone(problem)
        self.assertIn(MONITOR, problem)

    def test_changing_the_page_too_passes(self):
        self.assertIsNone(check.check([ROUTER, DIAGRAM], ""))

    def test_engine_extensions_count(self):
        self.assertIsNotNone(check.check(["RightLayout/Sources/Engine/CorrectionEngine+Decide.swift"], ""))

    def test_other_changes_pass(self):
        paths = ["README.md", "RightLayout/Sources/UI/SettingsView.swift", "RightLayout/Tests/LayoutMapperTests.swift"]
        self.assertIsNone(check.check(paths, ""))

    def test_a_reason_in_the_section_passes(self):
        body = "## Why\n\nTidy.\n\n## Algorithm page\n\nNot needed: only renames a private helper.\n\n## Testing\n"
        self.assertIsNone(check.check([ROUTER], body))

    def test_the_reason_must_be_in_the_section(self):
        body = "## Why\n\nNot needed: says it elsewhere.\n\n## Algorithm page\n\n## Testing\n\nNot needed: here either."
        self.assertIsNotNone(check.check([ROUTER], body))

    def test_the_template_hint_is_not_a_reason(self):
        body = "## Algorithm page\n\nNot needed: <!-- why -->\n"
        self.assertIsNotNone(check.check([ROUTER], body))

    def test_an_empty_reason_is_not_a_reason(self):
        self.assertIsNotNone(check.check([ROUTER], "### Algorithm page\n- Not needed:\n"))

    def test_list_markers_and_case(self):
        self.assertIsNone(check.check([ROUTER], "### algorithm page\n- not needed: comments only"))


if __name__ == "__main__":
    unittest.main()
