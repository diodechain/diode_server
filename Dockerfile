FROM elixir:1.9

RUN apt-get update && apt-get install -y libboost-dev

ENV MIX_ENV=prod PORT=8080

COPY mix.* .

RUN mix local.hex --force && mix local.rebar && mix deps.get && mix deps.compile

COPY . .

RUN mix compile

CMD ["iex", "-S","mix", "run"]
