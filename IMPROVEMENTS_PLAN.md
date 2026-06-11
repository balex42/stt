# Meetingprotokoll-Generator — Improvement Plan

Instructions for implementing all planned improvements. Designed to be worked through
with Claude Code (`claude` in the repo root), but usable as a manual checklist too.

**How to use with Claude Code:** work phase by phase. Paste one phase at a time as a
prompt (or say "implement Phase 1 from IMPROVEMENTS_PLAN.md" after committing this file
to the repo). Commit after each phase. Do NOT paste the whole file at once — the phases
are ordered so the app stays working after each one, and smaller tasks get better results.

**Repo context for the agent:** read CLAUDE.md first. Key invariants to preserve:

- Zero npm dependencies at runtime; `serve.js` uses only Node stdlib.
- `static/index.html` is the entire app, one ES-module script, top-level await.
- Everything must keep working in both modes: CDN dev mode (`node serve.js`) and
  air-gapped Docker mode (local `/vendor/` + `/models/`). The `useLocalVendor` HEAD
  probe decides which mode is active.
- All inference is client-side (WebGPU). The server only serves static files.
- UI language is German; code comments in English.

---

## Phase 1 — Security & infra fixes (small, do first)

### 1.1 Stop leaking HF_TOKEN into image layers

Problem: `ARG HF_TOKEN` in the Dockerfile bakes the token into the downloader stage's
layer metadata, and `cache-to: type=gha,mode=max` pushes those layers to the shared
GitHub Actions cache. It also invalidates all download layers whenever the token rotates.

Fix using BuildKit secrets:

- Dockerfile: remove `ARG HF_TOKEN` and the `/tmp/hf.curlrc` ARG-based block. Instead,
  at the top of each `RUN` that calls curl against huggingface.co, mount the secret:

  ```dockerfile
  RUN --mount=type=secret,id=hf_token \
      if [ -s /run/secrets/hf_token ]; then \
        echo "header = \"Authorization: Bearer $(cat /run/secrets/hf_token)\"" > /tmp/hf.curlrc; \
      else touch /tmp/hf.curlrc; fi && \
      ... curl -K /tmp/hf.curlrc ...
  ```

  (Combine the curlrc creation into each download RUN, or write it once in a RUN that
  also mounts the secret — secret mounts are per-RUN and never persist in layers.)

- `.github/workflows/docker.yml`: in the build-push-action step, replace
  `build-args: HF_TOKEN=...` with:

  ```yaml
  secrets: |
    hf_token=${{ secrets.HF_TOKEN }}
  ```

