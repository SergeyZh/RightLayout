#!/usr/bin/env python3
"""Release notes, in English and Russian, from the pull requests merged since the last release.

Each pull request says what changed for users in its "Release notes" section:

    ## Release notes

    EN: Show when secure input hides typing, and which app holds it.
    RU: Показывать, когда защищённый ввод скрывает набор текста и какая программа его держит.

Several EN/RU lines make several items. "EN: none", or the skip-release-notes label,
leaves a pull request out (CI, refactoring). Without the section, its title stands in
for both languages.

    release_notes.py --prs prs.json --commits commits.txt --notes-dir releases/notes

prs.json: `gh pr list --state merged --json number,title,body,labels,mergeCommit,url`.
commits.txt: `git rev-list <previous tag>..HEAD`, the commits this release adds.
"""

import argparse
import json
import re
import sys
from pathlib import Path

SKIP_LABEL = "skip-release-notes"
SECTION = re.compile(r"^#{1,6}\s*release notes\s*$", re.IGNORECASE)
HEADING = re.compile(r"^#{1,6}\s")
ITEM = re.compile(r"^\s*(?:[-*]\s*)?(EN|RU)\s*:\s*(.*?)\s*$", re.IGNORECASE)

TITLES = {"en": ("English", "Changes"), "ru": ("Русский", "Изменения")}
NOTHING = {
    "en": "Maintenance build, no user-facing changes.",
    "ru": "Служебная сборка, без заметных изменений.",
}


def release_note_items(body):
    """The (en, ru) items of a pull request's "Release notes" section; None without one."""
    lines = (body or "").splitlines()
    start = next((i for i, line in enumerate(lines) if SECTION.match(line.strip())), None)
    if start is None:
        return None
    items = {"en": [], "ru": []}
    for line in lines[start + 1:]:
        if HEADING.match(line):
            break
        match = ITEM.match(line)
        if match and match.group(2):
            items[match.group(1).lower()].append(match.group(2))
    if not items["en"] and not items["ru"]:
        return None
    if any(item.lower().rstrip(".") == "none" for item in items["en"] + items["ru"]):
        return [], []
    return items["en"], items["ru"]


def changes(prs, commits):
    """(en, ru) lines for the pull requests merged into the commits of this release, oldest first."""
    included = [
        pr for pr in prs
        if (pr.get("mergeCommit") or {}).get("oid") in commits
        and SKIP_LABEL not in {label.get("name") for label in pr.get("labels") or []}
    ]
    included.sort(key=lambda pr: pr["number"])
    en, ru = [], []
    for pr in included:
        link = f"([#{pr['number']}]({pr['url']}))"
        items = release_note_items(pr.get("body"))
        if items is None:
            items = ([pr["title"]], [pr["title"]])
        pr_en, pr_ru = items
        # A pull request that says it only in one language still shows in both.
        en += [f"- {item} {link}" for item in pr_en or pr_ru]
        ru += [f"- {item} {link}" for item in pr_ru or pr_en]
    return en, ru


def notes(prs, commits, headers):
    en, ru = changes(prs, commits)
    parts = []
    for lang, lines in (("en", en), ("ru", ru)):
        language, heading = TITLES[lang]
        parts.append(f"## {language}\n\n{headers[lang].strip()}\n\n### {heading}\n\n"
                     + "\n".join(lines or [f"- {NOTHING[lang]}"]))
    return "\n\n".join(parts) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--prs", required=True, type=Path)
    parser.add_argument("--commits", required=True, type=Path)
    parser.add_argument("--notes-dir", required=True, type=Path)
    args = parser.parse_args()

    prs = json.loads(args.prs.read_text(encoding="utf-8"))
    commits = set(args.commits.read_text(encoding="utf-8").split())
    headers = {lang: (args.notes_dir / f"header.{lang}.md").read_text(encoding="utf-8") for lang in TITLES}
    sys.stdout.write(notes(prs, commits, headers))


if __name__ == "__main__":
    main()
