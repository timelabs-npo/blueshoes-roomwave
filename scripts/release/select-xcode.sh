#!/usr/bin/env bash
set -euo pipefail
selected=""
for app in /Applications/Xcode_27.2.app /Applications/Xcode_27.2.0.app; do
  if [[ -d "$app/Contents/Developer" ]]; then
    version="$(DEVELOPER_DIR="$app/Contents/Developer" xcodebuild -version)"
    if [[ "$(printf '%s\n' "$version" | head -n 1)" == "Xcode 27.2" ]]; then
      selected="$app/Contents/Developer"
      break
    fi
  fi
done
[[ -n "$selected" ]] || { echo "::error::Stable Xcode 27.2 is required."; exit 1; }
printf 'DEVELOPER_DIR=%s\n' "$selected" >> "$GITHUB_ENV"
DEVELOPER_DIR="$selected" xcodebuild -version
DEVELOPER_DIR="$selected" xcodebuild -showsdks
DEVELOPER_DIR="$selected" swift --version
