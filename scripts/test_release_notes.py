import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release_notes  # noqa: E402

HEADERS = {"en": "Install it.", "ru": "Установите."}


def pr(number, title, body="", commit=None, labels=()):
    return {
        "number": number,
        "title": title,
        "body": body,
        "url": f"https://example.com/pull/{number}",
        "mergeCommit": {"oid": commit or f"c{number}"},
        "labels": [{"name": name} for name in labels],
    }


class ReleaseNotesTests(unittest.TestCase):
    def test_both_languages_from_the_section(self):
        body = "## Why\n\nBecause.\n\n## Release notes\n\nEN: Shows secure input.\nRU: Показывает защищённый ввод.\n\n## Testing\n\nEN: not this"
        en, ru = release_notes.changes([pr(15, "Title", body)], {"c15"})
        self.assertEqual(en, ["- Shows secure input. ([#15](https://example.com/pull/15))"])
        self.assertEqual(ru, ["- Показывает защищённый ввод. ([#15](https://example.com/pull/15))"])

    def test_several_items_and_list_markers(self):
        body = "### Release notes\n- EN: One.\n- RU: Один.\n- en: Two.\n- ru: Два."
        en, ru = release_notes.changes([pr(1, "T", body)], {"c1"})
        self.assertEqual([line.split(" (")[0] for line in en], ["- One.", "- Two."])
        self.assertEqual([line.split(" (")[0] for line in ru], ["- Один.", "- Два."])

    def test_title_without_the_section(self):
        en, ru = release_notes.changes([pr(2, "Fix lost spaces in Slack")], {"c2"})
        self.assertTrue(en[0].startswith("- Fix lost spaces in Slack"))
        self.assertEqual(en, ru)

    def test_one_language_shows_in_both(self):
        en, ru = release_notes.changes([pr(3, "T", "## Release notes\nEN: Only English.")], {"c3"})
        self.assertEqual(en, ru)

    def test_left_out(self):
        prs = [
            pr(4, "CI", "## Release notes\nEN: none\nRU: none"),
            pr(5, "Refactor", labels=["skip-release-notes"]),
            pr(6, "Earlier release"),
        ]
        self.assertEqual(release_notes.changes(prs, {"c4", "c5"}), ([], []))

    def test_notes_say_when_nothing_changed(self):
        text = release_notes.notes([], set(), HEADERS)
        self.assertIn("## English\n\nInstall it.\n\n### Changes\n\n- Maintenance build", text)
        self.assertIn("## Русский\n\nУстановите.\n\n### Изменения\n\n- Служебная сборка", text)

    def test_oldest_first(self):
        en, _ = release_notes.changes([pr(9, "Nine"), pr(7, "Seven")], {"c7", "c9"})
        self.assertEqual([line.split(" (")[0] for line in en], ["- Seven", "- Nine"])


if __name__ == "__main__":
    unittest.main()
