#!/usr/bin/env bash
# ==============================================================================
# GitHub Repositories 同步工具 (支援 Bash 與 macOS zsh)
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
# 【使用方式】
#   1. 給予執行權限：
#      chmod +x sync_repos.sh
#
#   2. 模式 A：指定同步一個或多個專案資料夾
#      ./sync_repos.sh ./org_repos/MyOrg/pos
#      ./sync_repos.sh ./org_repos/MyOrg/pos ./org_repos/MyOrg/scm-api
#      ./sync_repos.sh ./org_repos/MyOrg/scm-*
#
#   3. 模式 B：全自動同步（不帶參數）
#      ./sync_repos.sh
#      - 若下方 TARGET_ORGS 有指定，則只同步指定的組織。
#      - 若下方 TARGET_ORGS 為空，則自動抓取當前帳號所屬的全部組織。
#
# ==============================================================================

set -eu

# ==============================================================================
# 設定區
# ==============================================================================
# 若無傳入特定專案參數時生效：
# 可在此指定組織名稱，例如：TARGET_ORGS=("org-a" "org-b")
# 若為空 TARGET_ORGS=()，則自動抓取所屬全部組織
TARGET_ORGS=()

# 組織同步時的預設存放根目錄
DEFAULT_ROOT_DIR="./org_repos"

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
# 模式 A：給定一個或多個專案資料夾路徑
# ==============================================================================
if [ "$#" -gt 0 ]; then
    echo "=================================================="
    echo "檢測到指定專案參數，僅針對指定資料夾進行同步"
    echo "=================================================="

    for repo_arg in "$@"; do
        # 移除路徑尾端多餘的斜線
        repo_clean="${repo_arg%/}"
        sync_single_repo "$repo_clean"
    done

    echo "=================================================="
    echo "指定專案同步完成！"
    exit 0
fi

# ==============================================================================
# 模式 B：未傳入專案參數，執行組織批量同步
# ==============================================================================
TARGET_DIR="$DEFAULT_ROOT_DIR"
mkdir -p "$TARGET_DIR"

ORGS=()

if [ ${#TARGET_ORGS[@]} -eq 0 ]; then
    echo "==> 未指定專案與 TARGET_ORGS，正在自動獲取所屬的所有 GitHub 組織..."
    while IFS= read -r org_line; do
        [ -n "$org_line" ] && ORGS+=("$org_line")
    done < <(gh api user/orgs --paginate -q '.[].login' 2>/dev/null || true)
else
    echo "==> 使用自訂組織陣列清單..."
    ORGS=("${TARGET_ORGS[@]}")
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
