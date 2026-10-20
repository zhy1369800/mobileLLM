#!/usr/bin/env bash
# Build the llama.cpp XCFramework that Packages/LLMEngineLlama vendors.
#
# The framework is NOT committed (~355 MB). This script clones mainline llama.cpp at a pinned commit,
# builds the official XCFramework (Metal embedded — no .metallib to ship), trims it to the iOS + macOS
# slices, and drops it at Packages/LLMEngineLlama/Vendor/llama.xcframework. Re-run after a fresh clone.
#
#   ./scripts/build-llama-xcframework.sh
#
# Requirements: Xcode + CMake. Takes ~15–25 min (a full multi-platform llama.cpp build).
set -euo pipefail

# Mainline ggml-org/llama.cpp — v0.6.0 (2026-10-05) adds up to ~3x faster few-row matrix
# multiplication on Apple GPUs (the batch-1 decode bottleneck), which is the main reason
# mobileLLM decodes slower than llama.rn on the same model. Also includes Q1_0 (1-bit) +
# qwen3_5 hybrid (Gated-DeltaNet) Metal kernels, so one framework serves every Bonsai size.
# SHA below = refs/tags/v0.6.0 target commit.
LLAMA_COMMIT="d81235049384534c167caea52b85a694f6103d14"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Packages/LLMEngineLlama/Vendor/llama.xcframework"
WORK="${LLAMA_CPP_DIR:-$ROOT/.llama-build}"

if [ ! -d "$WORK/.git" ]; then
    echo "Cloning llama.cpp into $WORK …"
    git clone https://github.com/ggml-org/llama.cpp "$WORK"
fi
git -C "$WORK" fetch --depth 1 origin "$LLAMA_COMMIT"
git -C "$WORK" checkout "$LLAMA_COMMIT"

# Native MTP bridge injection — KEEP COMMENTED: llama_mtp_bridge.cpp is still an empty stub
# (predict() always returns 0 drafts, see scripts/mtp_bridge/llama_mtp_bridge.cpp). Injecting it
# only makes NativeMtpDriver.isCompiledIn true while every step still falls back to Prompt Lookup,
# and the "initialized successfully" log becomes misleading. Real MTP requires llama.cpp's own
# speculative/MTP API (PR #22673, draft-head GGUF) wired in LlamaEngine — a feature, not this stub.
# echo "Injecting native MTP bridge sources …"
# mkdir -p "$WORK/include" "$WORK/src"
# cp "$ROOT/scripts/mtp_bridge/llama_mtp_bridge.h" "$WORK/include/"
# cp "$ROOT/scripts/mtp_bridge/llama_mtp_bridge.cpp" "$WORK/src/"

echo "Building XCFramework (this is the slow part) …"
( cd "$WORK" && ./build-xcframework.sh )

echo "Trimming to iOS + macOS slices …"
BUILT="$WORK/build-apple/llama.xcframework"
rm -rf "$BUILT"/tvos-* "$BUILT"/xros-*
python3 - "$BUILT/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, "rb") as f: d = plistlib.load(f)
keep = {"ios-arm64", "ios-arm64_x86_64-simulator", "macos-arm64_x86_64"}
d["AvailableLibraries"] = [l for l in d["AvailableLibraries"] if l["LibraryIdentifier"] in keep]
with open(p, "wb") as f: plistlib.dump(d, f)
PY

# Publishing MTP bridge headers — keep commented for the same reason as the injection above (stub).
# echo "Publishing MTP bridge headers to framework slices …"
# for slice in "$BUILT"/*; do
#     if [ -d "$slice/Headers" ]; then
#         cp "$ROOT/scripts/mtp_bridge/llama_mtp_bridge.h" "$slice/Headers/"
#     fi
#     if [ -d "$slice/llama.framework/Headers" ]; then
#         cp "$ROOT/scripts/mtp_bridge/llama_mtp_bridge.h" "$slice/llama.framework/Headers/"
#     fi
# done

echo "Installing to $DEST …"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$BUILT" "$DEST"
echo "Done. $(du -sh "$DEST" | cut -f1) at $DEST"
