#!/usr/bin/env bash

set -euo pipefail

# Xcode 26.6 exports deployment targets for every Apple platform when a custom
# compiler is selected. Flutter's nested macOS clang invocation must see only
# the macOS target, otherwise clang 21 rejects the environment as conflicting.
unset IPHONEOS_DEPLOYMENT_TARGET
unset TVOS_DEPLOYMENT_TARGET
unset WATCHOS_DEPLOYMENT_TARGET
unset XROS_DEPLOYMENT_TARGET
unset DRIVERKIT_DEPLOYMENT_TARGET

exec "$FLUTTER_ROOT/packages/flutter_tools/bin/macos_assemble.sh" "$@"
