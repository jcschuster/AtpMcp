# syntax=docker/dockerfile:1
#
# atp_mcp as a self-contained MCP server on stdio.
#
#   docker build -t atp_mcp .                                # SystemOnTPTP + local E
#   docker build -t atp_mcp:isabelle --target isabelle .     # + Isabelle/HOL (amd64)
#
#   docker run -i --rm atp_mcp                  # serve MCP
#   docker run --rm atp_mcp doctor              # check every backend
#
# The working directory is /work: mount a directory holding atp_mcp.exs
# there to configure the server (see the README).
#
# For Isabelle on arm64, build with
#   --build-arg ISABELLE_IMAGE=docker.io/makarius/isabelle:Isabelle2025-2_ARM

ARG ISABELLE_IMAGE=docker.io/makarius/isabelle:Isabelle2025-2

# --- build: the escript ------------------------------------------------------
# BEAM files are portable, so the escript is built once on the build host's
# platform and copied into every target platform.
FROM --platform=$BUILDPLATFORM docker.io/library/elixir:1.20-otp-29-slim AS build

# The slim image ships no CA bundle, without which Hex cannot be reached.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
WORKDIR /src
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config config
COPY lib lib
RUN mix escript.build

# --- runtime: Erlang, E, and the escript --------------------------------------
FROM docker.io/library/erlang:29-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates eprover \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash atp
COPY --from=build /src/atp_mcp /usr/local/bin/atp_mcp

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
USER atp
WORKDIR /work
ENTRYPOINT ["atp_mcp"]

# --- isabelle: runtime + Isabelle/HOL -----------------------------------------
# The official image ships HOL heaps prebuilt, so nothing is built here; the
# server starts on the first Isabelle call (AtpMcp.IsabelleSession).
FROM ${ISABELLE_IMAGE} AS isabelle-dist

FROM runtime AS isabelle

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends libfontconfig1 libgomp1 perl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=isabelle-dist /home/isabelle/Isabelle /opt/isabelle
ENV PATH=/opt/isabelle/bin:$PATH

USER atp
# Returns at once when the heaps are current; initialises ~/.isabelle, where
# the resident server registers itself.
RUN isabelle build -b HOL
RUN ["atp_mcp", "doctor", "local_exec"]

# --- default: the image `docker build` produces without --target --------------
FROM runtime AS default
RUN ["atp_mcp", "doctor", "local_exec"]
