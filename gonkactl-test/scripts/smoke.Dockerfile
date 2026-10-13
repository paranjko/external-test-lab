FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates openssl tar && rm -rf /var/lib/apt/lists/*
COPY container-smoke.py /smoke.py
ENTRYPOINT ["python3", "/smoke.py", "/release", "/installer/install.sh"]
