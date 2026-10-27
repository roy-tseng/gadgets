#!/usr/bin/env bash
# ==============================================================================
# GitHub Repositories 同步工具 (支援 Bash 3.2+、Bash 4+ 與 macOS zsh)
# ==============================================================================
#
# 【前置需求】
#   1. 安裝 GitHub CLI (gh) 並完成登入：
#      - macOS (Homebrew):
#          brew install gh
#      - Ubuntu / Debian / WSL:
#          sudo apt update && sudo apt install gh
#      - Windows (PowerShell / winget):
#          winget install --id GitHub.cli
#      - 登入授權（需具備 repo 與 read:org 權限）：
#          gh auth login
#
#   2. 安裝 jq (JSON 解析工具)：
#      - macOS: brew install jq
#      - Ubuntu / Debian / WSL: sudo apt install jq
#
# 【外部設定檔格式說明】
#   每行填入一個項目，支援以 # 開頭的註解行與空白行。
#   - 專案清單檔 (預設 repos.txt)：填寫本地專案目錄路徑
#       例如：
#       ./org_repos/MyOrg/pos
#       ./org_repos/MyOrg/scm-api
#   - 組織清單檔 (預設 orgs.txt)：填寫 GitHub Organization 名稱
#       例如：
#       company-backend
#       company-frontend
#
# 【使用方式】
#   1. 給予執行權限：
#      chmod +x synpjs.sh
#
#   2. 模式 A：指定專案同步（優先級高於組織同步）
#      - 直接由 CLI 參數指定資料夾：
#          ./synpjs.sh ./org_repos/MyOrg/pos ./org_repos/MyOrg/scm-*
#      - 或是建立 repos.txt，執行腳本時若有清單內容將自動讀取同步：
#          ./synpjs.sh
#
#   3. 模式 B：組織批量同步（無指定專案時觸發）
#      - 若 orgs.txt 存在且有內容，則同步檔案內指定的組織。
#      - 若 orgs.txt 不存在或為空，則自動透過 GitHub API 抓取帳號所屬的全部組織。
#          ./synpjs.sh
#
# ==============================================================================

set -eu

# ==============================================================================
# 外部文字檔路徑設定
# ==============================================================================
# 指定專案清單檔案路徑（一行一個專案路徑）
REPOS_FILE="repos.txt"

# 指定組織清單檔案路徑（一行一個組織名稱）
ORGS_FILE="orgs.txt"

# 組織同步時的預設存放根目錄
DEFAULT_ROOT_DIR="./org_repos"

# ==============================================================================
# 輔助函式：自外部檔案讀取非空白且非註解的項目（相容所有 Bash/zsh 版本）
# ==============================================================================
read_valid_lines() {
    local file_path="$1"

    if [ -f "$file_path" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            # 去除前後空白
            line=$(echo "$line" \vert{} sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            # 略過空白行與 # 開頭的註解
            if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
                echo "$line"
            fi
        done < "$file_path"
    fi
}

# ==============================================================================
# 輔助函式：同步單一專案 (Pull)
# ==============================================================================