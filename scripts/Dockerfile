# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
FROM elixir:1.15.7

RUN apt-get update && apt-get install -y \
    libboost-dev \
    libboost-system-dev \
    build-essential \
    wget \
    zlib1g-dev

# Install OpenSSL 1.1
RUN wget https://www.openssl.org/source/openssl-1.1.1s.tar.gz && \
    tar -xzvf openssl-1.1.1s.tar.gz && \
    cd openssl-1.1.1s && \
    ./config && \
    make && \
    make install && \
    ldconfig

ENV MIX_ENV=prod
ENV PORT=8080
ENV ERL_EPMD_ADDRESS=127.0.0.1

COPY mix.* /app/

WORKDIR /app/

RUN mix local.hex --force && mix local.rebar && mix deps.get && make -C deps/libsecp256k1/ && mix deps.compile

COPY . /app/

RUN mix do compile, git_version

ENTRYPOINT ["scripts/entrypoint"]

