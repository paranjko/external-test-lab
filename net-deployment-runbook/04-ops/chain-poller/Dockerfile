FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY poller.py ./
USER nobody
EXPOSE 9800
CMD ["python", "-u", "poller.py"]
