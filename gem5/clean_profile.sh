#!/bin/bash

# This script finds and deletes all profiles (files ending with .gcda)
# recursively under the specified directory.

TARGET_DIR="./build/ARM/"

echo "Deleting profiles in $TARGET_DIR..."

# Find files ending with .gcda and delete them
find "$TARGET_DIR" -name '*.gcda' -type f -delete
find "$TARGET_DIR" -name '*.po' -type f -delete
find "$TARGET_DIR" -name '*.pos' -type f -delete
find "$TARGET_DIR" -name '*.pypo' -type f -delete

echo "Profile deletion complete."