# Playwright base image ships Chromium + all OS deps, matched to playwright==1.47.0.
FROM mcr.microsoft.com/playwright/python:v1.47.0-jammy

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Drop privileges: the Playwright image ships a non-root 'pwuser' (uid 1000).
RUN chown -R pwuser:pwuser /app
USER pwuser

# ACA Job runs the crawl to completion and exits.
CMD ["scrapy", "crawl", "sitemap"]
