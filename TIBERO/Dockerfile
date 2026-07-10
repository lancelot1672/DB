FROM python:3.11-slim

WORKDIR /app

# 의존성 먼저 설치 (레이어 캐시 활용)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 앱 소스 복사 (.dockerignore 로 PG.env / log 제외)
COPY . .

# 접속 정보는 이미지에 넣지 않고 런타임에 주입:
#   docker run -p 8501:8501 --env-file PG.env tibero-sql-grid
# 또는 PG.env 파일을 마운트:
#   docker run -p 8501:8501 -v $(pwd)/PG.env:/app/PG.env tibero-sql-grid
EXPOSE 8501

CMD ["streamlit", "run", "app.py", "--server.address=0.0.0.0", "--server.port=8501"]
