#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/scaffold-xcuitest.sh <FlowName>
# Example: ./scripts/scaffold-xcuitest.sh RemuxMatchFlow

if [ $# -lt 1 ]; then
  echo "Usage: $0 <FlowName>"
  exit 1
fi

FLOW="$1"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
  echo "Error: not inside a git repository."
  exit 1
fi
cd "$ROOT"

if ! [[ "$FLOW" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "Error: FlowName must be a Swift identifier (letters, digits, and underscore; not starting with a digit)."
  exit 1
fi

# Auto-detect UITests directory (e.g., App/UITests or *UITests).
# Skip .build, DerivedData, and .git so maxdepth 3 cannot pick build products.
UI_TEST_DIR=$(find . -maxdepth 3 \( -name .build -o -name DerivedData -o -name .git \) -prune -o -type d -name "*UITests" -print | head -n 1)

if [ -z "$UI_TEST_DIR" ]; then
  echo "Error: No *UITests directory found. Ensure a UI Test target exists in App/project.yml."
  exit 1
fi

TEST_FILE="$UI_TEST_DIR/${FLOW}UITests.swift"

if [ -e "$TEST_FILE" ]; then
  echo "Error: $TEST_FILE already exists."
  exit 1
fi

cat > "$TEST_FILE" <<EOF
import XCTest

@MainActor
final class ${FLOW}UITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    /// Pareto Critical Path: Verify main window and key controls render and respond.
    func test${FLOW}CriticalPath() throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Main application window did not appear.")

        // TODO: Assert critical controls via accessibilityIdentifier (avoid brittle coordinates)
        // Example:
        // let toggle = app.checkBoxes["matchOnMKANameToggle"]
        // XCTAssertTrue(toggle.waitForExistence(timeout: 2))
    }
}
EOF

echo "Created XCUITest: $TEST_FILE"

# New UI test files belong to the Xcode app project, so they need a
# project regen. On this Linux VM (no Swift), use the churn-free
# verify-linux.sh path instead of a raw `xcodegen generate`.
if [ -f "App/project.yml" ]; then
  if ! command -v swift >/dev/null 2>&1 && [ -x "./scripts/verify-linux.sh" ]; then
    ./scripts/verify-linux.sh
  else
    echo "Swift is on PATH; regenerate the Xcode project with your usual XcodeGen path."
  fi
fi
