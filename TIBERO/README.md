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

## 설치 / 실행 (RHEL 8.10 + Python 3.8)

`run.sh` → `run.py` 가 파이썬/의존성/`PG.env` 를 점검한 뒤 streamlit 을 기동한다.

```bash
cd TIBERO
sudo dnf install -y python38 python38-devel   # 없을 경우

# 접속 정보 (없으면 run.py 가 템플릿을 만들어 준다)
cat > PG.env <<'EOF'
PG_HOST=...
PG_PORT=5432
PG_DBNAME=...
PG_USER=...
PG_PASSWORD=...
EOF
chmod 600 PG.env

chmod +x run.sh make_wheels.sh
./run.sh                    # .venv 생성 여부를 물은 뒤 0.0.0.0:8501 로 기동
```

접속: `http://<서버IP>:8501` (필요 시 `firewall-cmd --add-port=8501/tcp --permanent && firewall-cmd --reload`)

옵션:
```bash
./run.sh --port 8600        # 포트 변경 (사용 중이면 자동으로 다음 포트)
./run.sh --host 127.0.0.1   # 로컬 전용 바인드
./run.sh --browser          # 데스크톱 환경에서 브라우저 자동 오픈
PYTHON_BIN=/usr/bin/python3.8 ./run.sh
python3.8 run.py            # venv 없이 직접 실행
```

## 폐쇄망 설치 (wheel 반입)

인터넷이 되는 서버에서 wheel 을 모아 대상 서버로 복사한다.

```bash
# [인터넷 서버]
./make_wheels.sh                       # cp38 / manylinux x86_64 휠을 wheels/ 에 수집 (약 200MB+)
./make_wheels.sh -c                    # 기존 wheels/ 를 비우고 새로 수집 (부분 수집본 정리)
./make_wheels.sh -n                    # 대상 서버에서 직접 받을 때(native)
tar czf tibero_web.tar.gz app.py run.py run.sh requirements.txt wheels/

# [대상 서버 - 폐쇄망]
tar xzf tibero_web.tar.gz && cd TIBERO
./run.sh                               # wheels/ 를 감지해 --no-index 로 오프라인 설치
# 수동 설치 시
python3.8 -m pip install --no-index --find-links wheels -r requirements.txt
```

## Docker (선택)
```bash
docker build -t sql-runner .
docker run -d -p 8501:8501 --env-file PG.env sql-runner
# 또는 docker network create dong-network && docker compose up -d --build
```


## 파일 구성
```
TIBERO/
├── app.py               # Streamlit 메인 앱
├── run.py               # 실행 런처 (환경/의존성/PG.env 점검 후 streamlit 기동)
├── run.sh               # RHEL 8 래퍼 (python3.8 탐색 + .venv 준비 → run.py)
├── make_wheels.sh       # 폐쇄망 반입용 wheel 수집 (cp38/manylinux)
├── requirements.txt     # 의존성 (Python 3.8 에서 설치 가능한 버전으로 자동 해석)
├── PG.env               # 실제 접속 정보 (git 제외, chmod 600)
├── wheels/              # 오프라인 설치용 wheel (git 제외)
├── .venv/               # run.sh 가 만드는 가상환경 (git 제외)
├── log/                 # 실행 SQL/오류 로그 (자동 생성)
├── SQL_EXECUTE.html     # 원본 디자인 목업
└── SQL_GRID_WEB_PLAN.md # 요구사항 정의서
```

## 참고 / 조정 포인트
- `app.py` 의 `PRESETS` 샘플 쿼리는 목업 기준(customers/orders/…)이므로 대상 DB 스키마에 맞게 수정.
- 행 초과 여부는 `LIMIT (n+1)` 로 판별하며, 정확한 원본 총건수는 표시하지 않음(별도 COUNT 필요 시 추가).
- `PG.env` 는 루트 `.gitignore` 의 `*.env` 로 제외된다. 파일 권한은 `chmod 600` 권장.
- **wheel 수집 시 `No matching distribution` 이 나면** 해당 패키지가 `--platform` 목록에 없는 태그로
  배포된 경우다(pip 은 태그 문자열을 정확히 일치시킨다). `make_wheels.sh` 의 `PLATFORMS` 배열에
  그 태그를 추가한다. 다운로드가 중간에 실패하면 `wheels/` 는 부분 수집 상태이므로 그대로 반입하면
  안 되고, `-c` 로 비우고 다시 받는다. 수집 후 핵심 패키지 존재 여부는 스크립트가 자동 검증한다.
- RHEL 8 의 기본 `python3` 은 3.6 이므로 반드시 `python38` 패키지를 설치해 사용한다.
