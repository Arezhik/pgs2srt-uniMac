#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/scaffold-swift.sh <FeatureName> [Subfolder]
# Example: ./scripts/scaffold-swift.sh MKAMatcher Matching

if [ $# -lt 1 ]; then
  echo "Usage: $0 <FeatureName> [Subfolder]"
  exit 1
fi

NAME="$1"
SUBFOLDER="${2:-}"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
  echo "Error: not inside a git repository."
  exit 1
fi
cd "$ROOT"

if ! [[ "$NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Error: FeatureName must be a Swift identifier (letters, digits, and underscore; not starting with a digit)."
  exit 1
fi

if [ -n "$SUBFOLDER" ]; then
  if ! [[ "$SUBFOLDER" =~ ^[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*)*$ ]]; then
    echo "Error: Subfolder must be one or more Swift-identifier path segments (no '..', absolute paths, or other characters)."
    exit 1
  fi
fi

# Auto-detect *Core and *CoreTests directories from Sources/ and Tests/
CORE_DIR=$(find Sources -maxdepth 1 -type d -name "*Core" | head -n 1)
TEST_DIR=$(find Tests -maxdepth 1 -type d -name "*CoreTests" | head -n 1)

if [ -z "$CORE_DIR" ] || [ -z "$TEST_DIR" ]; then
  echo "Error: Could not find Sources/*Core or Tests/*CoreTests"
  exit 1
fi

CORE_MODULE=$(basename "$CORE_DIR")

if [ -n "$SUBFOLDER" ]; then
  TARGET_SRC_DIR="$CORE_DIR/$SUBFOLDER"
  TARGET_TEST_DIR="$TEST_DIR/$SUBFOLDER"
else
  TARGET_SRC_DIR="$CORE_DIR"
  TARGET_TEST_DIR="$TEST_DIR"
fi

mkdir -p "$TARGET_SRC_DIR" "$TARGET_TEST_DIR"

SRC_FILE="$TARGET_SRC_DIR/${NAME}.swift"
TEST_FILE="$TARGET_TEST_DIR/${NAME}Tests.swift"

if [ -e "$SRC_FILE" ] || [ -e "$TEST_FILE" ]; then
  echo "Error: $SRC_FILE or $TEST_FILE already exists. Aborting to prevent overwrite."
  exit 1
fi

# 1. Generate pure-Foundation Core file (Linux & macOS CI compatible)
cat > "$SRC_FILE" <<EOF
import Foundation

/// TODO: Describe ${NAME} responsibility.
public struct ${NAME}: Sendable {
    public init() {}
}
EOF

# 2. Generate matching XCTest file
cat > "$TEST_FILE" <<EOF
import XCTest
@testable import ${CORE_MODULE}

final class ${NAME}Tests: XCTestCase {
    func testInitialBehavior() {
        let sut = ${NAME}()
        XCTAssertEqual(String(describing: type(of: sut)), "${NAME}")
    }
}
EOF

echo "Created: $SRC_FILE"
echo "Created: $TEST_FILE"

# 3. Core is a local Swift package (App/project.yml path: ..), so new
# Sources/*Core and Tests/*CoreTests files do not need an XcodeGen regen.
# On this Linux VM (no Swift), run the existing churn-free health check.
if ! command -v swift >/dev/null 2>&1 && [ -x "./scripts/verify-linux.sh" ]; then
  ./scripts/verify-linux.sh
else
  echo "No Xcode project regen needed; Core is a local Swift package."
fi
