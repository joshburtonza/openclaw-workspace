#!/usr/bin/env python3
# csm-tts.py
# Generates speech via Sesame CSM-1B HuggingFace Space (A10G GPU).
# Drop-in replacement for minimax-tts-to-opus.sh
#
# Usage:
#   python3 csm-tts.py "Text to speak" /output/path.opus
#   python3 csm-tts.py "Text to speak" /output/path.wav  (skip opus conversion)
#
# Voice style: "conversational" (default) or "read_speech"

import sys
import os
import subprocess
import tempfile
import shutil

VENV_PYTHON = os.path.join(os.path.dirname(__file__), "csm/.venv/bin/python3")
PROMPTS_DIR = os.path.join(os.path.dirname(__file__), "csm/prompts")
HF_TOKEN = os.environ.get("HUGGINGFACE_API_KEY", "")
SPACE_URL = "sesame/csm-1b"

def generate(text: str, output_path: str, voice: str = "conversational"):
    prompt_a = os.path.join(PROMPTS_DIR, f"{voice}_a.wav")
    prompt_b = os.path.join(PROMPTS_DIR, f"{voice}_b.wav")

    if not os.path.exists(prompt_a):
        prompt_a = os.path.join(PROMPTS_DIR, "conversational_a.wav")
        prompt_b = os.path.join(PROMPTS_DIR, "conversational_b.wav")

    # Run inference in the venv that has gradio_client installed
    script = f"""
import sys
sys.stdout.reconfigure(line_buffering=True)

from gradio_client import Client, handle_file
import shutil, os

client = Client("{SPACE_URL}", token="{HF_TOKEN}")

result = client.predict(
    text_prompt_speaker_a="Hey, how are you doing today?",
    text_prompt_speaker_b="Pretty good, thanks for asking.",
    audio_prompt_speaker_a=handle_file("{prompt_a}"),
    audio_prompt_speaker_b=handle_file("{prompt_b}"),
    gen_conversation_input={repr(text)},
    api_name="/infer"
)

print("RESULT_PATH:" + str(result))
"""

    tmp = tempfile.NamedTemporaryFile(suffix=".py", delete=False, mode="w")
    tmp.write(script)
    tmp.close()

    try:
        proc = subprocess.run(
            [VENV_PYTHON, tmp.name],
            capture_output=True, text=True, timeout=120
        )
        if proc.returncode != 0:
            print(f"[csm-tts] error: {proc.stderr}", file=sys.stderr)
            sys.exit(1)

        wav_path = None
        for line in proc.stdout.splitlines():
            if line.startswith("RESULT_PATH:"):
                wav_path = line.split("RESULT_PATH:", 1)[1].strip()

        if not wav_path or not os.path.exists(wav_path):
            print(f"[csm-tts] no output file. stdout: {proc.stdout}", file=sys.stderr)
            sys.exit(1)

        if output_path.endswith(".opus"):
            ret = subprocess.run([
                "ffmpeg", "-y", "-i", wav_path,
                "-c:a", "libopus", "-b:a", "48k",
                output_path
            ], capture_output=True)
            if ret.returncode != 0:
                print(f"[csm-tts] ffmpeg failed: {ret.stderr.decode()}", file=sys.stderr)
                sys.exit(1)
        else:
            shutil.copy(wav_path, output_path)

        print(f"[csm-tts] saved to {output_path}")

    finally:
        os.unlink(tmp.name)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: csm-tts.py <text> <output.opus|output.wav>", file=sys.stderr)
        sys.exit(1)
    generate(sys.argv[1], sys.argv[2], voice=sys.argv[3] if len(sys.argv) > 3 else "conversational")
