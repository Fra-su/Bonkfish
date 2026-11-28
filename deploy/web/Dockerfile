# Bonkfish web client: static files served by Caddy on Railway's $PORT.
# Build input: everything in this folder from Godot's "Web" export preset (index.html, .wasm, .pck, .js ...).
FROM caddy:2-alpine

COPY . /srv
# "no-cache" = browsers may keep a copy but must check it's still current before using it
# (cheap: unchanged files just get a 304). Without it, players kept running old builds.
RUN printf ':{$PORT}\nroot * /srv\nencode gzip\nheader Cache-Control "no-cache"\nfile_server\n' > /etc/caddy/Caddyfile

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
