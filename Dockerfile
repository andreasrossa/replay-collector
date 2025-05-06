FROM elixir:1.17-otp-26-alpine AS builder

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./

RUN mix deps.get --only prod
RUN mix deps.compile

COPY config/config.exs config/runtime.exs config/
COPY lib lib

RUN mix compile && \
    mix release


FROM alpine:3.19.1 AS app

RUN apk add --no-cache openssl ncurses-libs libstdc++
WORKDIR /app

COPY --from=builder /app/_build/prod/rel/collector ./

CMD ["bin/collector", "start"]
