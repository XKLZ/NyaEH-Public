#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
NYAEH_RUN_PERFORMANCE_TESTS=1 swift test --filter syntheticLibraryPerformance
