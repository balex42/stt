# Stage 1 — build/download all assets at build time for air-gapped operation
FROM node:22-alpine AS downloader
RUN apk add --no-cache curl

WORKDIR /out
RUN mkdir -p vendor/ort vendor/litert-lm-wasm \
    models/onnx-community/whisper-large-v3-turbo/resolve/main/onnx \
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
RUN BASE=https://huggingface.co/onnx-community/whisper-large-v3-turbo/resolve/main && \
    DEST=models/onnx-community/whisper-large-v3-turbo/resolve/main && \
    for f in config.json generation_config.json tokenizer.json tokenizer_config.json \
              preprocessor_config.json special_tokens_map.json vocab.json merges.txt \
              normalizer.json added_tokens.json quantize_config.json; do \
      curl -fsSL "${BASE}/${f}" -o "${DEST}/${f}"; \
    done

# ── Whisper ONNX weights (~560 MB total) ──────────────────────────────────
RUN BASE=https://huggingface.co/onnx-community/whisper-large-v3-turbo/resolve/main/onnx && \
    DEST=models/onnx-community/whisper-large-v3-turbo/resolve/main/onnx && \
    curl -fsSL "${BASE}/encoder_model_fp16.onnx" -o "${DEST}/encoder_model_fp16.onnx"
RUN BASE=https://huggingface.co/onnx-community/whisper-large-v3-turbo/resolve/main/onnx && \
    DEST=models/onnx-community/whisper-large-v3-turbo/resolve/main/onnx && \
    curl -fsSL "${BASE}/decoder_model_merged_q4.onnx" -o "${DEST}/decoder_model_merged_q4.onnx"

# ── Gemma 4 E2B model (~2 GB) ─────────────────────────────────────────────
RUN curl -fsSL \
    'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.litertlm' \
    -o models/gemma/gemma-4-E2B-it-web.litertlm

# Stage 2 — minimal production image
FROM node:22-alpine
WORKDIR /app
COPY serve.js .
COPY static/ static/
COPY --from=downloader /out/vendor static/vendor/
COPY --from=downloader /out/models static/models/
EXPOSE 8000
CMD ["node", "serve.js"]
