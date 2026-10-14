# -- Stage 1: Build Flutter Web ---------------------------------------------
FROM ghcr.io/cirruslabs/flutter:stable AS builder

WORKDIR /app

# Copy dependency files first (layer caching)
COPY pubspec.yaml pubspec.lock ./

# Get dependencies
RUN flutter pub get

# Copy the rest of the source code
COPY . .

# Build Flutter web release
ARG API_BASE_URL=https://backend-production-343b4.up.railway.app/api
ARG SENTRY_DSN=
RUN flutter build web --release \
    --dart-define=API_BASE_URL=${API_BASE_URL} \
    --dart-define=SENTRY_DSN=${SENTRY_DSN}

# -- Stage 2: Serve with nginx ----------------------------------------------
FROM nginx:alpine

# Copy built web files from builder stage
COPY --from=builder /app/build/web /usr/share/nginx/html

# nginx config with Flutter SPA routing + gzip
RUN printf 'server {\n  listen 8080;\n  root /usr/share/nginx/html;\n  index index.html;\n  location / {\n    try_files $uri $uri/ /index.html;\n  }\n  gzip on;\n  gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;\n}\n' > /etc/nginx/conf.d/default.conf

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
