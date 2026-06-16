# 오픈소스 AI-SIEM 4시간 실습 매뉴얼

**과정**: 오픈소스 AI-SIEM 관제 실습 (4시간) · **스택**: OpenSearch + Dashboards + Ollama (전부 오픈소스·로컬)
**검증**: 본 매뉴얼의 모든 명령/결과는 2026-06-15 실제 스택에서 검증됨

> 이 매뉴얼은 **실습(hands-on)** 절반을 담당합니다. 이론(개념 설명)은 동반 슬라이드
> `markdown/N시간_*.md` (시간별 4개) 가 담당하며, 4개 블록 각각 **이론 25분 + 실습 25분** 구성입니다.

---

## 0. 사전 준비 (수업 전 / 0교시, ~15분)

### 요구 사항
- Docker Desktop / Docker Engine + Compose v2, **RAM 8GB+**
- 실습 파일: `labs/opensearch-ai/` (docker-compose.yml, setup.sh, sample-data/)

### 0-1. 스택 기동
```bash
cd labs/opensearch-ai
docker compose up -d            # OpenSearch + Dashboards + Ollama
docker compose ps               # 3개 컨테이너 healthy 확인
```

### 0-2. Ollama 모델 + ml-commons 연결
```bash
# 실습용 경량 모델 (품질은 8b 권장, 저사양은 3b)
docker exec ollama ollama pull llama3.2:3b
./setup.sh                       # 커넥터→모델→배포→추론 테스트 (git-bash/WSL, curl·jq 필요)
```
> Windows 네이티브 Ollama가 :11434를 점유 중이면, 모델은 `docker exec ollama ollama pull` 로
> **컨테이너에 직접** 받습니다. OpenSearch는 docker 네트워크 `ollama:11434`(컨테이너)로 접속합니다.

### 0-3. 샘플 보안 로그 적재
```bash
python sample-data/load_sample_logs.py http://localhost:9200
# → loaded 716 docs into 'security-web' (정상 550 + 브루트포스 160 + SQLi/XSS 6)
```

### 0-4. 엔드포인트 확인
| 서비스 | URL | 확인 |
|--------|-----|------|
| OpenSearch | http://localhost:9200 | `_cluster/health` |
| Dashboards | http://localhost:5601 | UI 접속 |
| Ollama | http://localhost:11434 | `/api/version` |

---

## 블록 1 — 환경 & 데이터 탐색 (실습 25분)

### 1-1. Dashboards Data View 생성
1. http://localhost:5601 → **Stack Management → Data Views → Create data view**
2. 이름/패턴: `security-web` , 타임스탬프 필드: `@timestamp`

### 1-2. Discover 탐색
- **Discover** 에서 `security-web` 선택 → 최근 3시간 로그 확인
- 검색창(DQL): `http.response.status_code: 401` → 로그인 실패만 필터

### 1-3. 쿼리로 데이터 확인 (Dev Tools)
```
GET security-web/_count
GET security-web/_search
{ "size": 1, "sort": [{ "@timestamp": "desc" }] }
```
✅ 체크포인트: 문서 716건, source.ip / url.path / http.response.status_code 필드 확인

---

## 블록 2 — 위협 헌팅 & 이상 탐지 (실습 25분)

### 2-1. 브루트포스 탐지 — 401 최다 IP (검증된 결과)
```
POST security-web/_search
{
  "size": 0,
  "query": { "term": { "http.response.status_code": 401 } },
  "aggs": { "by_ip": { "terms": { "field": "source.ip", "size": 5 } } }
}
```
**실제 결과**:
```
source.ip      401_count
10.13.37.7     120          ← 브루트포스 공격자
```

### 2-2. SQLi 탐지 — UNION SELECT 흔적 (검증된 결과)
```
POST security-web/_search
{ "size": 5, "_source": ["source.ip","url.query","user_agent.original"],
  "query": { "wildcard": { "url.query": "*UNION*" } } }
```
**실제 결과**: `45.155.205.99` , `user_agent=sqlmap/1.7` , `url.query=...UNION SELECT username,password...`

### 2-3. Anomaly Detection 생성 (RCF, 무료 내장)
```
POST _plugins/_anomaly_detection/detectors
{
  "name": "web-ip-spike",
  "time_field": "@timestamp",
  "indices": ["security-web"],
  "feature_attributes": [
    { "feature_name": "req_count", "feature_enabled": true,
      "aggregation_query": { "req_count": { "value_count": { "field": "url.path" } } } }
  ],
  "detection_interval": { "period": { "interval": 10, "unit": "Minutes" } },
  "category_field": ["source.ip"]
}
```
시작: `POST _plugins/_anomaly_detection/detectors/<detector_id>/_start`
> ⚠️ RCF는 기준선 학습에 **데이터 누적/시간**이 필요합니다. 실습에서는 **생성·시작 절차**를 익히고,
> 즉시 탐지는 2-1·2-2의 쿼리(룰 기반)로 수행합니다 → **다층 방어**(룰 + 이상탐지).

✅ 체크포인트: 공격 IP 2건 식별(10.13.37.7 브루트포스, 45.155.205.99 SQLi), Detector 생성됨

---

## 블록 3 — LLM 경보 분석 (ml-commons + Ollama) (실습 25분)

### 3-1. ml-commons 설정 (1회)
```
PUT _cluster/settings
{ "persistent": {
  "plugins.ml_commons.only_run_on_ml_node": false,
  "plugins.ml_commons.connector.private_ip_enabled": true,
  "plugins.ml_commons.trusted_connector_endpoints_regex": ["^http://ollama:11434/.*$"]
}}
```

