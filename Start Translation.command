#!/bin/bash
# Double-click launcher for Church AI Translation
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"
exec bash "$SCRIPT_DIR/start_translation.sh"
