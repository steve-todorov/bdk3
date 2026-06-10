#!/bin/sh
set -eu

# Render a static response capturing the env at startup so we can confirm
# Flux postBuild substitution + Secret/ConfigMap wiring landed on the pod.
mkdir -p /srv
cat > /srv/index.html <<EOF
hello
APP_ENV=${APP_ENV:-unset}
DATABASE_URL=${DATABASE_URL:-unset}
EOF

exec busybox httpd -f -p 8080 -h /srv
