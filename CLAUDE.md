# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running the app

**Without Docker (CDN mode):**
```bash
node serve.js
```

**With Docker (air-gapped mode):**
```bash
docker compose up --build
```

Open `http://localhost:8000` in a browser. There are no tests and no build step.

## Architecture

This is a **zero-dependency, browser-only AI app**. All inference runs client-side via WebGPU/WASM — the server does nothing except serve static files.

```
serve.js            Node.js stdlib HTTP server (no npm packages)
static/index.html   Entire application — one file, ES module script
Dockerfile          node:22-alpine; stage 1 downloads all models/vendors, stage 2 serves them
docker-compose.yml  Exposes port 8000
CREDITS             Third-party license attributions
```

### Why a server at all
`SharedArrayBuffer` (required by WebGPU/WASM threading) needs two HTTP response headers that `file://` and plain `http-server` won't set:
- `Cross-Origin-Opener-Policy: same-origin`
- `Cross-Origin-Embedder-Policy: require-corp`

`serve.js` also adds `Cache-Control: immutable` for `/vendor/` and `/models/` paths and supports HTTP range requests (206 partial content) so large model files stream correctly.

### Two operating modes

A HEAD probe to `/vendor/litert-lm.js` at startup decides the mode:

| Mode | How triggered | Libraries | Models |
|------|--------------|-----------|--------|
| **CDN** | `node serve.js` (no vendor dir) | jsdelivr CDN imports | Downloaded from HuggingFace on first use; cached in browser Cache API |
| **Air-gapped** | `docker compose up` | `/vendor/transformers.js`, `/vendor/litert-lm.js` | `/models/…` (baked into image) |

### `static/index.html` internals

One `<script type="module">` with top-level `await`. Key constants at the top:

```javascript
const WHISPER_MODEL = 'onnx-community/whisper-large-v3-turbo';
const GEMMA_MODEL   = '/models/gemma/...' | 'https://huggingface.co/...';
const DIAR_MODEL    = 'onnx-community/pyannote-segmentation-3.0';  // in worker
```

### Processing pipeline

**Upload path:**
1. `blobToFloat32(blob)` — decode + resample to 16 kHz via `AudioContext` + `OfflineAudioContext`
2. `workerRun('transcribe', { audio, language, returnChunks? })` — Whisper in Web Worker
3. Optional: `workerRun('diarize', { audio })` — pyannote speaker diarization in same worker
4. `mergeTranscriptWithSpeakers(chunks, segments)` or `cleanTranscript(text, lang)`
5. `generateProtocol(transcript, meta)` — Gemma 4 E4B via LiteRT-LM

**Live recording path:**
1. `AudioContext({ sampleRate: 16000 })` + `AudioWorkletNode` (or `ScriptProcessorNode` fallback) captures raw 16 kHz PCM
2. Every 25 s of accumulated audio → `workerRun('transcribe', ...)` queued via `liveTranscribeQueue` promise chain; results appended with overlap dedup
3. On stop: flush remainder → optional diarization (re-decodes MediaRecorder blob) → `cleanTranscript` → `generateProtocol`

### Web Worker (`WHISPER_WORKER_SRC`)

Inlined as a blob URL. Handles three message types:

| Message | Action |
|---------|--------|
| `load` | Loads Whisper ASR pipeline via `pipeline('automatic-speech-recognition', ...)` on WebGPU |
| `transcribe` | Runs Whisper; returns `{ type:'complete', text, chunks[] }` |
| `diarize` | Lazily loads pyannote `AutoModelForAudioFrameClassification` + `AutoProcessor`; returns `{ type:'diarized', segments[] }` |

Progress events (`type:'progress'`) from both models flow through the existing progress bar UI.

### LLM (Gemma 4 E4B)

- Loaded via `Engine.create()` from `@litert-lm/core`; large model file cached in OPFS (`gemma-cache/`)
- `fetchWithOPFSCache` handles download + `.done` marker; calls `navigator.storage.persist()` on first success
- Each generation creates a fresh `Conversation` via `createConversation()` and disposes it with `conv.delete()` afterward
- Long transcripts (> ~15 000 estimated tokens) trigger map-reduce: chunk summaries → final protocol pass

### Key UI features

- **Meeting metadata form** (title, date, participants) above the tabs — injected into the Gemma prompt
- **Language select** (Deutsch / English / Auto) — `null` language passed to Whisper omits the option entirely, enabling true auto-detect
- **Sprechererkennung checkbox** (default off) — enables pyannote diarization; adds `Sprecher N:` prefixes to transcript
- **Session persistence** — saves `{transcript, protocol, meta, timestamp}` to `localStorage`; restores on reload
- **Storage management** — footer shows OPFS usage; "Modelle löschen" button disposes engine + revokes blob URL + removes OPFS + clears transformers caches

### Dockerfile

Three-stage model download pattern: each `RUN` uses `--mount=type=secret,id=hf_token` (token is never in a layer), writes a temporary curlrc, downloads, then **removes the curlrc** with `rm -f /tmp/hf.curlrc` in the same RUN so no token survives into any layer.

Models baked into the image:
- `onnx-community/whisper-large-v3-turbo` (encoder fp16 + decoder q4, ~560 MB)
- `onnx-community/pyannote-segmentation-3.0` (fp32, ~6 MB)
- `litert-community/gemma-4-E4B-it-litert-lm` (~3.5 GB)

### Invariants to preserve

- Zero npm runtime dependencies; `serve.js` uses only Node stdlib
- `static/index.html` is the entire app — one file, one ES-module script
- Both CDN and air-gapped Docker modes must keep working; the `useLocalVendor` HEAD probe is the branch point
- All inference is client-side; the server only serves static files
- UI language is German; code comments in English
- No build step, no test suite — manual testing in Chrome ≥ 123
