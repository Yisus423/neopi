#!/usr/bin/env bash
# Captures the real OpenRouter SSE wire format once, so the L1 tests can
# replay the actual wire against the real parser without any API key.
# Requires OPENROUTER_API_KEY in .env. Run manually:
#   bash tests/capture_openrouter.sh
set -euo pipefail
cd "$(dirname "$0")/.."
KEY=$(grep '^OPENROUTER_API_KEY=' .env | cut -d= -f2- | tr -d '"' | tr -d "'")
if [ -z "${KEY:-}" ]; then echo "no OPENROUTER_API_KEY in .env" >&2; exit 1; fi
MODEL="inclusionai/ling-3.0-flash-vl"
mkdir -p tests/fixtures
# The plain text stream: the content deltas and the finish reason.
curl -sN https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Escribí dos frases sobre el mar.\"}],\"stream\":true}" \
  > tests/fixtures/openrouter-text-stream.txt
# The tool-call stream: the tool_calls deltas stream their argument JSON in
# fragments — the exact wire the provider layer has to reassemble.
curl -sN https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Escribí el archivo notas/x.txt con el contenido hola\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"write\",\"description\":\"Escribe un archivo en el workspace\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"ruta relativa al workspace\"},\"content\":{\"type\":\"string\",\"description\":\"contenido del archivo\"}},\"required\":[\"path\",\"content\"]}}}],\"tool_choice\":\"auto\",\"stream\":true}" \
  > tests/fixtures/openrouter-tool-stream.txt
wc -c tests/fixtures/*.txt
