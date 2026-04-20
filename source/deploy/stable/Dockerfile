FROM node:20-alpine AS builder

WORKDIR /app
RUN apk add --no-cache python3 make g++ git 

COPY package.json ./
COPY npm-shrinkwrap.json ./
RUN npm install

COPY . .
RUN npm run build
RUN npm prune --production

FROM node:20-alpine
WORKDIR /app
RUN apk add --no-cache iputils

COPY --from=builder /app/package.json ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist

# Salin folder public jika ada di root project
RUN cp -r /app/public ./public 2>/dev/null || true

RUN mkdir -p /app/config/ext
RUN chmod +x ./dist/bin/*

CMD ["./dist/bin/genieacs-cwmp"]
