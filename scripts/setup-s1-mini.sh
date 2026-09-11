#!/bin/bash
# Registers Superwhisper's s1-mini transcript normalizer with Ollama.
set -euo pipefail

if ! command -v ollama >/dev/null; then
    echo "ollama is not installed. Install it from https://ollama.com/download, start the server, then re-run this script." >&2
    exit 1
fi

if ollama show s1-mini >/dev/null 2>&1; then
    echo "s1-mini is already registered with Ollama; nothing to do."
    exit 0
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

echo "Downloading s1-mini Q4_K_M (~460 MB)..."
curl -fL --progress-bar -o "$workdir/s1-mini-q4_k_m.gguf" \
    "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/main/s1-mini-q4_k_m.gguf"

cat > "$workdir/Modelfile" <<'EOF'
FROM ./s1-mini-q4_k_m.gguf

SYSTEM """You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."""

TEMPLATE """<|im_start|>system
{{ .System }}<|im_end|>
<|im_start|>user
{{ .Prompt }}<|im_end|>
<|im_start|>assistant
<think>

</think>

"""

PARAMETER temperature 0
PARAMETER num_ctx 4096
EOF

(cd "$workdir" && ollama create s1-mini -f Modelfile)

echo
echo "Done. Enable local dictation cleanup in Kleio's Dictation settings to use s1-mini."
