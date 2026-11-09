# ビルドはリポジトリのルートで行う（shared/schemas を入れるため）
#   gcloud builds submit --config server/cloudbuild.yaml .
FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
COPY server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY shared/schemas /srv/shared/schemas
COPY shared/params /srv/shared/params
COPY server/app /srv/app
CMD exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8080} --proxy-headers
