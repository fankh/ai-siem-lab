# 오픈소스 AI-SIEM 스택 — OpenSearch + Dashboards + Ollama

상용 Elastic(Platinum/Enterprise) AI 기능을 **무료·로컬·Docker**로 대체하는 실습 스택.

| 상용 (Elastic) | 이 스택 (오픈소스) |
|---|---|
| Kibana (유료 티어) | OpenSearch Dashboards |
| Elastic ML 이상 탐지 (Platinum) | OpenSearch Anomaly Detection (RCF) |
| Elastic AI Assistant (Enterprise + LLM 커넥터) | Dashboards Assistant + ml-commons + **Ollama** |
| 유료 LLM API 커넥터 | 로컬 **Ollama** (qwen2.5:3b 등) |

> ⚠️ **실습 전용**: 보안 플러그인(TLS/인증)을 끈 구성입니다. 운영 환경에 사용하지 마세요.

## 요구 사항
- Docker Desktop / Docker Engine + Compose v2
- **RAM**: 기본 모델 `qwen2.5:3b`(~2GB) 기준 **8GB 권장**. 초저사양은 `.env`에서 `OLLAMA_MODEL=qwen2.5:1.5b`(~1GB), 고사양은 `qwen2.5:7b`/`llama3.1:8b`. (⚠️ `llama3.2:3b`는 한국어 출력 불안정으로 비권장)
- 리눅스 호스트: `sudo sysctl -w vm.max_map_count=262144` (Docker Desktop/WSL2는 보통 불필요)
- `setup.sh` 실행용: bash·curl·jq·sed (Windows는 **git-bash** 또는 **WSL**)

## 빠른 시작
```bash
cd ai-siem-lab/labs/opensearch-ai
docker compose up -d          # 4개 컨테이너 기동 (OpenSearch·Dashboards·Ollama·tools)
./setup.sh                    # 모델 다운로드 + ml-commons 연결 + 추론 테스트
```
- Dashboards: http://localhost:5601
- OpenSearch: http://localhost:9200
- Ollama: http://localhost:11434

`setup.sh` 가 출력하는 **`model_id`** 를 메모해 두세요(아래 Assistant 연결에 사용).

## 테스트 도구 컨테이너 (tools) — OS 무관 실행

호스트에 curl/jq/python 설치 없이 모든 테스트 명령을 `tools` 컨테이너에서 실행합니다
(Windows/Mac/Linux 동일). nicolaka/netshoot 기반 — **curl·jq·python3·nmap·dig** 포함, 랩 폴더가 `/lab` 로 마운트됨.

> 컨테이너 안에서는 `localhost` 대신 **서비스명**으로 접근: `opensearch:9200`, `ollama:11434`

```bash
# 대화형 접속 (셸 진입; 작업폴더 /lab, 종료 exit) — docker exec -it ai-siem-tools bash 도 가능
docker compose exec tools bash
# 헬스 체크
docker compose exec tools curl -s http://opensearch:9200/_cluster/health | jq .status
# 샘플 데이터 적재 (호스트 python 불필요)
docker compose exec tools python3 sample-data/load_sample_logs.py http://opensearch:9200
# 보안 테스트 예 — 스택 포트 스캔
docker compose exec tools nmap -p 9200,5601,11434 opensearch ollama
```

### (대안) Windows PowerShell — 호스트 직접 실행
도구 컨테이너 대신 호스트에서 실행하려면 `curl.exe` 사용:
```powershell
curl.exe -s http://localhost:9200/_cluster/health
# 한글/복잡 JSON 본문은 파일로: curl.exe -H "Content-Type: application/json" -d "@body.json" http://localhost:9200/...
```
> `Invoke-RestMethod` 는 한글 본문 시 `[Text.Encoding]::UTF8.GetBytes($body)` + `-ContentType 'application/json; charset=utf-8'` 필요.