- Update the Dockerfile comment to document the new local invocation:
  `docker build --secret id=hf_token,src=$HOME/.cache/huggingface/token .`
  and note that `docker compose build` users need `secrets:` support or can build
  without the token (it's optional outside CI).

Acceptance: `docker history <image>` and the build log show no token; build succeeds
with and without the secret provided.

### 1.2 Cache-Control headers in serve.js

Add a `Cache-Control` header per path class, keeping stdlib-only:

- `/vendor/*` and `/models/*` → `public, max-age=31536000, immutable`
  (contents only change when the image is rebuilt).
- everything else (notably `/` → index.html) → `no-cache`.

Acceptance: `curl -sI localhost:8000/vendor/transformers.js | grep -i cache` shows
immutable; index.html shows no-cache.

### 1.3 Range request support in serve.js

Support a single `bytes=start-end` range (parse `req.headers.range`; respond 206 with
`Content-Range`, `Accept-Ranges: bytes`, and `createReadStream(filePath, {start, end})`;
respond 416 for unsatisfiable ranges; ignore multi-range requests by serving 200).
Keep all SECURITY headers on every response.

Acceptance: `curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-99' localhost:8000/` → 206
with Content-Length 100; invalid range → 416.

---

## Phase 2 — LLM output quality (small JS changes)

### 2.1 Sampler settings + automatic retry

In `generateProtocol()` in static/index.html:

- Change `samplerParams` to `{ temperature: 0.3, k: 40, p: 0.9 }`.
- If `parseProtocol(buffer)` returns the fallback object (it has `raw_output`), retry
  the generation ONCE with a fresh conversation and an appended instruction:
  `"Antworte ausschließlich mit dem JSON-Objekt."` Show status
  `"Antwort war kein gültiges JSON – zweiter Versuch…"`. Only after the second failure
  render the raw_output fallback.

### 2.2 Meeting metadata form

Add three optional inputs above the tabs (or in a collapsible row inside the card):
Meeting-Titel, Datum (default today, `<input type="date">`), Teilnehmer
(comma-separated free text). Then:

- Inject into the user message sent to Gemma, before the transcript:

  ```
  Meeting: <titel>
  Datum: <datum>
  Teilnehmer: <namen>

  Meetingtranskript:
  ...
  ```

  Omit empty lines. Add one sentence to SYSTEM_PROMPT: task owners
  ("verantwortlich") should be matched against the participant list when possible.
- Use title/date in the rendered protocol header, the .md download content, and the
  download filename (slugified title).

Acceptance: with participants given, generated Aufgaben prefer those names; .md header
contains title/date.

### 2.3 Context length guard

Before sending to Gemma, estimate tokens (`transcript.length / 4` is fine for German).
If estimate + prompt overhead > ~15000, do map-reduce:

1. Split the transcript into chunks of ~8000 estimated tokens at sentence boundaries.
2. For each chunk, run a separate conversation with a short system prompt:
   "Fasse diesen Transkriptabschnitt sachlich zusammen. Erhalte alle Entscheidungen,
   Aufgaben (mit Verantwortlichen und Fristen) und Themen. Antworte als Fließtext."
   Show progress in status: "Abschnitt 2/5 wird zusammengefasst…".
3. Concatenate the chunk summaries and run the normal protocol prompt over them,
   with a note in the user message that this is a condensed transcript.

Keep the single-pass path unchanged for short transcripts. The .md download must still
contain the FULL raw transcript, not the condensed one.

Acceptance: feed a long text (can simulate by pasting into the transcript textarea and
hitting "Protokoll neu erstellen") — no truncation error, visible per-chunk progress.

---

## Phase 3 — Resource management & resilience

### 3.1 Storage management UI

- Footer: add a line showing OPFS usage via `navigator.storage.estimate()`
  (e.g. "Lokale Modelle: 4,1 GB belegt") plus a button "Modelle löschen" that removes
  the `gemma-cache` OPFS directory (`root.removeEntry('gemma-cache', {recursive: true})`)
  and clears the Transformers.js browser Cache API entries
  (`(await caches.keys()).filter(...)` — delete caches whose name contains
  'transformers'). Refresh the usage display afterwards.
- After the first successful Gemma download in `fetchWithOPFSCache`, call
  `navigator.storage.persist()` (fire-and-forget) so Chrome doesn't evict the model.

### 3.2 Dispose conversations between regenerations

In `generateProtocol()`, after consuming `sendMessageStreaming`, dispose the
conversation if the LiteRT-LM API exposes it (check the bundled
`@litert-lm/core` typings/source for `close()`, `delete()` or similar on the
conversation object; if none exists, document that in a comment instead of guessing).

### 3.3 Session persistence + unload guard

- After a successful run, save `{transcript, protocol, meta, timestamp}` to
  `localStorage` under one key (transcripts are small; guard with try/catch for quota).
- On page load, if a saved session exists, show a dismissible status line:
  "Letzte Sitzung vom <Zeit> wiederherstellen?" with a button that repopulates the
  results card (transcript textarea + rendered protocol + enabled buttons).
- Add a `beforeunload` handler that warns while `setAllBusy(true)` is active
  (track a module-level `busy` flag).

---

## Phase 4 — Transcription quality & UX

### 4.1 Language selection / auto-detect

- Add a small `<select>` near the tabs: Deutsch (default) / English / Auto.
- Pass the selection into the worker's transcribe message; map "Auto" to
  `language: null` (Transformers.js Whisper then auto-detects; verify against the
  bundled transformers.js source — if null isn't accepted, omit the `language` option
  entirely for auto).
- The filler-word regex in `cleanTranscript` is German-specific; extend it with
  English fillers (uh, um, erm) and apply based on selected language.

### 4.2 Incremental live transcription

Currently the recording tab buffers everything and transcribes at the end. Change to:

- `mediaRecorder.start()` stays as is, BUT additionally tee the live audio through an
  `AudioContext` + `AudioWorkletNode` (or `ScriptProcessorNode` fallback) that
  accumulates 16 kHz Float32 samples directly — this avoids re-decoding webm chunks,
  which is unreliable because MediaRecorder timeslice chunks aren't independently
  decodable containers.
- Every ~25 s of accumulated audio, send the segment (plus ~3 s overlap from the
  previous segment) to the existing Whisper worker for transcription while recording
  continues. Append results to the transcript textarea progressively. Use a simple
  overlap-dedup at the seam (reuse the word-window logic with a small window).
- On stop: transcribe the final remainder, then run `cleanTranscript` over the whole
  text once and proceed to protocol generation as before.
- The worker must serialize requests (queue) since one segment may still be running
  when the next arrives.
- Keep the upload path unchanged.

Acceptance: during a multi-minute recording, transcript text appears progressively;
stopping yields the protocol within seconds, not minutes; no duplicated seam phrases.

### 4.3 VAD pre-segmentation for uploads (optional, do last in this phase)

Integrate Silero VAD (ONNX, ~2 MB; `onnx-community/silero-vad` on HF runs via
Transformers.js/onnxruntime-web) in the worker:

- Run VAD over the 16 kHz audio, get speech segments, merge gaps < 0.5 s, then cut the
  audio into chunks ≤ 30 s at the longest silence within each window.
- Feed chunks to Whisper sequentially without the 30 s sliding-window/stride options
  (no overlap needed when cutting at silence), concatenating results.
- Docker mode: add the VAD model files to the Dockerfile download stage under
  `models/` alongside Whisper, same pattern.
- Once stable, reduce `cleanTranscript`'s dedup aggressiveness (raise MIN_LEN to 8) —
  repetition loops should be much rarer.

Acceptance: a file with long silences transcribes faster and without hallucinated
repetition; air-gapped Docker build still works offline.

### 4.4 Small UX wins

- Drag & drop onto the upload card (`dragover`/`drop` on `.file-label`, set
  `fileInput.files` via DataTransfer or store the File directly).
- "Kopieren" buttons on both result panes (`navigator.clipboard.writeText`).
- Time-remaining estimate during transcription: you already compute current audio
  position and total duration in the `chunk` handler; track wall-clock start, derive
  speed = processed_audio_s / elapsed_s, show "≈ X:XX verbleibend" once speed is stable
  (after ~20 s processed).

---

## Phase 5 — Speaker diarization (largest task, separate effort)

Goal: coarse "Sprecher 1 / Sprecher 2" labels in the transcript so Gemma can attribute
decisions and tasks.

Suggested approach (research current state before coding — verify model availability
on HuggingFace at implementation time):

1. Use `onnx-community/pyannote-segmentation-3.0` (or current equivalent) via
   Transformers.js in the existing worker to get per-frame speaker activity.
2. Cluster: for short meetings, simple agglomerative clustering on speaker embeddings
   (`onnx-community/wespeaker-voxceleb-resnet34-LM` or similar) over the segmentation
   output. If embedding models prove impractical in-browser, fall back to
   segmentation-only local speaker indices (good enough for turn-taking labels).
3. Merge diarization segments with Whisper chunk timestamps
   (`return_timestamps: true` already gives per-chunk times) — assign each transcript
   chunk the dominant speaker.
4. Render transcript with `Sprecher N:` prefixes; make it a toggle (checkbox
   "Sprechererkennung", default off) since it adds significant compute.
5. Update SYSTEM_PROMPT: speaker labels may appear and should be used for
   "verantwortlich" attribution (participants form, if filled, maps names to speakers
   only when the transcript itself makes the mapping explicit — no guessing).
6. Docker: add required model files to the download stage.

Acceptance: two-speaker test recording shows alternating speaker labels broadly
matching turns; toggle off reproduces current behavior exactly.

---

## Testing notes (all phases)

- Manual test matrix: dev mode (CDN) and Docker mode (local vendor), Chrome ≥ 123.
- Keep the no-JSPI fallback path working (transcription only, friendly error).
- After Dockerfile changes, verify the air-gapped property: run the container with
  networking disabled (`docker run --network none ...` won't serve, but you can block
  outbound and check the browser devtools network tab — no requests should leave
  localhost).
- There is no test suite; do not introduce a build step or npm runtime dependencies.
