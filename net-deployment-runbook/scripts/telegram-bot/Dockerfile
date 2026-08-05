FROM python:3.12-alpine
WORKDIR /app
COPY bot.py /app/bot.py
RUN adduser -D -u 10001 bot
USER bot
CMD ["python3", "/app/bot.py"]
