# Stage 1 — download/build all assets at build time for air-gapped operation
FROM node:22-alpine AS downloader
RUN apk add --no-cache curl

WORKDIR /out
RUN mkdir -p vendor/ort vendor/litert-lm-wasm \
    models/onnx-community/whisper-large-v3-turbo/resolve/main/onnx \
    models/gemma

# ── litert-lm: npm install + esbuild → self-contained ESM (no CDN imports) ─
WORKDIR /bundle
RUN npm install @litert-lm/core esbuild
RUN node_modules/.bin/esbuild node_modules/@litert-lm/core/dist/index.js \
    --bundle --format=esm --platform=browser \
    --outfile=/out/vendor/litert-lm.js

# ── transformers.js: extract pre-built Webpack bundle from npm tarball ─────
WORKDIR /out
RUN curl -sL 'https://registry.npmjs.org/@huggingface/transformers/-/transformers-3.8.1.tgz' \
    -o /tmp/tf-bundle.tgz && \
    tar -xzOf /tmp/tf-bundle.tgz package/dist/transformers.web.js \
      > vendor/transformers.js && \
    rm /tmp/tf-bundle.tgz

# ── transformers.js WASM ───────────────────────────────────────────────────
RUN curl -sL 'https://registry.npmjs.org/@huggingface/transformers/-/transformers-3.8.1.tgz' \
    -o /tmp/tf.tgz && \
    tar -xzOf /tmp/tf.tgz package/dist/ort-wasm-simd-threaded.jsep.wasm \
      > vendor/ort/ort-wasm-simd-threaded.jsep.wasm && \
    tar -xzOf /tmp/tf.tgz package/dist/ort-wasm-simd-threaded.jsep.mjs \
      > vendor/ort/ort-wasm-simd-threaded.jsep.mjs && \
    rm /tmp/tf.tgz

# ── litert-lm WASM ────────────────────────────────────────────────────────
RUN curl -sL 'https://registry.npmjs.org/@litert-lm/core/-/core-0.13.1.tgz' \
    -o /tmp/lm.tgz && \
    tar -xzOf /tmp/lm.tgz package/wasm/litertlm_wasm_internal.js \
      > vendor/litert-lm-wasm/litertlm_wasm_internal.js && \
    tar -xzOf /tmp/lm.tgz package/wasm/litertlm_wasm_internal.wasm \
      > vendor/litert-lm-wasm/litertlm_wasm_internal.wasm && \
    tar -xzOf /tmp/lm.tgz package/wasm/litertlm_wasm_compat_internal.js \
      > vendor/litert-lm-wasm/litertlm_wasm_compat_internal.js && \
    tar -xzOf /tmp/lm.tgz package/wasm/litertlm_wasm_compat_internal.wasm \
      > vendor/litert-lm-wasm/litertlm_wasm_compat_internal.wasm && \
    rm /tmp/lm.tgz

# ── Whisper model JSON configs ─────────────────────────────────────────────
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
