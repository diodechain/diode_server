FROM elixir:1.9

ENV MIX_ENV=prod PORT=8080

COPY mix.* .

RUN mix local.hex --force && mix local.rebar && mix deps.get && mix compile

COPY . .

RUN mix compile

CMD ["iex", "-S","mix", "run"]
