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
DEFAULT_ROOT_DIR=""

# ==============================================================================
# 輔助函式：自外部檔案讀取非空白且非註解的項目（相容所有 Bash/zsh 版本）
# ==============================================================================
read_valid_lines() {
    local file_path="$1"

    if [ -f "$file_path" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            # 去除前後空白
            line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
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
sync_single_repo() {
    local target_path="$1"

    if [ ! -d "$target_path" ]; then
        echo "❌ [錯誤] 目錄不存在: $target_path"
        return 1
    fi

    if [ ! -d "$target_path/.git" ]; then
        echo "⚠️  [跳過] 目錄不是有效的 Git 儲存庫: $target_path"
        return 0
    fi

    echo "--> [PULL] 更新專案: $target_path..."
    git -C "$target_path" pull --ff-only || {
        echo "⚠️  [警告] $target_path pull 失敗（可能存在分支分歧或未提交改動），略過。"
    }
}

# ==============================================================================
# 模式 A：指定專案同步（檢查 CLI 參數或 REPOS_FILE）
# ==============================================================================
TARGET_REPOS=()

# 優先讀取指令列參數
if [ "$#" -gt 0 ]; then
    TARGET_REPOS=("$@")
elif [ -f "$REPOS_FILE" ]; then
    while IFS= read -r repo_item; do
        [ -n "$repo_item" ] && TARGET_REPOS+=("$repo_item")
    done < <(read_valid_lines "$REPOS_FILE")
fi

# 若有指定專案（無論來自參數或檔案），直接執行單一專案同步並結束
if [ ${#TARGET_REPOS[@]} -gt 0 ]; then
    echo "=================================================="
    echo "檢測到指定專案清單，僅針對指定資料夾進行同步"
    echo "=================================================="

    for repo_arg in "${TARGET_REPOS[@]}"; do
        repo_clean="${repo_arg%/}"
        sync_single_repo "$repo_clean"
    done

    echo "=================================================="
    echo "指定專案同步完成！"
    exit 0
fi

# ==============================================================================
# 模式 B：組織批量同步（從 ORGS_FILE 或 GitHub API 取得）
# ==============================================================================
TARGET_DIR="$DEFAULT_ROOT_DIR"
mkdir -p "$TARGET_DIR"

ORGS=()

if [ -f "$ORGS_FILE" ]; then
    while IFS= read -r org_item; do
        [ -n "$org_item" ] && ORGS+=("$org_item")
    done < <(read_valid_lines "$ORGS_FILE")
fi

if [ ${#ORGS[@]} -eq 0 ]; then
    echo "==> 未指定專案且 $ORGS_FILE 為空或不存在，自動獲取所屬的所有 GitHub 組織..."
    while IFS= read -r org_line; do
        [ -n "$org_line" ] && ORGS+=("$org_line")
    done < <(gh api user/orgs --paginate -q '.[].login' 2>/dev/null || true)
else
    echo "==> 自 $ORGS_FILE 載入指定組織清單..."
fi

if [ ${#ORGS[@]} -eq 0 ]; then
    echo "未找到任何組織或權限不足。"
    exit 0
fi

for ORG in "${ORGS[@]}"; do
    [ -z "$ORG" ] && continue

    echo "=================================================="
    echo "正在處理組織: $ORG"
    echo "=================================================="

    ORG_DIR="$TARGET_DIR/$ORG"
    mkdir -p "$ORG_DIR"

    REPOS=$(gh repo list "$ORG" --limit 1000 --json name,sshUrl,isArchived \
        --jq '.[] | select(.isArchived == false) | "\(.name) \(.sshUrl)"' 2>/dev/null || true)

    if [ -z "$REPOS" ]; then
        echo "[$ORG] 沒有活躍的儲存庫或無權限存取。"
        continue
    fi

    while IFS=' ' read -r REPO_NAME REPO_URL; do
        [ -z "$REPO_NAME" ] && continue
        REPO_PATH="$ORG_DIR/$REPO_NAME"

        if [ -d "$REPO_PATH/.git" ]; then
            sync_single_repo "$REPO_PATH"
        else
            echo "--> [CLONE] 下載 $ORG/$REPO_NAME..."
            git clone "$REPO_URL" "$REPO_PATH"
        fi
    done <<< "$REPOS"
done

echo "=================================================="
echo "所有組織儲存庫同步完成！目錄位於: $TARGET_DIR"