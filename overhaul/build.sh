#!/bin/bash
# Builds the latest overhaul place from the v87 place, overhaul/src and the library meshes it uses:
#   overhaul/build.sh            -> overhaul/Overkill_overhaul_v88.rbxl
# Run from the repository root (or anywhere: it finds its own folder).
set -e
cd "$(dirname "$0")/.."
M=ReplicatedStorage/Abilities/Assets/AzureTideCannon/Meshes
L=ServerStorage/VFXLibrary/Meshes/VFX
python3 -I tools/build_rbxl.py overhaul/Overkill_overhaul_v87.rbxl overhaul/src "${1:-overhaul/Overkill_overhaul_v88.rbxl}" \
  --copy "$L/Meshes/Contents/Lightning (Blue Skin)=$M/Sleeve" \
  --copy "$L/LightningStrikeMesh=$M/Strike" \
  --copy "$L/Meshes/Contents/ElectricShockwave(Mesh)=$M/Shock" \
  --copy "$L/Meshes/VFX/Thunder=$M/Thunder" \
  --copy "$L/Meshes/VFX/ThunderSpark=$M/Spark"
