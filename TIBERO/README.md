# SQL Grid Web (PostgreSQL 9.6)

SQL 을 붙여넣고 실행하면 결과를 그리드로 조회하는 Streamlit 웹 앱.
`SQL_EXECUTE.html` 디자인 목업을 `SQL_GRID_WEB_PLAN.md` 요구사항에 맞춰 실제 동작 앱으로 변환한 것.

## 주요 기능
- SQL 입력(100줄+) → [실행] → 그리드 조회
- **조회 전용**: `SELECT` / `WITH` 만 허용, 다중 문장 차단, DML/DDL 차단
- 행 수 제한(100/500/1000/5000), 조회 건수 · 수행 시간 표시
- CSV 다운로드 (UTF-8 BOM)
- 읽기 전용 세션(`set_session(readonly=True)`) + 실행 SQL/시각 로깅(`log/`)
- 그리드: `streamlit-aggrid`(정렬/필터), 미설치 시 `st.dataframe` 자동 폴백

## 설치 / 실행
```bash
cd TIBERO
pip install -r requirements.txt

# 접속 정보 설정
cp PG.env.example PG.env    # Windows: copy PG.env.example PG.env
# PG.env 편집 (host/port/dbname/user/password)

streamlit run app.py
```

## Docker
docker build -t sql-runner .
docker run -d -p 8501:8501 --env-file PG.env sql-runner


## 파일 구성
```
TIBERO/
├── app.py               # Streamlit 메인 앱
├── requirements.txt     # 의존성 (9.6 호환 버전 고정)
├── PG.env.example       # 접속 정보 템플릿 (복사해서 PG.env 로)
├── PG.env               # 실제 접속 정보 (git 제외)
├── log/                 # 실행 SQL/오류 로그 (자동 생성)
├── SQL_EXECUTE.html     # 원본 디자인 목업
└── SQL_GRID_WEB_PLAN.md # 요구사항 정의서
```

## 참고 / 조정 포인트
- `app.py` 의 `PRESETS` 샘플 쿼리는 목업 기준(customers/orders/…)이므로 대상 DB 스키마에 맞게 수정.
- 행 초과 여부는 `LIMIT (n+1)` 로 판별하며, 정확한 원본 총건수는 표시하지 않음(별도 COUNT 필요 시 추가).
- `PG.env` 는 `.gitignore` 에 추가 권장.
