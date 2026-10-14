#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun clang -std=c11 -Wall -Wextra -Wno-unused-parameter -fsanitize=address,undefined -g \
  -I Sources/MixerDSP/include Sources/MixerDSP/MixerDSP.c Tests/DSPTests.c \
  -framework CoreAudio -o .build/tests/DSPTests
.build/tests/DSPTests
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
# Compile the actual recovery/settings sources with the regression harness.
# This runs with Command Line Tools alone; XCTest requires the full Xcode app.
xcrun swiftc -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  Sources/MenuMixer/AppVolume.swift Sources/MenuMixer/RouteRecovery.swift Sources/MenuMixer/ApplicationIdentity.swift \
  Tests/MenuMixerTests/RouteRecoveryTests.swift Tests/MenuMixerTests/IdentityTests.swift Tests/MenuMixerTests/RegressionRunner.swift \
  -o .build/tests/RecoveryTests
.build/tests/RecoveryTests
