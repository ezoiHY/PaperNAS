#!/bin/bash
set -euo pipefail
task_root=$(cd "$(dirname "$0")/.." && pwd)
toolchain_bin=$(dirname "$(xcrun --find swiftc)")
testing_plugin="$toolchain_bin/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
cd "$task_root/macOS"
# CLT's incremental dependency scanner can omit TestingMacros. Load it explicitly.
if [ -f "$testing_plugin" ]; then
  swift test --disable-xctest -Xswiftc -load-plugin-library -Xswiftc "$testing_plugin"
else
  swift test --disable-xctest
fi
