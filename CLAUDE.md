# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the app

**Without Docker:**
```bash
node serve.js
```

**With Docker:**
```bash
docker compose up --build
```

Open `http://localhost:8000` in a browser. There are no tests and no build step.

## Architecture

This is a **zero-dependency, browser-only AI app**. All inference runs client-side via WebGPU — the server does nothing except serve static files.

```
serve.js          Node.js stdlib HTTP server (no npm packages)
static/index.html Entire application — one file, ES module script
Dockerfile        node:22-alpine, copies serve.js + static/
docker-compose.yml  Exposes port 8000
```

### Why a server at all
`SharedArrayBuffer` (required by WebGPU/WASM threading) needs two HTTP response headers that `file://` and plain `http-server` won't set:
- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

`serve.js` exists solely to set these headers on every response.

### `static/index.html` internals

The script tag is `type="module"` with top-level `await`. Two CDN libraries are imported at runtime:

| Library | CDN import | Purpose |
|---------|-----------|---------|
| `@huggingface/transformers` v3 | jsdelivr | Whisper transcription via WebGPU |
| `@litert-lm/core` | jsdelivr | Gemma 4 E2B/E4B protocol generation via WebGPU |

**Model IDs** are defined as constants at the top of the script block — change them there if HuggingFace paths change:
```javascript
const WHISPER_MODEL = 'onnx-community/whisper-base';
const GEMMA_MODELS  = { E2B: '...', E4B: '...' };
```

**Processing flow:**
1. Audio blob (upload or `MediaRecorder`) → resampled to 16 kHz `Float32Array` via `AudioContext` + `OfflineAudioContext`
2. Whisper pipeline → transcript string
3. LiteRT-LM `Engine.create()` → `createConversation()` → `sendMessageStreaming()` → buffered JSON → `JSON.parse()`
4. Results rendered in-page; `.md` download built client-side

Both AI singletons (`asr`, `llmEngine`) are lazy — loaded on first use and reused. Switching the E2B/E4B toggle calls `engine.delete()` to free GPU memory before the next load.

Models are downloaded from HuggingFace on first use and cached in the browser's Cache API automatically by the libraries.
