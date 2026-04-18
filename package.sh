#!/bin/bash
# Build rebalance.tar.gz from the plugin/ directory.
# Run this on Linux or WSL, then copy both output files to your Unraid server.
#
# Usage:  bash package.sh
# Output: rebalance.tar.gz  +  rebalance.plg

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building ReBalance plugin package..."

# Generate PNG icon from SVG (required — Unraid Tools page doesn't render SVG in img tags)
if command -v convert >/dev/null 2>&1; then
    convert -background none -resize 64x64 \
        plugin/images/rebalance.svg plugin/images/rebalance.png
    echo "Generated rebalance.png from SVG"
elif command -v inkscape >/dev/null 2>&1; then
    inkscape --export-type=png --export-width=64 --export-height=64 \
        --export-filename=plugin/images/rebalance.png \
        plugin/images/rebalance.svg
    echo "Generated rebalance.png from SVG (via Inkscape)"
else
    echo "WARNING: Neither ImageMagick nor Inkscape found."
    echo "         Install ImageMagick in WSL:  sudo apt-get install imagemagick"
    echo "         The Tools menu icon will not display until rebalance.png exists."
fi

# The tarball contents must extract to:  /usr/local/emhttp/plugins/rebalance/
# So we strip the leading "plugin/" from the paths inside the archive.
tar -czf rebalance.tar.gz \
    -C plugin \
    --transform 's|^\.|rebalance|' \
    .

echo ""
echo "Created: rebalance.tar.gz"
echo "Created: rebalance.plg  (already in this folder)"
echo ""
echo "════════════════════════════════════════════════════════"
echo " Installation steps"
echo "════════════════════════════════════════════════════════"
echo ""
echo "  On your Unraid server (via SSH or the terminal):"
echo "    mkdir -p /boot/config/plugins/rebalance"
echo "    cp rebalance.plg      /boot/config/plugins/rebalance/"
echo "    cp rebalance.tar.gz   /boot/config/plugins/rebalance/"
echo ""
echo "  In the Unraid web UI:"
echo "    1. Click PLUGINS in the top nav"
echo "    2. Click the 'Install Plugin' tab"
echo "    3. In the file browser navigate to:"
echo "          config → plugins → rebalance → rebalance.plg"
echo "       (or type the path: /boot/config/plugins/rebalance/rebalance.plg)"
echo "    4. Click INSTALL"
echo ""
echo "  After installation:"
echo "    • Plugin appears in:  PLUGINS → Installed Plugins"
echo "    • UI is accessed via: TOOLS   → ReBalance"
echo ""
