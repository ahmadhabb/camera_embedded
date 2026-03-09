#!/bin/bash

echo "=== Running Camera App ==="

# Set library path
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$(pwd):$(pwd)/linux

# Run
flutter run -d linux --release