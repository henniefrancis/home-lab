# IT Tools (R17, milestone M7): the official static build served by the official, current NGINX (unprivileged, alpine-slim).
#
# Why not run the upstream image directly: its only release (v2024.10.22-7ca5933, the official ghcr.io/corentinth/it-tools image) is
# built on Alpine 3.20.3, which is end of life, with 3 CRITICAL and 37 HIGH CVEs (mostly OpenSSL) in a 2026-11-10 trivy scan. The app
# itself is 282 static files (HTML, JS, CSS, images) with no server side, so the files are copied out of the official image unchanged
# and served by nginxinc/nginx-unprivileged (NGINX's own image: non-root uid 101 by default, port 8080, pid and temp files in /tmp).
#
# N8 (same rule as traefik/ra-helper): both FROM lines are pinned by digest and nothing is downloaded or installed at build time, so
# the build has no mutable input. Dependabot (docker ecosystem, /it-tools) proposes new digests for both.
# Self-test: scripts/test-it-tools-config.sh. Runbook: docs/runbooks/m7-it-tools.md.
FROM ghcr.io/corentinth/it-tools:2024.10.22-7ca5933@sha256:8b8128748339583ca951af03dfe02a9a4d7363f61a216226fc28030731a5a61f AS app

FROM nginxinc/nginx-unprivileged:1.30.6-alpine-slim@sha256:5d8bb9437d74a600ec5dbf90c035451c724dc33eac8d3a71078f6f8612c345f6
# Root-owned and read-only for the service uid: the web server can read the site but never change it.
COPY --from=app --chown=0:0 --chmod=0755 /usr/share/nginx/html /usr/share/nginx/html
COPY --chown=0:0 --chmod=0644 nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
# NGINX is started directly, not through the image's /docker-entrypoint.sh: its scripts try to rewrite default.conf (IPv6 listen,
# templates, worker tuning), which a read-only root refuses and this site does not need. The config is exactly what is committed.
ENTRYPOINT ["nginx", "-g", "daemon off;"]
CMD []
