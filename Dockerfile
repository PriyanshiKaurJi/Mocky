FROM eclipse-temurin:17-jdk AS builder
ARG SBT_VERSION=1.9.9
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && update-ca-certificates \
    && curl -fsSL https://github.com/sbt/sbt/releases/download/v${SBT_VERSION}/sbt-${SBT_VERSION}.tgz | tar xz -C /opt \
    && rm -rf /var/lib/apt/lists/*
ENV PATH="/opt/sbt/bin:${PATH}"
WORKDIR /app
COPY server ./server
WORKDIR /app/server
RUN sbt clean stage

FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
RUN apk add --no-cache bash nginx gettext
COPY --from=builder /app/server/target/universal/stage ./
COPY public /usr/share/nginx/html

RUN mkdir -p /run/nginx && cat <<'EOF' > /etc/nginx/http.d/default.conf.template
server {
    listen ${PORT};
    server_name _;
    client_max_body_size 10M;

    location = /health {
        access_log off;
        default_type application/json;
        return 200 '{"status":"ok"}';
    }

    location /view/ {
        root /usr/share/nginx/html;
        try_files /page.html =404;
    }

    location ~ ^/(api|v2|v3|admin)(/|$) {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }
}
EOF

RUN cat <<'EOF' > /app/entrypoint.sh
#!/usr/bin/env bash
set -e
export PORT="${PORT:-10000}"
export BACKEND_PORT="${BACKEND_PORT:-8080}"
envsubst '${PORT} ${BACKEND_PORT}' < /etc/nginx/http.d/default.conf.template > /etc/nginx/http.d/default.conf
APP_BIN=$(ls /app/bin/* | grep -v '\.bat$' | head -n 1)

PORT="${BACKEND_PORT}" HTTP_PORT="${BACKEND_PORT}" "$APP_BIN" \
  -J-Xms128m \
  -J-Xmx350m \
  -Dhttp.port="${BACKEND_PORT}" \
  -Dserver.port="${BACKEND_PORT}" &

exec nginx -g "daemon off;"
EOF

RUN chmod +x /app/entrypoint.sh
EXPOSE 10000
CMD ["/app/entrypoint.sh"]
