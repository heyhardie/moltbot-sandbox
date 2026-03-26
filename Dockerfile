# Use the official Node 22 image (which is 22.17.0+ as of now)
FROM node:22-bookworm-slim

# Set the working directory
WORKDIR /app

# Copy package files and install dependencies
COPY package*.json ./
RUN npm install --production

# Copy the rest of the application code
COPY . .

# OpenClaw usually runs on port 18789
EXPOSE 18789

# Start the Gateway
CMD ["npm", "start"]
