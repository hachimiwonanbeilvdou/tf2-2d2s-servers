#!/bin/bash
# Download required custom maps for the TF2 MGE server
# Run this before starting the server

MAPS_DIR="../tf/maps"
mkdir -p "$MAPS_DIR"

echo "=== Downloading MGE custom maps ==="

# Map URLs (replace with actual download links)
# These maps are available from various TF2 map sites
# If you have the BSP files locally, copy them directly to tf/maps/

MAP_LIST=(
  "mge_training_v8_beta4b"
  "mge_bball_v2"
  "mge_dueling_v1_fix1"
  "mge_oihguv_sucks_a12"
  "mge_oihguv_sucks_b5"
  "mge_triumph_beta7_rc1"
)

# Large map - needs separate handling (>100MB, won't fit in Git)
LARGE_MAP="mge_chillypunch_final4_fix2"

echo ""
echo "⚠️  NOTE: The following map is >100MB and not included in the repo:"
echo "   $LARGE_MAP.bsp (137MB)"
echo ""
echo "   Download it from:"
echo "   https://tf2maps.net or https://gamebanana.com"
echo "   and place it in: $MAPS_DIR/"
echo ""

# Check which maps are missing
MISSING=0
for map in "${MAP_LIST[@]}"; do
  if [ ! -f "$MAPS_DIR/$map.bsp" ]; then
    echo "  ✗ $map.bsp - NOT FOUND"
    MISSING=$((MISSING + 1))
  else
    echo "  ✓ $map.bsp - OK ($(du -sh "$MAPS_DIR/$map.bsp" | cut -f1))"
  fi
done

if [ ! -f "$MAPS_DIR/$LARGE_MAP.bsp" ]; then
  echo "  ✗ $LARGE_MAP.bsp - NOT FOUND (137MB, download separately)"
  MISSING=$((MISSING + 1))
fi

echo ""
if [ $MISSING -eq 0 ]; then
  echo "✅ All maps present!"
else
  echo "⚠️  $MISSING map(s) missing. Please download them before starting the server."
  echo ""
  echo "The maps currently in the repo should be sufficient for basic MGE gameplay."
  echo "The large map ($LARGE_MAP) is optional."
fi