### 3-2. 커넥터 → 모델 → 배포
```
POST _plugins/_ml/connectors/_create
{ "name":"Ollama Chat","version":"1","protocol":"http",
  "credential": { "key":"ollama-no-auth" },          ← 무인증이어도 필수
  "parameters": { "endpoint":"ollama:11434", "model":"llama3.2:3b" },
  "actions": [{ "action_type":"predict","method":"POST",
    "url":"http://${parameters.endpoint}/v1/chat/completions",
    "request_body":"{\"model\":\"${parameters.model}\",\"messages\":${parameters.messages}}" }] }
```
```
POST _plugins/_ml/models/_register
{ "name":"ollama-chat","function_name":"remote","connector_id":"<CONNECTOR_ID>" }
POST _plugins/_ml/models/<MODEL_ID>/_deploy        → model_state: DEPLOYED
```
> `setup.sh` 가 위 과정을 자동화합니다(커넥터~추론 테스트).

**배포된 모델 ID 확인** (여러 모델이 있으면 **큰 모델**을 선택 — 품질↑):
```
GET _plugins/_ml/models/_search
{ "query": { "term": { "model_state": "DEPLOYED" } }, "_source": ["name","model_state"] }
```
> ⚠️ 0.5b 같은 초소형 모델은 트리아지 품질이 낮습니다. 실습은 **llama3.2:3b 이상**을 사용하세요.

### 3-3. 경보 트리아지 (검증된 결과)
블록 2에서 찾은 공격 IP를 LLM에 넘겨 분류·요약합니다.
```
POST _plugins/_ml/models/<MODEL_ID>/_predict
{ "parameters": { "messages": [
  {"role":"system","content":"너는 SOC 분석가다. 한국어로 간결히 트리아지: 1)공격유형 2)심각도 3)근거 4)권고조치"},
  {"role":"user","content":"source.ip 10.13.37.7 이 12분간 /login POST 120건, 대부분 401, UA=python-requests/2.31. 정상 IP 평균은 10건 미만."} ] } }
```
**실제 LLM 응답 (llama3.2:3b)**:
```
1) 공격유형: 브루트포스(Brute Force) 로그인 공격
2) 심각도: 상(High)
3) 근거: 10.13.37.7 이 12분간 /login POST 120건, 대부분 401, UA=python-requests/2.31
4) 권고조치: 로그인 rate limit 적용, 해당 IP 차단, 로그인 시도 모니터링 강화
```

> **한글 인코딩 주의**: curl은 UTF-8 본문을 파일(`-d @body.json`)로 보내면 안전합니다.
> Windows PowerShell `Invoke-RestMethod` 는 본문을 UTF-8 바이트로 변환해 보내야 합니다:
> `[Text.Encoding]::UTF8.GetBytes($body)` + `-ContentType 'application/json; charset=utf-8'`.

✅ 체크포인트: OpenSearch → Ollama 경로로 경보가 한국어 트리아지로 변환됨 (라이선스·API 비용 0)

---

## 블록 4 — 종합 시나리오 (실습 25분)

**시나리오**: 외부 IP 웹 공격 탐지 → 분석 → 보고서 초안 자동 생성

1. **탐지**: 블록 2 쿼리로 공격 IP 식별 (10.13.37.7 / 45.155.205.99)
2. **상세 조사**: 해당 IP의 로그 추출
   ```
   POST security-web/_search
   { "query": { "term": { "source.ip": "45.155.205.99" } },
     "_source": ["@timestamp","url.path","url.query","http.response.status_code"] }
   ```
3. **LLM 분석/요약**: 추출한 로그를 `_predict` 의 user content에 넣어 공격 유형·영향·대응 요약
4. **관제 보고서 초안**: 프롬프트를 "관제 보고서 형식(개요/탐지/분석/영향/대응/권고)으로 작성"으로 변경 → 초안 생성
5. **(선택) Dashboards Assistant**: root agent 등록 후 우상단 챗에서 대화형 분석
   (절차: `labs/opensearch-ai/README.md` "Assistant 챗 연결")

✅ 최종 산출물: 공격 IP 식별 → LLM 분석 → **관제 보고서 초안** (관제 보고서 양식에 정리)

---

## 정리 / 트러블슈팅

### 종료
```bash
docker compose -f labs/opensearch-ai/docker-compose.yml down      # 데이터 유지
docker compose -f labs/opensearch-ai/docker-compose.yml down -v   # 볼륨까지 삭제
```

### 자주 묻는 문제
| 증상 | 원인/해결 |
|------|-----------|
| OpenSearch 즉시 종료 | RAM/`vm.max_map_count` 부족 → 힙·메모리 확인 |
| 커넥터 `credential is null` | `credential` 필드 누락 → 더미 키 추가 |
| 커넥터 `version is null` | `"version":"1"` 누락 |
| `untrusted endpoint` | `trusted_connector_endpoints_regex` 미적용 |
| LLM 한글 깨짐 | 본문을 UTF-8로 전송 (curl `-d @file` 또는 PS UTF-8 bytes) |
| 트리아지 품질 낮음 | 모델 키우기: `llama3.2:3b` → `llama3.1:8b` |

### 모델 선택 가이드
| 모델 | 크기 | 용도 |
|------|------|------|
| qwen2.5:0.5b | 0.4GB | 배선 점검용(품질 낮음) |
| **llama3.2:3b** | 2GB | 실습 표준(본 매뉴얼 검증) |
| llama3.1:8b | 5GB | 운영 품질 권장 |

---

**검증 환경**: Docker Desktop 4.77, OpenSearch/Dashboards 2.19.0, Ollama 0.30.7, llama3.2:3b
(2026-06-15 본 머신 실측 — 데이터 적재 716건, 브루트포스/SQLi 탐지, 이상탐지 Detector 생성, LLM 트리아지 정상)
