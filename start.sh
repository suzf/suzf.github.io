#!/bin/bash
# Hugo server startup

echo "INFO: Cleaning Hugo cache..."
rm -f .hugo_build.lock
rm -rf resources/_gen

echo "INFO: Starting server with fast render disabled and HTTP cache disabled..."
hugo server \
  --disableFastRender \
  --noHTTPCache \
  --ignoreCache \
  --disableBrowserError \
  --navigateToChanged \
  --buildDrafts \
  --buildFuture \
  --gc \
  --environment production \
  --port 1313 \
  --bind 0.0.0.0
