#!/bin/sh
set -eu

for test_file in tests/_test_*.lua; do
    lua "$test_file"
done
