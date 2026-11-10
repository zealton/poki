#!/bin/sh
set -eu
workspace_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workspace_test_dir=$(mktemp -d)
trap 'rm -rf "$workspace_test_dir"' EXIT
xcrun clang -fobjc-arc -framework Foundation -I "$workspace_root/Shared" "$workspace_root/Shared/WorkspacePolicy.m" "$workspace_root/Tests/policy.m" -o "$workspace_test_dir/policy"
"$workspace_test_dir/policy"
