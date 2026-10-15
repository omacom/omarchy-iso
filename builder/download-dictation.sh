#!/bin/bash
# Shared multilingual model, downloaded only for --with-dictation.
set -euo pipefail
assets=$1
mkdir -p "$assets"
curl -fL --retry 3 https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin -o "$assets/ggml-small.bin.part"
printf '%s  %s\n' 1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b "$assets/ggml-small.bin.part" | sha256sum -c -
mv "$assets/ggml-small.bin.part" "$assets/ggml-small.bin"
cp "$(dirname -- "${BASH_SOURCE[0]}")/WHISPER-LICENSE" "$assets/"
