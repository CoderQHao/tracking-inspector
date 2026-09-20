#!/bin/bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/tracking-inspector-fixtures.XXXXXX")
trap 'rm -rf -- "$fixture_dir"' EXIT
xcrun swiftc Sources/InspectorCore/InspectorProtocol.swift Sources/InspectorCore/WirelessTransport.swift \
  Tests/Fixtures/FixtureServer.swift -o "$fixture_dir/InspectorFixture"
"$fixture_dir/InspectorFixture"
