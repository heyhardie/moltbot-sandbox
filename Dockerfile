FROM node:22.17.0-bookworm-slim
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
# This generates the files that the Worker's "ASSETS" binding needs
RUN npm run build
EXPOSE 18789
ENV HOST=0.0.0.0
ENV PORT=18789
CMD ["node", "dist/index.js"]
