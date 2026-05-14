# CANADA_EXPDP 구현 계획

## 구현 규칙
1. CANADA_EXPDP_SHELL_UPDATE_YYYYMMDD.md 파일에 수정사항 기록
2. 주석은 영어로 작성

## 개요
DBADM.MIG_TAB_LIST 테이블에서 대상 테이블 목록을 조회하여,
WHERE 조건이 있으면 QUERY 파라미터를 포함한 EXPDP를 수행하는 쉘 스크립트

## 테이블 구조 (DBADM.MIG_TAB_LIST)
| 컬럼 | 설명 |
|---|---|
| OWNER | 스키마명 |
| TABLE_NAME | 테이블명 |
| WHERE_COL1 | 1차 조건 컬럼 |
| PRE1 | 1차 조건 값 (>= 비교) |
| WHERE_COL2 | 2차 조건 컬럼 |
| PRE2 | 2차 조건 값 (< 비교) |

## 처리 흐름

```
1. sqlplus로 MIG_TAB_LIST 조회 -> 임시 파일 생성
2. 임시 파일을 한 줄씩 읽기
3. WHERE_COL1, WHERE_COL2 존재 여부에 따라 QUERY 파라미터 조립
4. expdp 수행
5. 결과 출력 (성공/실패, 소요시간)
6. SUMMARY 출력
```

## QUERY 조건 조립 규칙

| WHERE_COL1 | WHERE_COL2 | QUERY 파라미터 |
|---|---|---|
| 없음 | 없음 | QUERY 없이 전체 export |
| 있음 | 없음 | `QUERY=OWNER.TABLE:"WHERE COL1 >= 'PRE1'"` |
| 있음 | 있음 | `QUERY=OWNER.TABLE:"WHERE COL1 >= 'PRE1' AND COL2 < 'PRE2'"` |

## 스크립트 구조 (CANADA_EXPDP.sh)

```
#!/bin/ksh

### 1. 인자 확인
- $1 : DB_DIR (DIRECTORY 오브젝트명)

### 2. 환경 변수
- BASE_PATH, DUMP_DIR, LOGFILE 설정

### 3. sqlplus로 대상 목록 추출
sqlplus -s dbadm/password <<EOF > tmp_list.dat
SET HEAD OFF FEED OFF PAGES 0 LINES 200 TRIM ON
SELECT OWNER || ',' ||
       TABLE_NAME || ',' ||
       NVL(WHERE_COL1, 'NONE') || ',' ||
       NVL(PRE1, 'NONE') || ',' ||
       NVL(WHERE_COL2, 'NONE') || ',' ||
       NVL(PRE2, 'NONE')
  FROM DBADM.MIG_TAB_LIST
 ORDER BY OWNER, TABLE_NAME;
EOF

### 4. 루프 처리 (한 줄씩)
while IFS=',' read owner table wcol1 pre1 wcol2 pre2
do
    # 4-1. QUERY 파라미터 조립
    if [ "$wcol1" != "NONE" ] && [ "$wcol2" != "NONE" ] ; then
        QUERY_PARAM="QUERY=${owner}.${table}:\"WHERE ${wcol1} >= '${pre1}' AND ${wcol2} < '${pre2}'\""
    elif [ "$wcol1" != "NONE" ] ; then
        QUERY_PARAM="QUERY=${owner}.${table}:\"WHERE ${wcol1} >= '${pre1}'\""
    else
        QUERY_PARAM=""
    fi

    # 4-2. expdp 수행
    expdp dbadm/password \
        directory=${DB_DIR} \
        dumpfile=${owner}.${table}_%U.dat \
        logfile=exp_${owner}.${table}.log \
        tables=${owner}.${table} \
        ${QUERY_PARAM}

    # 4-3. 결과 판정 (성공/실패 카운트)
done < tmp_list.dat

### 5. SUMMARY 출력
- 총 소요시간
- 성공/실패 건수
- 실패 테이블 목록

### 6. 임시 파일 삭제
rm -f tmp_list.dat
```

## 로그 출력 형식
- PROSYNC_GZIP_IMPDP.sh와 동일한 포맷 적용
  - [N/Total] OWNER.TABLE 헤더
  - STEP 1/2 Query Build, STEP 2/2 EXPDP
  - 스텝별 Elapsed
  - [OK] / [FAIL] 결과
  - SUMMARY (총 소요시간, 성공/실패, 실패 목록)
- 로그 파일 : ${BASE_PATH}/log/CANADA_EXPDP_YYYYMMDD_HHMMSS.log

## 파일
- CANADA_EXPDP_PLAN.md : 본 계획서
- CANADA_EXPDP.sh : 구현 쉘 스크립트
