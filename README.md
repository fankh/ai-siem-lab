# AI-SIEM Lab — OpenSearch + Dashboards + Ollama (오픈소스)

상용 SIEM의 AI 기능(이상 탐지·LLM 경보 분석)을 **무료·로컬·Docker** 오픈소스 스택으로 실습하는 랩.

| 기능 | 스택 |
|------|------|
| 수집·저장·시각화 | OpenSearch + OpenSearch Dashboards |
| 이상 탐지 | OpenSearch Anomaly Detection (RCF, 무료 내장) |
| LLM 경보 분석 | ml-commons + 로컬 **Ollama** (Llama 3.x) |

> ⚠️ **실습 전용**: 보안 플러그인(TLS/인증)을 끈 구성입니다. 운영 환경에 사용하지 마세요.

## 요구 사항
- Docker Desktop / Docker Engine + Compose v2, **RAM 8GB+**
- `setup.sh` 실행용 bash·curl·jq (Windows 는 git-bash 또는 WSL)

## 빠른 시작
```bash
git clone https://github.com/fankh/ai-siem-lab.git
cd ai-siem-lab/labs/opensearch-ai
docker compose up -d        # OpenSearch · Dashboards · Ollama · tools
docker exec ollama ollama pull llama3.2:3b
./setup.sh                  # 커넥터→모델→배포→추론 테스트
docker compose exec tools python3 sample-data/load_sample_logs.py http://opensearch:9200
```
- Dashboards <http://localhost:5601> · OpenSearch <http://localhost:9200> · Ollama <http://localhost:11434>

> 명령은 OS 무관하게 **`tools` 컨테이너**에서 실행하세요(curl·jq·python3·nmap 내장).
> 컨테이너 안에서는 `localhost` 대신 서비스명: `opensearch:9200`, `ollama:11434`.

## 구성
| 경로 | 설명 |
|------|------|
| `labs/opensearch-ai/` | Docker 스택 (docker-compose·setup.sh·sample-data) |
| `1~4시간_테스트_보안가이드.md` | 시간별 검증 + 보안 테스트 가이드(공격 시뮬레이션·프롬프트 인젝션 등) |
| `오픈소스_AI-SIEM_4시간_실습매뉴얼.md` | 통합 실습 매뉴얼(4블록) |

## 실습 흐름 (4블록)
1. **환경·데이터 탐색** — 스택 기동, 716건 보안 로그 적재, Discover/Dev Tools
2. **위협 헌팅·이상 탐지** — 브루트포스/SQLi 탐지 쿼리 + Anomaly Detection(RCF)
3. **LLM 경보 분석** — ml-commons + Ollama 로 경보 트리아지(한국어)
4. **종합 시나리오** — 탐지 → 분석 → 관제 보고서 초안

---
교육용 자료입니다 (Educational use). 자세한 절차는 실습 매뉴얼과 시간별 가이드를 참고하세요.
