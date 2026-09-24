FROM python:3.12-slim-bookworm

ARG MODAL_VERSION=1.5.4

RUN apt-get update \
    && apt-get install --no-install-recommends -y git ca-certificates \
    && python -m pip install --no-cache-dir "modal==${MODAL_VERSION}" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /github/workspace
