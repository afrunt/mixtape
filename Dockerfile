# mixtape.sh runtime image.
#
# Bundles mixtape.sh with its runtime dependencies (ffmpeg/ffprobe) so it can
# be run without installing anything locally besides Docker.
#
# Build:
#   docker build -t afrunt/mixtape .
#
# Run (album and output directories are bind-mounted from the host):
#   docker run --rm \
#     -v "$(pwd)/albums/my-album:/album:ro" \
#     -v "$(pwd)/out:/out" \
#     afrunt/mixtape --path /album --dest /out --length 90

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg bash \
    && rm -rf /var/lib/apt/lists/*

COPY mixtape.sh /usr/local/bin/mixtape.sh
RUN chmod +x /usr/local/bin/mixtape.sh

WORKDIR /work

ENTRYPOINT ["mixtape.sh"]
CMD ["--help"]
