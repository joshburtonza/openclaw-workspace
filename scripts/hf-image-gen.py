#!/usr/bin/env python3
# hf-image-gen.py
# Generate images via HuggingFace Inference API (FLUX.1-schnell).
#
# Usage:
#   python3 hf-image-gen.py "prompt text" /output/path.png
#
# Reads HUGGINGFACE_API_KEY from environment.

import sys
import os

VENV_PYTHON = os.path.join(os.path.dirname(__file__), "tts/csm/.venv/bin/python3")
HF_TOKEN = os.environ.get("HUGGINGFACE_API_KEY", "")
MODEL = "black-forest-labs/FLUX.1-schnell"


def generate(prompt: str, output_path: str):
    script = f"""
import os, sys
from huggingface_hub import InferenceClient

token = {repr(HF_TOKEN)}
client = InferenceClient(token=token)
img = client.text_to_image({repr(prompt)}, model={repr(MODEL)})
img.save({repr(output_path)})
print("RESULT_PATH:" + {repr(output_path)})
"""

    import tempfile, subprocess

    tmp = tempfile.NamedTemporaryFile(suffix=".py", delete=False, mode="w")
    tmp.write(script)
    tmp.close()

    try:
        proc = subprocess.run(
            [VENV_PYTHON, tmp.name],
            capture_output=True, text=True, timeout=120
        )
        if proc.returncode != 0:
            print(f"[hf-image] error: {proc.stderr}", file=sys.stderr)
            sys.exit(1)

        found = False
        for line in proc.stdout.splitlines():
            if line.startswith("RESULT_PATH:"):
                found = True
                break

        if not found or not os.path.exists(output_path):
            print(f"[hf-image] no output. stdout: {proc.stdout}", file=sys.stderr)
            sys.exit(1)

        print(f"[hf-image] saved to {output_path}")

    finally:
        os.unlink(tmp.name)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: hf-image-gen.py <prompt> <output.png>", file=sys.stderr)
        sys.exit(1)
    generate(sys.argv[1], sys.argv[2])
