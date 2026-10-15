FROM python:3.12-alpine
WORKDIR /app
COPY bot.py /app/bot.py
COPY gateway_traffic.py /app/gateway_traffic.py
COPY register-commands.py /app/register-commands.py
RUN chmod 0644 /app/bot.py /app/gateway_traffic.py /app/register-commands.py \
    && adduser -D -u 10001 bot
USER bot
CMD ["python3", "/app/bot.py"]
