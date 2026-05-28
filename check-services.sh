#!/usr/bin/env bash
# check-services.sh — 各サービスの状態を一発確認

set -euo pipefail

# ── 色定義 ────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

OK="${GREEN}[  OK  ]${RESET}"
NG="${RED}[  NG  ]${RESET}"
WARN="${YELLOW}[ WARN ]${RESET}"

# ── HTTP チェック関数 ──────────────────────────────────
# Nginx コンテナ(curl 有り・内部NW到達可)経由で実行
# usage: check_http <label> <url> [expected_substr]
PROXY_CONTAINER="env-keycloaked-reverse-proxy-1"

check_http() {
  local label="$1"
  local url="$2"
  local expected="${3:-}"

  # コンテナが起動していなければスキップ
  local proxy_status
  proxy_status=$(docker inspect --format '{{.State.Status}}' "$PROXY_CONTAINER" 2>/dev/null || echo "not_found")
  if [[ "$proxy_status" != "running" ]]; then
    printf "  $WARN %-40s Nginx コンテナ未起動のためスキップ\n" "$label"
    return
  fi

  local result
  result=$(docker exec "$PROXY_CONTAINER" \
    sh -c "curl -s -o /tmp/_ck -w '%{http_code}' --max-time 5 --connect-timeout 3 '$url' 2>/dev/null; echo; cat /tmp/_ck" \
    2>/dev/null) || result=""

  local http_code content
  http_code=$(echo "$result" | head -1 | tr -d '[:space:]')
  content=$(echo "$result" | tail -n +2)

  if [[ "$http_code" =~ ^[23] ]]; then
    if [[ -n "$expected" && "$content" != *"$expected"* ]]; then
      printf "  $WARN %s\n" "$label"
      printf "       ${YELLOW}%s${RESET}  HTTP %s  (期待値 '%s' が見つからない)\n" \
        "$url" "$http_code" "$expected"
    else
      printf "  $OK %s\n" "$label"
      printf "       ${GREEN}%s${RESET}  HTTP %s\n" "$url" "$http_code"
    fi
  elif [[ -z "$http_code" ]]; then
    printf "  $NG %s\n" "$label"
    printf "       ${RED}%s${RESET}  接続タイムアウト\n" "$url"
  else
    printf "  $NG %s\n" "$label"
    printf "       ${RED}%s${RESET}  HTTP %s\n" "$url" "$http_code"
  fi
}

# ── Docker コンテナ状態 ────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}━━━ Docker コンテナ ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

declare -A SERVICE_LABELS=(
  [reverse-proxy]="Nginx (Reverse Proxy)"
  [keycloak]="Keycloak"
  [frontend]="Frontend (Vite)"
  [backend]="Backend (FastAPI)"
)

for svc in reverse-proxy keycloak frontend backend; do
  label="${SERVICE_LABELS[$svc]}"
  # compose プロジェクト名は env-keycloaked
  container="env-keycloaked-${svc}-1"
  status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "not_found")
  health=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "")

  case "$status" in
    running)
      health_str=""
      [[ -n "$health" ]] && health_str=" (health: ${health})"
      printf "  $OK %-40s running%s\n" "$label" "$health_str"
      ;;
    not_found)
      printf "  $NG %-40s コンテナが見つかりません\n" "$label"
      ;;
    *)
      printf "  $NG %-40s %s\n" "$label" "$status"
      ;;
  esac
done

# ── HTTP エンドポイント ────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}━━━ HTTP エンドポイント ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

echo -e "  ${BOLD}[ Reverse Proxy 経由 (Nginx:80 / ホスト:10080) ]${RESET}"
check_http "Frontend トップ"        "http://localhost:80/"
check_http "Backend ヘルスチェック" "http://localhost:80/api/health"  '"ok"'
check_http "Backend Swagger UI"     "http://localhost:80/api/docs"
check_http "Keycloak トップ"        "http://localhost:80/auth/"

echo ""
echo -e "  ${BOLD}[ 直アクセス (内部サービス名) ]${RESET}"
check_http "Keycloak   :8080"        "http://keycloak:8080/auth/"
check_http "Frontend   :5173"        "http://frontend:5173/"
check_http "Backend    :8000/health" "http://backend:8000/health"  '"ok"'
check_http "Backend    :8000/docs"   "http://backend:8000/docs"

echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
