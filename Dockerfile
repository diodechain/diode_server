# Diode Server
# Copyright 2019 IoT Blockchain Technology Corporation LLC (IBTC)
# Licensed under the Diode License, Version 1.0
FROM elixir:1.9

RUN apt-get update && apt-get install -y libboost-dev libboost-system-dev

ENV MIX_ENV=prod PORT=8080

COPY mix.* .

RUN mix local.hex --force && mix local.rebar && mix deps.get && mix deps.compile

COPY . .

RUN mix compile

CMD ["iex", "-S","mix", "run"]
