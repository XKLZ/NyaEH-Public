#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 1 ]]; then
  echo "Usage: $0 <NyaEH.app>" >&2
  exit 2
fi

contents="$1/Contents"
for key in CFBundleIconName CFBundleIconFile; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$contents/Info.plist" 2>/dev/null)" || value=
  if [[ "$value" != AppIcon ]]; then
    printf 'App icon check failed: expected %s=AppIcon (found %s).\n' "$key" "${value:-missing}" >&2
    exit 1
  fi
done

for resource in AppIcon.icns Assets.car; do
  if [[ ! -s "$contents/Resources/$resource" ]]; then
    printf 'App icon check failed: missing or empty Resources/%s.\n' "$resource" >&2
    exit 1
  fi
done
