# Build context is the repo root, not apps/web — this app resolves
# kavach_core, kavach_core_storage_web and neopop_theme via relative
# `path:` deps in its pubspec.yaml (melos monorepo), so Flutter needs
# those sibling package directories present at their real relative
# locations. Build with:
#   docker build -f apps/web/Dockerfile -t kavach-web .
# from the repo root, or via apps/web/docker-compose.yml, which sets the
# context correctly already.

# No official Google Flutter image exists, and third-party ones
# (cirruslabs/flutter) lag the real stable channel by enough that they
# don't reliably satisfy this monorepo's `sdk: ^3.13.2` constraint —
# tried first, and even its newest published tag still shipped Dart
# 3.12.0. Installing Flutter straight from its own repo, pinned to the
# exact tag this project was developed against, sidesteps that entirely:
# it's the authoritative source and isn't gated on a second party
# republishing an image after every Flutter release.
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch 3.47.2 https://github.com/flutter/flutter.git /flutter
ENV PATH="/flutter/bin:${PATH}"
# Warms Flutter's web-specific tooling/artifact cache in its own layer,
# so it's reused across rebuilds that only touch app source below.
RUN flutter precache --web && flutter config --no-analytics

WORKDIR /monorepo

# Only the packages apps/web actually depends on — copying the whole
# monorepo here would invalidate this layer (and force a full
# flutter pub get + rebuild) on every unrelated change anywhere else in
# the repo, e.g. editing apps/kavach or kavach-storage.
COPY packages/core packages/core
COPY packages/core_storage_web packages/core_storage_web
COPY packages/neopop_theme packages/neopop_theme
COPY apps/web apps/web

WORKDIR /monorepo/apps/web
RUN flutter pub get
RUN flutter build web --release

FROM nginx:1.27-alpine
COPY apps/web/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /monorepo/apps/web/build/web /usr/share/nginx/html
EXPOSE 80
