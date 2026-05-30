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

# ── HTTP チェック関数 (内部) ─────────────────────────────
# ブラウザ用URL(localhost:1xxxx)を内部URLへ変換してNginxコンテナ経由でcurl
# 経路: devcontainer → docker exec → Nginxコンテナ内curl → Docker内部NW
# usage: check_http <label> <browser_url> [expected_substr]
PROXY_CONTAINER="env-keycloaked-reverse-proxy-1"

# ── HTTP チェック関数 (外部) ─────────────────────────────
# 実行環境を自動判定してcurl先を切り替える
# - devcontainer内: localhost → Dockerブリッジgateway IP に変換してcurl
# - WSL2/ホスト  : localhost をそのまま使用してcurl
# usage: check_host <label> <browser_url> [expected_substr]

# 実行環境判定: /.dockerenv の有無でDockerコンテナ内か判断
if [ -f /.dockerenv ]; then
  IS_INSIDE_CONTAINER=true
  DOCKER_HOST_IP=$(ip route show default 2>/dev/null | awk 'NR==1{print $3}')
else
  IS_INSIDE_CONTAINER=false
  DOCKER_HOST_IP="localhost"
fi

check_host() {
  local label="$1"
  local url="$2"          # ブラウザからアクセスするURL（表示用）
  local expected="${3:-}"

  # 実行環境に応じてcurl先を切り替え
  local curl_url
  if [[ "$IS_INSIDE_CONTAINER" == "true" ]]; then
    # devcontainer内: localhost → Dockerブリッジgateway IP に変換
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      printf "  $WARN %s\n" "$label"
      printf "       Docker ホストIPが取得できません\n"
      return
    fi
    curl_url="${url/localhost/$DOCKER_HOST_IP}"
  else
    # WSL2/ホスト: localhost をそのまま使用
    curl_url="$url"
  fi

  local http_code="" content=""
  http_code=$(curl -s -o /tmp/_ck_host -w "%{http_code}" \
    --max-time 5 --connect-timeout 3 "$curl_url" 2>/dev/null) || http_code=""
  content=$(cat /tmp/_ck_host 2>/dev/null) || content=""

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
    printf "       ${RED}%s${RESET}  到達不可 (ポート転送未設定 or タイムアウト)\n" "$url"
  else
    printf "  $NG %s\n" "$label"
    printf "       ${RED}%s${RESET}  HTTP %s\n" "$url" "$http_code"
  fi
}

# ブラウザURL → コンテナ内部URL へ変換
to_internal_url() {
  local url="$1"
  url="${url/localhost:10800/localhost:800}"
  url="${url/localhost:18080/keycloak:8080}"
  url="${url/localhost:15173/frontend:5173}"
  url="${url/localhost:18000/backend:8000}"
  echo "$url"
}

check_http() {
  local label="$1"
  local url="$2"          # ブラウザからアクセスするURL（表示用）
  local expected="${3:-}"
  local internal_url
  internal_url=$(to_internal_url "$url")

  # コンテナが起動していなければスキップ
  local proxy_status
  proxy_status=$(docker inspect --format '{{.State.Status}}' "$PROXY_CONTAINER" 2>/dev/null || echo "not_found")
  if [[ "$proxy_status" != "running" ]]; then
    printf "  $WARN %-40s Nginx コンテナ未起動のためスキップ\n" "$label"
    return
  fi

  local result
  result=$(docker exec "$PROXY_CONTAINER" \
    sh -c "curl -s -o /tmp/_ck -w '%{http_code}' --max-time 5 --connect-timeout 3 '$internal_url' 2>/dev/null; echo; cat /tmp/_ck" \
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

# ── 内部疎通チェック (Docker NW経由) ─────────────────────
echo ""
echo -e "${BOLD}${CYAN}━━━ サービス間疎通 (Docker 内部NW経由) ━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "    各コンテナが互いに通信できるか確認します"
echo -e "    ${CYAN}devcontainer ─[docker exec]→ Nginxコンテナ内 curl ─[Docker内部NW]→ 各サービス${RESET}"
echo ""

echo -e "  ${BOLD}[ Reverse Proxy 経由 (Nginx:800) ]${RESET}"
check_http "Frontend トップ"        "http://localhost:10800/"
check_http "Backend ヘルスチェック" "http://localhost:10800/api/health"  '"ok"'
check_http "Backend Swagger UI"     "http://localhost:10800/api/docs"
check_http "Keycloak トップ"        "http://localhost:10800/auth/"

echo ""
echo -e "  ${BOLD}[ 直アクセス (内部サービス名) ]${RESET}"
check_http "Frontend   :15173"       "http://localhost:15173/"
check_http "Backend    :18000/health" "http://localhost:18000/health"  '"ok"'
check_http "Backend    :18000/docs"   "http://localhost:18000/docs"
check_http "Keycloak   :18080"       "http://localhost:18080/auth/"

# ── 外部疎通チェック (ポート転送経由) ────────────────────
echo ""
echo -e "${BOLD}${CYAN}━━━ ポートバインド確認 (ホストポートに届くか) ━━━━━━━━━━━━━━${RESET}"
echo -e "    Dockerのポートバインド(0.0.0.0)が機能しているか確認します"
if [[ "$IS_INSIDE_CONTAINER" == "true" ]]; then
  echo -e "    ${CYAN}devcontainer ─[${DOCKER_HOST_IP:-不明}:PORT]→ Dockerホスト ─[port binding]→ 各コンテナ${RESET}"
  echo -e "    ※ ローカル環境では OK = ブラウザからも到達可能"
else
  echo -e "    ${CYAN}WSL2/ホスト ─[localhost:PORT]→ Docker ─[port binding]→ 各コンテナ${RESET}"
  echo -e "    ※ ホストから直接確認（ブラウザと同等の経路）"
fi
echo ""

echo -e "  ${BOLD}[ Reverse Proxy 経由 (ホスト:10800) ]${RESET}"
check_host "Frontend トップ"        "http://localhost:10800/"
check_host "Backend ヘルスチェック" "http://localhost:10800/api/health"  '"ok"'
check_host "Backend Swagger UI"     "http://localhost:10800/api/docs"
check_host "Keycloak トップ"        "http://localhost:10800/auth/"

echo ""
echo -e "  ${BOLD}[ 直アクセス ]${RESET}"
check_host "Frontend   :15173"       "http://localhost:15173/"
check_host "Backend    :18000/health" "http://localhost:18000/health"  '"ok"'
check_host "Backend    :18000/docs"   "http://localhost:18000/docs"
check_host "Keycloak   :18080"       "http://localhost:18080/auth/"

echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
