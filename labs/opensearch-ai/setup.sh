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

echo "[6/6] 추론 테스트"
curl -s -XPOST "$OS_URL/_plugins/_ml/models/$MODEL_ID/_predict" -H 'Content-Type: application/json' -d '{
  "parameters": { "messages": [
    {"role":"system","content":"You are a SOC analyst assistant. Answer concisely in Korean."},
    {"role":"user","content":"401 응답이 동일 IP에서 1분에 50회 발생하면 무슨 공격인가? 한 문장."}
  ]}
}' | jq -r '.inference_results[0].output[0].dataAsMap.choices[0].message.content // .'

rm -rf "$TMP"
cat <<EOF

✅ 완료. OpenSearch ml-commons에서 로컬 LLM 사용 가능.
   model_id = $MODEL_ID

다음 단계(선택) — Dashboards Assistant 챗 연결:
   README.md 의 "Assistant 챗 연결(root agent)" 절 참고 ($MODEL_ID 사용)
EOF
