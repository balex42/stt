# Stage 1 — build/download all assets at build time for air-gapped operation
FROM node:22-alpine AS downloader
RUN apk add --no-cache curl

# Optional HuggingFace token — passed as a BuildKit secret, never baked into layers.
# Local build:  docker build --secret id=hf_token,src=$HOME/.cache/huggingface/token .
# GitHub Actions: workflow passes secrets.HF_TOKEN as hf_token (see .github/workflows/docker.yml).
# docker compose build: requires secrets: support; omit for token-less builds (optional outside CI).

WORKDIR /out
RUN mkdir -p vendor/ort vendor/litert-lm-wasm \
    models/onnx-community/whisper-large-v3-turbo/resolve/main/onnx \
    models/onnx-community/pyannote-segmentation-3.0/resolve/main/onnx \
    models/gemma

# ── Install packages and build self-contained ESM bundles with esbuild ─────
WORKDIR /bundle
RUN npm install @huggingface/transformers@3.8.1 @litert-lm/core@0.13.1 esbuild

# Bundle transformers.js — inlines onnxruntime-common and all other bare deps
RUN node_modules/.bin/esbuild \
    node_modules/@huggingface/transformers/dist/transformers.web.js \
    --bundle --format=esm --platform=browser \
    --outfile=/out/vendor/transformers.js

# Bundle litert-lm — inlines @litertjs/wasm-utils and all other bare deps
RUN node_modules/.bin/esbuild \
    node_modules/@litert-lm/core/dist/index.js \
    --bundle --format=esm --platform=browser \
    --outfile=/out/vendor/litert-lm.js

# Copy WASM files straight from installed packages (no re-download needed)
RUN cp node_modules/@huggingface/transformers/dist/ort-wasm-simd-threaded.jsep.wasm \
       /out/vendor/ort/ && \
    cp node_modules/@huggingface/transformers/dist/ort-wasm-simd-threaded.jsep.mjs \
       /out/vendor/ort/
RUN cp node_modules/@litert-lm/core/wasm/litertlm_wasm_internal.js \
       /out/vendor/litert-lm-wasm/ && \
    cp node_modules/@litert-lm/core/wasm/litertlm_wasm_internal.wasm \
       /out/vendor/litert-lm-wasm/ && \
    cp node_modules/@litert-lm/core/wasm/litertlm_wasm_compat_internal.js \
       /out/vendor/litert-lm-wasm/ && \
    cp node_modules/@litert-lm/core/wasm/litertlm_wasm_compat_internal.wasm \
       /out/vendor/litert-lm-wasm/

# ── Whisper model JSON configs ─────────────────────────────────────────────
WORKDIR /out
RUN --mount=type=secret,id=hf_token \
    if [ -s /run/secrets/hf_token ]; then \
      echo "header = \"Authorization: Bearer $(cat /run/secrets/hf_token)\"" > /tmp/hf.curlrc; \
    else touch /tmp/hf.curlrc; fi && \
    BASE=https://huggingface.co/onnx-community/whisper-large-v3-turbo/resolve/main && \
    DEST=models/onnx-community/whisper-large-v3-turbo/resolve/main && \
    for f in config.json generation_config.json tokenizer.json tokenizer_config.json \
              preprocessor_config.json special_tokens_map.json vocab.json merges.txt \
              normalizer.json added_tokens.json quantize_config.json; do \
      curl -fsSL --retry 3 --retry-delay 10 -K /tmp/hf.curlrc "${BASE}/${f}" -o "${DEST}/${f}"; \
    done && \
    rm -f /tmp/hf.curlrc

# ── Whisper ONNX weights (~560 MB total) ──────────────────────────────────
RUN --mount=type=secret,id=hf_token \
    if [ -s /run/secrets/hf_token ]; then \
      echo "header = \"Authorization: Bearer $(cat /run/secrets/hf_token)\"" > /tmp/hf.curlrc; \
    else touch /tmp/hf.curlrc; fi && \
    BASE=https://huggingface.co/onnx-community/whisper-large-v3-turbo/resolve/main/onnx && \
    DEST=models/onnx-community/whisper-large-v3-turbo/resolve/main/onnx && \
    curl -fsSL --retry 3 --retry-delay 10 -K /tmp/hf.curlrc \
      "${BASE}/encoder_model_fp16.onnx" -o "${DEST}/encoder_model_fp16.onnx" && \
    rm -f /tmp/hf.curlrc
RUN --mount=type=secret,id=hf_token \
    if [ -s /run/secrets/hf_token ]; then \
      echo "header = \"Authorization: Bearer $(cat /run/secrets/hf_token)\"" > /tmp/hf.curlrc; \
    else touch /tmp/hf.curlrc; fi && \
    BASE=https://huggingface.co/onnx-community/whisper-large-v3-turbo/resolve/main/onnx && \
    DEST=models/onnx-community/whisper-large-v3-turbo/resolve/main/onnx && \
    curl -fsSL --retry 3 --retry-delay 10 -K /tmp/hf.curlrc \
      "${BASE}/decoder_model_merged_q4.onnx" -o "${DEST}/decoder_model_merged_q4.onnx" && \
    rm -f /tmp/hf.curlrc

# ── Pyannote speaker diarization model (~6 MB) ────────────────────────────
RUN --mount=type=secret,id=hf_token \
    if [ -s /run/secrets/hf_token ]; then \
      echo "header = \"Authorization: Bearer $(cat /run/secrets/hf_token)\"" > /tmp/hf.curlrc; \
    else touch /tmp/hf.curlrc; fi && \
    BASE=https://huggingface.co/onnx-community/pyannote-segmentation-3.0/resolve/main && \
    DEST=models/onnx-community/pyannote-segmentation-3.0/resolve/main && \
    for f in config.json preprocessor_config.json; do \
      curl -fsSL --retry 3 --retry-delay 10 -K /tmp/hf.curlrc "${BASE}/${f}" -o "${DEST}/${f}"; \
    done && \
    curl -fsSL --retry 3 --retry-delay 10 -K /tmp/hf.curlrc \
      "${BASE}/onnx/model.onnx" -o "${DEST}/onnx/model.onnx" && \
    rm -f /tmp/hf.curlrc

# ── Gemma 4 E4B model (~3.5 GB) ───────────────────────────────────────────
RUN --mount=type=secret,id=hf_token \
    if [ -s /run/secrets/hf_token ]; then \
      echo "header = \"Authorization: Bearer $(cat /run/secrets/hf_token)\"" > /tmp/hf.curlrc; \
    else touch /tmp/hf.curlrc; fi && \
    curl -fsSL --retry 3 --retry-delay 10 -K /tmp/hf.curlrc \
      'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it-web.litertlm' \
      -o models/gemma/gemma-4-E4B-it-web.litertlm && \
    rm -f /tmp/hf.curlrc

# Stage 2 — minimal production image
FROM node:22-alpine
RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
COPY serve.js .
COPY static/ static/
COPY --from=downloader /out/vendor static/vendor/
COPY --from=downloader /out/models static/models/
USER app
EXPOSE 8000
CMD ["node", "serve.js"]
