#!/bin/sh

NGINX_HTML_DIR=/usr/share/nginx/html

# Wait for directory to exist
while [ ! -d "$NGINX_HTML_DIR" ]; do
  echo "Waiting for $NGINX_HTML_DIR..."
  sleep 1
done

# Generate env-config.js
cat << EOF > "$NGINX_HTML_DIR/env-config.js"
window._env_ = {
  AUTH0_DOMAIN: '${AUTH0_DOMAIN}',
  AUTH0_CLIENT_ID: '${AUTH0_CLIENT_ID}',
  AUTH0_AUDIENCE: '${AUTH0_AUDIENCE}'
};
EOF

chmod 644 "$NGINX_HTML_DIR/env-config.js"