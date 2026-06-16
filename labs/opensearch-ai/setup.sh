#!/usr/bin/env bash
# Ollama LLM을 OpenSearch ml-commons에 연결 (connector → model → deploy → test)
# 실행: docker compose up -d  후  ./setup.sh
# 요구: bash, curl, jq, sed  (Windows는 git-bash 또는 WSL)
set -euo pipefail

OS_URL="${OS_URL:-http://localhost:9200}"
OLLAMA_HOST_URL="${OLLAMA_HOST_URL:-http://localhost:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5:3b}"   # 저사양 표준. .env 에서 변경 가능(초저사양 qwen2.5:1.5b)
TMP="$(mktemp -d)"

echo "[1/6] OpenSearch 대기..."
until curl -sf "$OS_URL/_cluster/health" >/dev/null; do sleep 3; done
echo "      OK"

echo "[2/6] Ollama 모델 다운로드: $OLLAMA_MODEL (최초 1회, 수 GB)"
curl -s "$OLLAMA_HOST_URL/api/pull" -d "{\"name\":\"$OLLAMA_MODEL\"}" | tail -1
echo "      완료"

echo "[3/6] ml-commons 기능 활성화 + Ollama 엔드포인트 신뢰 등록"
curl -s -XPUT "$OS_URL/_cluster/settings" -H 'Content-Type: application/json' -d '{
  "persistent": {
    "plugins.ml_commons.only_run_on_ml_node": false,
    "plugins.ml_commons.memory_feature_enabled": true,
    "plugins.ml_commons.rag_pipeline_feature_enabled": true,
    "plugins.ml_commons.agent_framework_enabled": true,
    "plugins.ml_commons.connector.private_ip_enabled": true,
    "plugins.ml_commons.trusted_connector_endpoints_regex": ["^http://ollama:11434/.*$"]
  }
}' >/dev/null
echo "      완료"

echo "[4/6] 커넥터 생성 (Ollama OpenAI 호환 /v1/chat/completions)"
# 단일따옴표 heredoc → ${parameters.*} 는 OpenSearch 로 그대로 전달
cat > "$TMP/connector.json" <<'JSON'
{
  "name": "Ollama Chat (OpenAI-compatible)",
  "description": "Local Ollama via /v1/chat/completions",
  "version": "1",
  "protocol": "http",
  "credential": { "key": "ollama-no-auth" },
  "parameters": { "endpoint": "ollama:11434", "model": "__MODEL__" },
  "actions": [{
    "action_type": "predict",
    "method": "POST",
    "url": "http://${parameters.endpoint}/v1/chat/completions",
    "headers": { "Content-Type": "application/json" },
    "request_body": "{ \"model\": \"${parameters.model}\", \"messages\": ${parameters.messages}, \"temperature\": 0 }"
  }]
}
JSON
sed -i "s|__MODEL__|$OLLAMA_MODEL|" "$TMP/connector.json"
CONNECTOR_ID=$(curl -s -XPOST "$OS_URL/_plugins/_ml/connectors/_create" \
  -H 'Content-Type: application/json' -d @"$TMP/connector.json" | jq -r '.connector_id')
echo "      connector_id=$CONNECTOR_ID"

echo "[5/6] 모델 등록 + 배포"
MODEL_ID=$(curl -s -XPOST "$OS_URL/_plugins/_ml/models/_register" -H 'Content-Type: application/json' -d "{
  \"name\": \"ollama-chat\",
  \"function_name\": \"remote\",
  \"description\": \"Ollama $OLLAMA_MODEL\",
  \"connector_id\": \"$CONNECTOR_ID\"
}" | jq -r '.model_id')
curl -s -XPOST "$OS_URL/_plugins/_ml/models/$MODEL_ID/_deploy" >/dev/null
# 배포 상태 대기
for i in $(seq 1 20); do
  STATE=$(curl -s "$OS_URL/_plugins/_ml/models/$MODEL_ID" | jq -r '.model_state')
  [ "$STATE" = "DEPLOYED" ] && break
  sleep 3
done
echo "      model_id=$MODEL_ID  state=$STATE"

echo "[6/6] 추론 테스트 (few-shot 트리아지 — 소형 모델도 정확/안정. 커넥터가 temperature=0 적용)"
curl -s -XPOST "$OS_URL/_plugins/_ml/models/$MODEL_ID/_predict" -H 'Content-Type: application/json' -d '{
  "parameters": { "messages": [
    {"role":"system","content":"너는 SOC 분석가다. 한국어 3줄로 답하라 — 1)공격유형 2)심각도(상/중/하) 3)권고. 공격유형은 [브루트포스,SQLi,XSS,스캐닝,정상] 중 하나. 신호: /login 401 다수=브루트포스, UNION SELECT나 UA=sqlmap=SQLi, <script>=XSS, 경로 404 다수=스캐닝, 2xx 정상응답만=정상."},
    {"role":"user","content":"5.5.5.5 가 2분간 /login 에 POST 200건, 대부분 401, UA=hydra."},
    {"role":"assistant","content":"공격유형: 브루트포스\n심각도: 상\n권고: 해당 IP 차단 + 로그인 rate limit."},
    {"role":"user","content":"7.7.7.7 가 /search?q=<script>alert(1)</script> 요청."},
    {"role":"assistant","content":"공격유형: XSS\n심각도: 중\n권고: 입력 검증·출력 인코딩."},
    {"role":"user","content":"192.168.10.5 가 /index.html, /a.css GET 12건 모두 200."},
    {"role":"assistant","content":"공격유형: 정상\n심각도: 하\n권고: 조치 불필요."},
    {"role":"user","content":"10.13.37.7 이 1분간 /login 에 401 을 50회 발생, UA=python-requests."}
  ]}
}' | jq -r '.inference_results[0].output[0].dataAsMap.choices[0].message.content // .'

rm -rf "$TMP"
cat <<EOF

✅ 완료. OpenSearch ml-commons에서 로컬 LLM 사용 가능.
   model_id = $MODEL_ID

다음 단계(선택) — Dashboards Assistant 챗 연결:
   README.md 의 "Assistant 챗 연결(root agent)" 절 참고 ($MODEL_ID 사용)
EOF
