#!/bin/bash
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -o "$work/marker-tests" "$here/../FolderVideoPlayer/Model/ModelSpace.swift" "$here/test_model_space_validation.swift" -framework CryptoKit
"$work/marker-tests"
