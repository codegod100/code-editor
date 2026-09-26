FROM dart:stable AS dart-sdk

FROM python:3.12-slim-bookworm

ARG MODAL_VERSION=1.5.4

COPY --from=dart-sdk /usr/lib/dart /usr/lib/dart

ENV PATH="/usr/lib/dart/bin:${PATH}"

RUN apt-get update \
    && apt-get install --no-install-recommends -y git ca-certificates curl \
    && python -m pip install --no-cache-dir "modal==${MODAL_VERSION}" \
    && dart --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /github/workspace
