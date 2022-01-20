# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
FROM elixir:1.11.4

RUN apt-get update && apt-get install -y libboost-dev libboost-system-dev

ENV MIX_ENV=prod

COPY mix.* /app/

WORKDIR /app/

RUN mix local.hex --force && mix local.rebar && mix deps.get && mix deps.compile

COPY . /app/

RUN mix do compile, git_version

CMD ["elixir", "-S", "mix", "run", "--no-halt"]
