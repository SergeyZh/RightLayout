#!/usr/bin/env bash
# Prints the version for a new build: the current UTC time as YYYYMMDD.HHMMSS.
# Two period-separated integers, so it is a valid CFBundleVersion /
# CFBundleShortVersionString and always grows (UTC has no DST jumps back).
set -euo pipefail
date -u +%Y%m%d.%H%M%S
