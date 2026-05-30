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
# Docker内部NWで解決できるURLをNginxコンテナ経由でcurl
# 経路: devcontainer → docker exec → Nginxコンテナ内curl → Docker内部NW
# usage: check_http <label> <internal_url> [expected_substr]
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

to_host_curl_url() {
  local url="$1"
  if [[ "$IS_INSIDE_CONTAINER" == "true" ]]; then
    if [[ -z "$DOCKER_HOST_IP" ]]; then
      return 1
    fi
    echo "${url/localhost/$DOCKER_HOST_IP}"
  else
    echo "$url"
  fi
}

to_host_header() {
  local url="$1"
  local without_scheme="${url#*://}"
  echo "${without_scheme%%/*}"
}

check_host() {
  local label="$1"
  local url="$2"          # ブラウザからアクセスするURL（表示用）
  local expected="${3:-}"

  local curl_url
  if ! curl_url=$(to_host_curl_url "$url"); then
    printf "  $WARN %s\n" "$label"
    printf "       Docker ホストIPが取得できません\n"
    return
  fi
  local host_header_args=()
  if [[ "$IS_INSIDE_CONTAINER" == "true" ]]; then
    host_header_args=(-H "Host: $(to_host_header "$url")")
  fi

  local http_code="" content=""
  http_code=$(curl -s -o /tmp/_ck_host -w "%{http_code}" \
    --max-time 5 --connect-timeout 3 "${host_header_args[@]}" "$curl_url" 2>/dev/null) || http_code=""
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
    printf "       ${RED}%s${RESET}  到達不可 (ポート公開未設定 or タイムアウト)\n" "$url"
  else
    printf "  $NG %s\n" "$label"
    printf "       ${RED}%s${RESET}  HTTP %s\n" "$url" "$http_code"
  fi
}

check_host_redirect() {
  local label="$1"
  local url="$2"
  local expected_location="$3"

  local curl_url
  if ! curl_url=$(to_host_curl_url "$url"); then
    printf "  $WARN %s\n" "$label"
    printf "       Docker ホストIPが取得できません\n"
    return
  fi
  local host_header_args=()
  if [[ "$IS_INSIDE_CONTAINER" == "true" ]]; then
    host_header_args=(-H "Host: $(to_host_header "$url")")
  fi

  local headers_file="/tmp/_ck_host_headers" http_code="" location=""
  http_code=$(curl -s -o /tmp/_ck_host -D "$headers_file" -w "%{http_code}" \
    --max-time 5 --connect-timeout 3 "${host_header_args[@]}" "$curl_url" 2>/dev/null) || http_code=""
  location=$(tr -d '\r' < "$headers_file" 2>/dev/null | awk 'tolower($1) == "location:" { $1=""; sub(/^ /, ""); print; exit }') || location=""

  if [[ "$http_code" =~ ^30[12378]$ && "$location" == *"$expected_location"* ]]; then
    printf "  $OK %s\n" "$label"
    printf "       ${GREEN}%s${RESET}  HTTP %s  -> %s\n" "$url" "$http_code" "$location"
  else
    printf "  $NG %s\n" "$label"
    printf "       ${RED}%s${RESET}  HTTP %s  -> %s  (期待 Location: %s)\n" \
      "$url" "${http_code:-到達不可}" "${location:-なし}" "$expected_location"
  fi
}

check_host_blocked() {
  local label="$1"
  local url="$2"

  local curl_url
  if ! curl_url=$(to_host_curl_url "$url"); then
    printf "  $WARN %s\n" "$label"
    printf "       Docker ホストIPが取得できません\n"
    return
  fi
  local host_header_args=()
  if [[ "$IS_INSIDE_CONTAINER" == "true" ]]; then
    host_header_args=(-H "Host: $(to_host_header "$url")")
  fi

  local http_code=""
  http_code=$(curl -s -o /tmp/_ck_host -w "%{http_code}" \
    --max-time 3 --connect-timeout 2 "${host_header_args[@]}" "$curl_url" 2>/dev/null) || http_code=""

  if [[ -z "$http_code" || "$http_code" == "000" ]]; then
    printf "  $OK %s\n" "$label"
    printf "       ${GREEN}%s${RESET}  到達不可\n" "$url"
  else
    printf "  $NG %s\n" "$label"
    printf "       ${RED}%s${RESET}  HTTP %s  (直接到達できています)\n" "$url" "$http_code"
  fi
}

check_http() {
  local label="$1"
  local url="$2"          # Docker内部NWで解決するURL
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
  [oauth2-proxy]="OAuth2 Proxy"
  [keycloak]="Keycloak"
  [frontend]="Frontend (Vite)"
  [backend]="Backend (FastAPI)"
)

for svc in reverse-proxy oauth2-proxy keycloak frontend backend; do
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

echo -e "  ${BOLD}[ 直アクセス (内部サービス名) ]${RESET}"
check_http "[5] Frontend   :5173"          "http://frontend:5173/"
check_http "[6] Backend    :8000/docs"      "http://backend:8000/docs"
check_http "[7] Keycloak   :8080"          "http://keycloak:8080/auth/"
check_http "[8] OAuth2 Proxy :4180/ping"   "http://oauth2-proxy:4180/ping"

# ── 認証ゲート確認 (ホスト公開ポート経由) ─────────────────
echo ""
echo -e "${BOLD}${CYAN}━━━ 認証ゲート確認 (ホスト公開ポート経由) ━━━━━━━━━━━━━━━${RESET}"
echo -e "    未認証リクエストがOAuth2ログインへ誘導されるか確認します"
if [[ "$IS_INSIDE_CONTAINER" == "true" ]]; then
  echo -e "    ${CYAN}devcontainer ─[${DOCKER_HOST_IP:-不明}:PORT]→ Dockerホスト ─[port binding]→ 各コンテナ${RESET}"
else
  echo -e "    ${CYAN}WSL2/ホスト ─[localhost:PORT]→ Docker ─[port binding]→ 各コンテナ${RESET}"
fi
echo ""

echo -e "  ${BOLD}[ Reverse Proxy 経由 (ホスト:10800) ]${RESET}"
check_host_redirect "[1][2][3] Frontend 未認証"      "http://localhost:10800/" "/oauth2/start"
check_host_redirect "[1][2][4] Backend Swagger 未認証" "http://localhost:10800/api/docs" "/oauth2/start"
check_host_redirect "[1][2][8][7] OAuth2 ログイン開始" "http://localhost:10800/oauth2/start?rd=http://localhost:10800/" "/auth/realms/env-keycloaked/protocol/openid-connect/auth"
check_host_redirect "[1][2][7] Keycloak トップ"       "http://localhost:10800/auth/" "/auth/"

# ── 直アクセス遮断確認 ─────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}━━━ 直アクセス遮断確認 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "    Reverse Proxyを通らず各サービスのホストポートへ到達できないことを確認します"
echo ""

check_host_blocked "[9] Frontend   :15173"       "http://localhost:15173/"
check_host_blocked "[10] Backend    :18000/docs"  "http://localhost:18000/docs"
check_host_blocked "[11] Keycloak   :18080"       "http://localhost:18080/auth/"

echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
