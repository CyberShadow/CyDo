#!/usr/bin/env bash
# Render logo-banner.svg → dark/light .webp files for the README.
#
# The README displays the banner at width="520" CSS pixels.
# We render at 2x (1040px) for Retina/HiDPI screens.
#
# Usage:
#   nix develop -ic docs/tools/render-banner.sh
#
# Dependencies (all provided by nix shell below):
#   inkscape, cwebp (libwebp)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOCS="$REPO_ROOT/docs"
SVG="$DOCS/logo-banner.svg"

DISPLAY_WIDTH=520
SCALE=2
TARGET_WIDTH=$((DISPLAY_WIDTH * SCALE))

# SVG viewBox width → compute DPI for target pixel width
VIEWBOX_WIDTH=$(grep -oP 'viewBox="[^"]*"' "$SVG" | grep -oP '[\d.]+' | sed -n '3p')
DPI=$(python3 -c "print(round($TARGET_WIDTH / $VIEWBOX_WIDTH * 96))")

echo "SVG viewBox width: ${VIEWBOX_WIDTH}, target: ${TARGET_WIDTH}px, DPI: ${DPI}"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

render() {
  local name="$1" svg_src="$2" quality="${3:-90}"

  echo "Rendering ${name}..."
  inkscape "$svg_src" \
    --export-type=png \
    --export-filename="$TMPDIR/${name}.png" \
    --export-dpi="$DPI" \
    --export-background-opacity=0 2>&1 | grep -v WARNING | grep -v Fontconfig || true

  cwebp -q "$quality" -alpha_q 100 "$TMPDIR/${name}.png" -o "$DOCS/${name}.webp" 2>&1

  echo "  → $(ls -lh "$DOCS/${name}.webp" | awk '{print $5}') ($DOCS/${name}.webp)"
}

# Dark variant: bright gradient, strong shadow — uses logo-banner.svg as-is
render "logo-banner-dark" "$SVG"

# Light variant: darker colors, softer shadow for white backgrounds
# Patch the SVG in a temp copy
LIGHT_SVG="$TMPDIR/logo-banner-light.svg"
sed \
  -e 's/#f0d050/#c8a020/g' \
  -e 's/hsl(122, 40%, 50%)/hsl(122, 40%, 38%)/g' \
  -e 's/flood-opacity="0.6"/flood-opacity="0.3"/' \
  "$SVG" > "$LIGHT_SVG"

render "logo-banner-light" "$LIGHT_SVG"

echo "Done."
