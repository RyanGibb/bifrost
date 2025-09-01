FROM python:3.11-slim

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libportaudio2 portaudio19-dev libasound2 libasound2-dev libsndfile1 \
    libgomp1 \
  && rm -rf /var/lib/apt/lists/*

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONUNBUFFERED=1 \
    MODELS_DIR=/models \
    MODEL_NAME=moonshine/base

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install -r requirements.txt

COPY stt.py /app/stt.py
COPY tokenizer.json /app/tokenizer.json
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

VOLUME ["/models"]

RUN useradd -m appuser
USER appuser

ENTRYPOINT ["/app/entrypoint.sh"]

