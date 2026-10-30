#!/usr/bin/env bash

# ============================================================================
# Cloudflare Quick Tunnel 啟動腳本（macOS / bash）
#
# 用途：
#   將本機 HTTP 服務暫時公開至 Cloudflare 提供的 HTTPS 網址，
#   方便進行 Demo、跨裝置測試或分享給測試人員。
#
# 用法：
#   ./cloudflared-quick.sh 30081
#   ./cloudflared-quick.sh http://localhost:30081
#   ./cloudflared-quick.sh http://127.0.0.1:8080
#
# 前置條件：
#   1. 已安裝 cloudflared，且可直接從 Terminal 執行。
#   2. 本機服務已啟動，並能透過指定的 Port 或 URL 存取。
#   3. 下方 CONFIG 指向的設定檔已存在（建議使用獨立的空設定檔，
#      避免與既有 Named Tunnel 的 ingress 設定衝突）。
#
# 停止方式：
#   在執行此腳本的 Terminal 按 Ctrl+C。
#
# 注意：
#   Quick Tunnel 會產生臨時的 *.trycloudflare.com 網址；
#   知道網址的人可能可以存取你的服務，不適合直接公開敏感資料。
# ============================================================================

# 指令執行失敗時立即結束，避免在前置條件不足時繼續啟動。
set -e

# ---------------------------------------------------------------------------
# 1. 讀取使用者輸入
# ---------------------------------------------------------------------------
# $1 是第一個命令列參數：可為單純的 Port（如 30081）或完整 URL。
# 若沒有傳入參數，顯示使用方法並以非零狀態碼結束。
if [[ -z "$1" ]]; then
  echo "Usage: $0 <port|service-url>"
  echo "Examples:"
  echo "  $0 30081"
  echo "  $0 http://localhost:30081"
  exit 1
fi

# 保存本機服務位置，後續會傳給 cloudflared 的 --url 參數。
SERVICE="$1"

# ---------------------------------------------------------------------------
# 2. 指定 Cloudflare Quick Tunnel 專用設定檔
# ---------------------------------------------------------------------------
# $HOME 代表目前使用者的家目錄，例如 /Users/<username>。 like: $HOME/hdd-d/tmp/cloudflared-quick.yml
# 注意：這個檔案是在執行腳本的電腦上，不是 Cloudflare 雲端設定。
CONFIG=""

# ---------------------------------------------------------------------------
# 3. 將純數字 Port 轉換為本機 HTTP URL
# ---------------------------------------------------------------------------
# 以 bash 正規表示式比對純數字；例如 30081 符合，但 http://... 不符合。
# 因此：
#   30081                       -> http://localhost:30081
#   http://localhost:30081      -> 保持原樣
#   http://127.0.0.1:8080       -> 保持原樣
if [[ "$SERVICE" =~ ^[0-9]+$ ]]; then
  SERVICE="http://localhost:$SERVICE"
fi

# ---------------------------------------------------------------------------
# 4. 檢查設定檔是否存在
# ---------------------------------------------------------------------------
# 不直接改用系統預設的 ~/.cloudflared/config.yml，避免誤用其他 Tunnel
# 的路由規則。若不存在，先建立獨立設定檔：
#   mkdir -p "$HOME/hdd-d/tmp"
#   printf '{}\n' > "$HOME/hdd-d/tmp/cloudflared-quick.yml"
if [[ ! -f "$CONFIG" ]]; then
  echo "Error: Config file not found: $CONFIG" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. 顯示執行資訊，並啟動 Quick Tunnel
# ---------------------------------------------------------------------------
# cloudflared 會建立連線並在 Terminal 印出臨時的 HTTPS 公開網址。
# --config : 指定獨立設定檔，避免使用既有的 Named Tunnel 設定。
# --url    : 指定要公開的本機 HTTP 服務。
# 此指令會持續執行；關閉 Terminal 或按 Ctrl+C 即會結束 Tunnel。
echo "Starting Cloudflare Quick Tunnel"
echo "Local Service: $SERVICE"
echo "Config File: $CONFIG"

cloudflared \
  --config "$CONFIG" \
  tunnel \
  --url "$SERVICE"