## 무엇이 되나
- OpenSearch에 **로컬 LLM이 등록**되어 `_predict` 로 추론 가능 (alert triage, 요약, 쿼리 생성 등)
- Dashboards **Anomaly Detection** 플러그인(무료)으로 이상 탐지 Job 생성
- (선택) Dashboards **Assistant 챗**에서 자연어로 질의

## Assistant 챗 연결 (root agent) — 선택/심화
> ml-commons 에이전트 스키마는 OpenSearch 버전마다 다릅니다. 아래는 2.x 기준 예시이며,
> 본인 버전 문서(`ml-commons-plugin/opensearch-assistant`)로 필드를 확인하세요.

```bash
OS=http://localhost:9200
MODEL_ID=<setup.sh 가 출력한 값>

# 1) 대화형 root agent 생성
AGENT_ID=$(curl -s -XPOST "$OS/_plugins/_ml/agents/_register" -H 'Content-Type: application/json' -d "{
  \"name\": \"SOC Chat Agent\",
  \"type\": \"conversational\",
  \"description\": \"Dashboards Assistant root agent\",
  \"llm\": { \"model_id\": \"$MODEL_ID\",
             \"parameters\": { \"max_iteration\": 5,
                               \"response_filter\": \"\$.choices[0].message.content\" } },
  \"memory\": { \"type\": \"conversation_index\" },
  \"tools\": [ { \"type\": \"MLModelTool\", \"name\": \"chat\",
                 \"parameters\": { \"model_id\": \"$MODEL_ID\",
                                   \"prompt\": \"\${parameters.question}\" } } ],
  \"app_type\": \"os_chat\"
}" | jq -r '.agent_id')

# 2) Assistant 의 root agent 로 등록
curl -s -XPUT "$OS/.plugins-ml-config/_doc/os_chat" -H 'Content-Type: application/json' -d "{
  \"type\": \"os_chat_root_agent\",
  \"configuration\": { \"agent_id\": \"$AGENT_ID\" }
}"
```
이후 Dashboards 우상단 챗 아이콘에서 사용. (`config/opensearch_dashboards.yml`의 `assistant.chat.enabled: true` 필요)

## 정리/종료
```bash
docker compose down          # 컨테이너 중지 (데이터 유지)
docker compose down -v       # 볼륨까지 삭제 (모델·인덱스 초기화)
```

## 트러블슈팅
- **OpenSearch가 바로 종료**: 메모리/`vm.max_map_count` 부족. 힙(`OPENSEARCH_JAVA_OPTS`)·호스트 RAM 확인
- **커넥터 신뢰 오류**(`untrusted endpoint`): `setup.sh`의 `trusted_connector_endpoints_regex` 적용 여부 확인
- **추론 타임아웃**: 모델 첫 로드시 지연 → 잠시 후 재시도, 또는 더 작은 모델 사용
- **jq 없음(Windows)**: git-bash에 jq 설치하거나 WSL에서 실행
- **호스트에 네이티브 Ollama 존재(:11434 충돌)**: setup.sh의 모델 다운로드가 컨테이너가 아닌
  네이티브로 갈 수 있음 → `docker exec ollama ollama pull <model>` 로 컨테이너에 직접 받기.
  OpenSearch는 docker 네트워크의 `ollama:11434`(컨테이너)로 접속하므로 호스트 포트 충돌과 무관.
- **커넥터 credential 오류**: ml-commons는 무인증이어도 `credential` 필드를 요구 → setup.sh에 더미 키 포함됨.

> ✅ 이 스택은 2026-06-16 본 머신(Docker Desktop 4.77, OpenSearch 2.19.0, qwen2.5:3b)에서
> connector→model→deploy→추론(few-shot 트리아지)까지 정상 동작 검증됨.

## 참고
- OpenSearch Assistant Toolkit · ml-commons(agents/tools) · Anomaly Detection 공식 문서
- Ollama OpenAI 호환 API: `/v1/chat/completions`
