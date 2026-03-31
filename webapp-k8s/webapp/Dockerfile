FROM node:18-alpine

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies with verbose logging
RUN npm install --production --verbose

# Copy application files
COPY . .

# Create uploads directory
RUN mkdir -p /app/public/uploads

# Expose port
EXPOSE 3000

# Start application
CMD ["node", "server.js"]
