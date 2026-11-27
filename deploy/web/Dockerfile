# Bonkfish web client: static files served by Caddy on Railway's $PORT.
# Build input: everything in this folder from Godot's "Web" export preset (index.html, .wasm, .pck, .js ...).
FROM caddy:2-alpine

COPY . /srv
RUN printf ':{$PORT}\nroot * /srv\nencode gzip\nfile_server\n' > /etc/caddy/Caddyfile

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
