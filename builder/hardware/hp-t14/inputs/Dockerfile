FROM ubuntu:26.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl python3 7zip innoextract xorriso squashfs-tools zstd m4 alsa-utils \
    && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["python3", "/hardware/fetch-firmware.py"]
