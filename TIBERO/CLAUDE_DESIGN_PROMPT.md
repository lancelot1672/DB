# Claude 개발/디자인 프롬프트 - SQL Grid Web

> 아래 "프롬프트" 블록을 그대로 복사해서 Claude(Claude Code / claude.ai)에 붙여넣으면 됩니다.
> `«...»` 로 표시된 부분은 필요 시 값만 바꿔주세요. (지금은 권장 기본값으로 채워둠)

---

## 프롬프트 (복사해서 사용)

```
당신은 시니어 풀스택 개발자입니다. 아래 요구사항에 맞는 웹 애플리케이션을 개발해 주세요.

## 목표
SQL(약 100줄 규모)을 텍스트 영역에 붙여넣고 [실행] 버튼을 누르면,
PostgreSQL 9.6 에서 쿼리를 수행하고 결과를 그리드(표) 형식으로 조회하는 웹 페이지.

## 기술 스택
- 언어/프레임워크: Python + Streamlit (단일 app.py 로 구성)
- DB: PostgreSQL 9.6
- DB 드라이버: psycopg2 (psycopg2-binary), 9.6 호환 버전으로 고정
- 그리드 표시: streamlit-aggrid (AG Grid) 사용, 없으면 st.dataframe 로 폴백
- 접속 정보: 같은 폴더의 PG.env 파일에서 로딩 (host, port, dbname, user, password)
  python-dotenv 사용. 코드에 접속정보 하드코딩 금지.

## 기능 요구사항
1. SQL 입력
   - 여러 줄(100줄 이상) 입력 가능한 넓은 텍스트 영역
   - [실행] 버튼
2. SQL 실행
   - 붙여넣은 SQL 을 PostgreSQL 에 전송하여 실행
   - 「단일 SELECT 문」만 처리한다고 가정 (아래 보안 규칙 참고)
3. 결과 표시
   - 결과를 그리드로 표시 (컬럼 헤더 포함, 정렬/스크롤 가능)
   - 상단에 조회 건수와 수행 시간(초) 표시
   - 결과를 CSV 로 다운로드하는 버튼 제공
4. 오류 처리
   - SQL 오류/DB 오류 시 앱이 죽지 않고 화면에 에러 메시지를 빨간색으로 표시

## 보안/제약 (반드시 반영)
- 조회 전용: SELECT 및 WITH ... SELECT 로 시작하는 쿼리만 허용.
  INSERT/UPDATE/DELETE/DROP/TRUNCATE/ALTER/CREATE/GRANT 등이 포함되면
  실행하지 않고 "조회(SELECT) 쿼리만 허용됩니다" 라고 차단.
- 여러 문장(세미콜론으로 구분된 다중 문장) 입력 시 차단하거나 첫 SELECT 만 실행.
- 결과 행 수는 최대 «1000» 행으로 제한 (원 쿼리를 서브쿼리로 감싸 LIMIT 적용).
- DB 접속은 읽기 전용 계정 사용을 전제로 함.
- 실행한 SQL / 시각을 로그 파일에 남김.

## UI 레이아웃(가이드)
- 상단 제목: "SQL Grid (PostgreSQL)"
- SQL 입력 텍스트 영역 (전체 폭, 높이 크게)
- 우측/하단에 [실행] 버튼
- 실행 후: "조회 건수: N   수행 시간: 0.00s   [CSV 저장]" 표시줄 + 그 아래 그리드
- 레이아웃은 wide 모드

## 산출물
1. app.py            - Streamlit 메인 앱 (위 기능 전부 포함)
2. requirements.txt  - 의존성 목록 (streamlit, pandas, psycopg2-binary, python-dotenv, streamlit-aggrid)
3. PG.env.example    - 접속 정보 템플릿 (host/port/dbname/user/password)
4. README (실행 방법: pip install -r requirements.txt → streamlit run app.py)

## 코드 작성 규칙
- 주석은 한국어로 간결하게.
- 함수는 역할별로 분리 (env 로딩 / SQL 검증 / 쿼리 실행 / 결과 렌더링).
- 접속정보·비밀번호는 절대 하드코딩하지 말 것.
- PostgreSQL 9.6 에서 동작하는 문법/드라이버 버전만 사용.

먼저 전체 구조를 간단히 설명한 뒤, 파일별 전체 코드를 제시해 주세요.
```

---

## 참고 (변경 포인트)
프롬프트 안에서 상황에 맞게 바꿀 수 있는 값:
- 그리드 라이브러리: `streamlit-aggrid` ↔ 기본 `st.dataframe`
- 허용 SQL 범위: `SELECT 전용`(현재) ↔ DML 허용 ↔ 제한 없음
- 행 수 제한: `«1000»` 숫자 조정 또는 "제한 없음"
- 접근 통제: 인증 없음(현재) ↔ 로그인 추가
- 상세 요구사항은 `SQL_GRID_WEB_PLAN.md` 참고
