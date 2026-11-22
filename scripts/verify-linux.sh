#!/usr/bin/env bash
# verify-linux.sh: Linux-host verification for this repo.
# When Swift is absent and a project.yml exists, regenerate the Xcode project
# with XcodeGen. Then run this repo's existing non-Swift check scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEFAULT_XCODEGEN="/workspace/macos-dev-test/projects/mkv-forge/icon/tools/XcodeGen-2.48.0/.build/x86_64-unknown-linux-gnu/release/xcodegen"
XCODEGEN="${XCODEGEN:-$DEFAULT_XCODEGEN}"

# XcodeGen names the local package folder reference after the repo directory
# (absolutePath.lastComponent). Use the GitHub repo name so a clone folder
# like PGS2SRT or MP4SubRip still produces a stable project. Override with
# XCODEGEN_CLONE_NAME if needed.
xcodegen_clone_name() {
  if [ -n "${XCODEGEN_CLONE_NAME:-}" ]; then
    printf '%s\n' "$XCODEGEN_CLONE_NAME"
    return
  fi
  local url
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  if [ -z "$url" ]; then
    basename "$ROOT"
    return
  fi
  url="${url%/}"
  url="${url%.git}"
  basename "$url"
}

generate_xcode_project() {
  local spec="$1"
  local spec_dir expected current tmp wrap rel src dst
  spec_dir="$(cd "$(dirname "$spec")" && pwd)"
  expected="$(xcodegen_clone_name)"
  current="$(basename "$ROOT")"

  if [ "$current" = "$expected" ]; then
    echo "verify-linux: running xcodegen in $spec_dir (clone folder $current)"
    (cd "$spec_dir" && "$XCODEGEN" generate --spec "$spec")
    return
  fi

  echo "verify-linux: clone folder is $current; generating via a temp copy named $expected so the local package reference stays stable"
  tmp="$(mktemp -d)"
  wrap="$tmp/$expected"
  mkdir "$wrap"
  if ! (cd "$ROOT" && tar --exclude=./.git --exclude=./.build --exclude=./.swiftpm -cf - .) | (cd "$wrap" && tar -xf -); then
    rm -rf "$tmp"
    echo "verify-linux: failed to copy the working tree for XcodeGen" >&2
    exit 1
  fi
  rel="${spec_dir#"$ROOT"/}"
  if ! (cd "$wrap/$rel" && "$XCODEGEN" generate --spec "$wrap/${spec#"$ROOT"/}"); then
    rm -rf "$tmp"
    echo "verify-linux: xcodegen generate failed" >&2
    exit 1
  fi
  src="$(ls -d "$wrap/$rel"/*.xcodeproj)"
  dst="$spec_dir/$(basename "$src")"
  rm -rf "$dst"
  cp -a "$src" "$dst"
  rm -rf "$tmp"
}

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
    generate_xcode_project "$SPEC"
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
