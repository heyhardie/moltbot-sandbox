# 1. Use the most stable Node 22 image for AI agents
FROM node:22.17.0-bookworm-slim

# 2. Install essential system tools for building native modules
RUN apt-get update && apt-get install -y \
    python3 \
    make \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# 3. Create and set the working directory
WORKDIR /app

# 4. Copy dependency files first (to optimize build caching)
# We use a wildcard to ensure it works even if package-lock is missing
COPY package*.json ./

# 5. Install ALL dependencies (needed for the build step)
RUN npm install

# 6. Copy the rest of the application source code
COPY . .

# 7. BUILD the project
# This step creates the 'dist' folder for the backend 
# and the 'dist/client' folder for the frontend UI.
RUN npm run build

# 8. Set environment variables for the container runtime
ENV NODE_ENV=production
ENV HOST=0.0.0.0
ENV PORT=18789

# 9. Expose the internal port for Cloudflare's health check
EXPOSE 18789

# 10. Start the application using the compiled javascript
# Note: We use the compiled dist/index.js, not the src/index.ts
CMD ["node", "dist/index.js"]
