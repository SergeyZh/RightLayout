#!/usr/bin/env python3
"""Fails a pull request that changes the word-check algorithm but not the Algorithm page.

Settings → Algorithm draws how a typed word is decided and replaced (CONTRIBUTING.md,
"Changing How Words Are Decided"). A pull request that changes one of the algorithm's
files must change the page too, or say in its "Algorithm page" section why it needn't:

    ## Algorithm page

    Not needed: only renames a private helper.

    check_algorithm_page.py --files changed.txt

changed.txt: `git diff --name-only <base>...<head>`, one path per line. The pull
request's description is read from the PR_BODY environment variable.
"""

import argparse
import os
import re
import sys
from fnmatch import fnmatch

SOURCES = "RightLayout/Sources/"

# Files whose changes can change how a word is decided, suggested or left alone, or how a
# correction is put into the text.
ALGORITHM = [
    SOURCES + "Core/ConfidenceRouter.swift",
    SOURCES + "Core/CoreMLLayoutClassifier.swift",
    SOURCES + "Core/FoundationModelClassifier.swift",
    SOURCES + "Core/LanguageEnsemble.swift",
    SOURCES + "Core/LayoutMapper.swift",
    SOURCES + "Core/NgramLanguageModel.swift",
    SOURCES + "Core/UserDictionary.swift",
    SOURCES + "Core/WordFrequencyModel.swift",
    SOURCES + "Core/WordValidator.swift",
    SOURCES + "Core/WrongLayoutShorthand.swift",
    SOURCES + "Engine/CorrectionDecisionPolicy.swift",
    SOURCES + "Engine/CorrectionEngine*.swift",
    SOURCES + "Engine/CorrectionVerifierAgent.swift",
    SOURCES + "Engine/EventMonitor.swift",
    SOURCES + "Engine/RuntimeProfiles.swift",
    SOURCES + "Personalization/IntentDetector.swift",
    SOURCES + "Personalization/RiskController.swift",
    SOURCES + "Personalization/TransliterationDetector.swift",
    SOURCES + "Services/FocusedTextContextService.swift",
    SOURCES + "Services/SelectionReplacementService.swift",
    SOURCES + "Resources/language_data.json",
    SOURCES + "Resources/layouts.json",
    SOURCES + "Resources/thresholds.json",
]

# The Algorithm page: its blocks, switches, parameters and the trace of its test field.
PAGE = [
    SOURCES + "Core/DecisionPipeline.swift",
    SOURCES + "Core/DecisionProbe.swift",
    SOURCES + "Engine/DecisionPlayground.swift",
    SOURCES + "UI/AlgorithmDiagram.swift",
    SOURCES + "UI/AlgorithmSettingsView.swift",
    SOURCES + "UI/DecisionPlaygroundModel.swift",
]

SECTION = re.compile(r"^#{1,6}\s*algorithm page\s*$", re.IGNORECASE)
HEADING = re.compile(r"^#{1,6}\s")
NOT_NEEDED = re.compile(r"^\s*(?:[-*]\s*)?not needed\s*:\s*(.*?)\s*$", re.IGNORECASE)


def matching(paths, patterns):
    return [path for path in paths if any(fnmatch(path, pattern) for pattern in patterns)]


def reason_not_needed(body):
    """The reason given in the "Algorithm page" section for leaving the page alone, if any."""
    lines = (body or "").splitlines()
    start = next((i for i, line in enumerate(lines) if SECTION.match(line.strip())), None)
    if start is None:
        return None
    for line in lines[start + 1:]:
        if HEADING.match(line):
            break
        match = NOT_NEEDED.match(line)
        # An HTML comment is the template's hint, not a reason.
        if match and match.group(1) and not match.group(1).startswith("<!--"):
            return match.group(1)
    return None


def check(paths, body):
    """None if the pull request may go in, otherwise what is wrong."""
    changed = matching(paths, ALGORITHM)
    if not changed or matching(paths, PAGE):
        return None
    if reason_not_needed(body):
        return None
    files = "\n".join(f"  {path}" for path in changed)
    return (
        "This pull request changes the word-check algorithm:\n"
        f"{files}\n"
        "but not the Algorithm page in Settings. Update its blocks, switches, parameters or\n"
        "test-field trace as CONTRIBUTING.md (\"Changing How Words Are Decided\") describes,\n"
        "or say why it needs no change in the pull request's description:\n\n"
        "    ## Algorithm page\n\n"
        "    Not needed: <why>\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--files", required=True, help="the changed paths, one per line")
    args = parser.parse_args()
    with open(args.files, encoding="utf-8") as handle:
        paths = [line.strip() for line in handle if line.strip()]
    problem = check(paths, os.environ.get("PR_BODY", ""))
    if problem:
        changed = ", ".join(path.rsplit("/", 1)[-1] for path in matching(paths, ALGORITHM))
        print(f"::error title=Algorithm page::{changed} changed, the Algorithm page didn't; update it or say why not")
        print(problem)
        return 1
    print("The Algorithm page is in step with this change.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
