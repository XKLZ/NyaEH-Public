#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

export NYAEH_RUN_SEMANTIC_SERIES_TESTS=1
swift test --filter semanticSeriesCalibrationReport
