#!/bin/bash
# Development helper: rebuilds the app every time a ".rebuild" file appears in this folder.
# Ctrl+C to stop.
cd "$(dirname "$0")"
echo "👀 Watching for rebuild requests… (Ctrl+C to stop)"
touch .rebuild
while true; do
  if [ -f .rebuild ]; then
    rm -f .rebuild .build-status
    echo "=== Build $(date +%T) ==="
    if bash build.sh > build.log 2>&1; then
      echo ok > .build-status; echo "✅ success — launching ClassicPaint"
      pkill -x ClassicPaint 2>/dev/null; pkill -x Paint 2>/dev/null; sleep 0.5; open build/ClassicPaint.app
    else
      echo fail > .build-status; echo "❌ failed — see build.log"
    fi
  fi
  sleep 2
done
