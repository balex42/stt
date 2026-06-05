FROM node:22-alpine
WORKDIR /app
COPY serve.js .
COPY static/ static/
EXPOSE 8000
CMD ["node", "serve.js"]
