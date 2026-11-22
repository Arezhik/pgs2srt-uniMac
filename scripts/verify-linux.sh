#!/usr/bin/env bash
# verify-linux.sh: Linux-host verification for this repo.
# When Swift is absent and a project.yml exists, regenerate the Xcode project
# with XcodeGen. Then run this repo's existing non-Swift check scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEFAULT_XCODEGEN="/workspace/macos-dev-test/projects/mkv-forge/icon/tools/XcodeGen-2.48.0/.build/x86_64-unknown-linux-gnu/release/xcodegen"
XCODEGEN="${XCODEGEN:-$DEFAULT_XCODEGEN}"

SPEC=""
if [ -f "$ROOT/App/project.yml" ]; then
  SPEC="$ROOT/App/project.yml"
elif [ -f "$ROOT/project.yml" ]; then
  SPEC="$ROOT/project.yml"
fi

if ! command -v swift >/dev/null 2>&1; then
  if [ -n "$SPEC" ]; then
    if [ ! -x "$XCODEGEN" ]; then
      echo "verify-linux: xcodegen not found or not executable: $XCODEGEN" >&2
      echo "verify-linux: set XCODEGEN to the xcodegen binary path." >&2
      exit 1
    fi
    echo "verify-linux: swift not on PATH; generating Xcode project from $SPEC"
    SPEC_DIR="$(cd "$(dirname "$SPEC")" && pwd)"
    (
      cd "$SPEC_DIR"
      "$XCODEGEN" generate --spec "$SPEC"
    )
  else
    echo "verify-linux: swift not on PATH and no project.yml found; skipping XcodeGen"
  fi
else
  echo "verify-linux: swift is on PATH; skipping XcodeGen"
fi

ran_any=0
# Run existing check scripts exactly as intended. Never run bump-version.sh
# without --check (that would bump the version). Skip this script itself.
if [ -x "$ROOT/scripts/check-project.sh" ]; then
  echo "verify-linux: running scripts/check-project.sh"
  "$ROOT/scripts/check-project.sh"
  ran_any=1
fi
if [ -x "$ROOT/scripts/bump-version.sh" ]; then
  echo "verify-linux: running scripts/bump-version.sh --check"
  "$ROOT/scripts/bump-version.sh" --check
  ran_any=1
fi

if [ "$ran_any" -eq 0 ]; then
  echo "verify-linux: no existing non-Swift check scripts in scripts/; nothing else to run"
  exit 0
fi

echo "verify-linux: all checks passed"
