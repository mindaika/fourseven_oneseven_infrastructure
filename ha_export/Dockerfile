# homelab-api: Home Assistant statistics for the garbanzo.monster dashboard.
FROM python:3.13-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements-api.txt .
RUN pip install --no-cache-dir -r requirements-api.txt

COPY api/ ./api/

# Runs unprivileged: this service only ever needs to read Postgres over the
# network, so it has no reason to hold root in the container.
RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 5007

# 2 workers: the Pi is shared with Home Assistant, Postgres and five other
# containers, and this API serves one dashboard rather than public traffic.
CMD ["gunicorn", "--bind", "0.0.0.0:5007", "--workers", "2", \
     "--timeout", "60", "--access-logfile", "-", "api:create_app()"]
