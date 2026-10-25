FROM python:3.12-slim

ARG INSTALL_LAYOUT=0
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends libglib2.0-0 libgl1 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 papernas
WORKDIR /build
COPY . .
RUN python scripts/package-source.py --from-checkout \
    && python backend/scripts/build_web.py \
    && if [ "$INSTALL_LAYOUT" = "1" ]; then pip install './backend[layout]'; else pip install ./backend; fi \
    && mkdir -p /var/lib/papernas /home/papernas/.cache \
    && chown -R papernas:papernas /var/lib/papernas /home/papernas/.cache \
    && rm -rf /build
WORKDIR /home/papernas
USER papernas
EXPOSE 8788
CMD ["papernas-v2", "api"]
