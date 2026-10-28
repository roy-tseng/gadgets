#!/usr/bin/env bash
# ==============================================================================
# GitHub Repositories 同步工具 (支援併行加速、Bash 3.2+、Bash 4+ 與 macOS zsh)
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
#      chmod +x synpjs.sh
#
#   2. 模式 A：指定專案同步（支援併行）
#      ./synpjs.sh ./org_repos/MyOrg/pos ./org_repos/MyOrg/scm-*
#      或是由 repos.txt 自動載入路徑後併行同步。
#
#   3. 模式 B：組織批量同步（支援併行）
#      ./synpjs.sh
#
# ==============================================================================

set -eu

# ==============================================================================
# 設定區
# ==============================================================================
MAX_JOBS=6
REPOS_FILE="repos.txt"
ORGS_FILE="orgs.txt"
DEFAULT_ROOT_DIR="${DEFAULT_ROOT_DIR:-./org_repos}"

# 用於跨子行程彙整 Summary 的臨時檔
SUMMARY_LOG=$(mktemp /tmp/synpjs_summary.XXXXXX)
trap 'rm -f "$SUMMARY_LOG"' EXIT

# ==============================================================================
# 輔助函式：併行工作節流控制器
# ==============================================================================
wait_for_job_slot() {
    while [ "$(jobs -p | wc -l)" -ge "$MAX_JOBS" ]; do
        sleep 0.2
    done
}

# ==============================================================================
# 輔助函式：自外部檔案讀取非空白且非註解的項目
# ==============================================================================
read_valid_lines() {
    local file_path="$1"

    if [ -f "$file_path" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
                echo "$line"
            fi
        done < "$file_path"
    fi
}

# ==============================================================================
# 輔助函式：取得目錄的完整絕對路徑 (Full Path)
# ==============================================================================
get_full_path() {
    local target_dir="$1"
    if [ -d "$target_dir" ]; then
        (cd "$target_dir" && pwd -P)
    else
        echo "$target_dir"
    fi
}

# ==============================================================================
# 輔助函式：記錄結果至 Summary 檔案
# ==============================================================================
record_summary() {
    local org="$1"
    local repo="$2"
    local path="$3"

    local branch="-"
    local full_path
    full_path=$(get_full_path "$path")

    if [ -d "$path/.git" ]; then
        branch=$(git -C "$path" branch --show-current 2>/dev/null || echo "DETACHED")
        [ -z "$branch" ] && branch="DETACHED"
    fi

    # 寫入格式：Org|Repo|Branch|FullPath
    echo "${org}|${repo}|${branch}|${full_path}" >> "$SUMMARY_LOG"
}

# ==============================================================================
# 輔助函式：同步單一專案 (Pull)
# ==============================================================================
sync_single_repo() {
    local target_path="$1"
    local org="-"
    local repo_name

    repo_name=$(basename "$target_path")

    if [ ! -d "$target_path" ]; then
        echo "❌ [錯誤] 目錄不存在: $target_path"
        return 1
    fi

    if [ ! -d "$target_path/.git" ]; then
        echo "⚠️  [跳過] 目錄不是有效的 Git 儲存庫: $target_path"
        return 0
    fi

    # 嘗試從 Git remote URL 解析組織名稱
    local remote_url
    remote_url=$(git -C "$target_path" remote get-url origin 2>/dev/null || true)
    if [[ "$remote_url" =~ [:|/]([^/]+)/[^/]+(\.git)?$ ]]; then
        org="${BASH_REMATCH[1]}"
    fi

    echo "--> [PULL] 更新專案: $target_path..."
    if ! git -C "$target_path" pull --ff-only >/dev/null 2>&1; then
        echo "⚠️  [警告] $target_path pull 失敗（可能存在分支分歧或未提交改動），略過。"
    else
        echo "✅ [完成] $target_path 更新完畢。"
    fi

    record_summary "$org" "$repo_name" "$target_path"
}

# ==============================================================================
# 輔助函式：處理單一儲存庫 Clone 或 Pull
# ==============================================================================
process_repo() {
    local org_name="$1"
    local repo_name="$2"
    local repo_url="$3"
    local repo_path="$4"

    if [ -d "$repo_path/.git" ]; then
        echo "--> [PULL] 更新專案: $org_name/$repo_name..."
        if ! git -C "$repo_path" pull --ff-only >/dev/null 2>&1; then
            echo "⚠️  [警告] $org_name/$repo_name pull 失敗，略過。"
        else
            echo "✅ [完成] $org_name/$repo_name 更新完畢。"
        fi
    else
        echo "--> [CLONE] 下載 $org_name/$repo_name..."
        if git clone "$repo_url" "$repo_path" >/dev/null 2>&1; then
            echo "✅ [完成] $org_name/$repo_name 下載完成。"
        else
            echo "❌ [失敗] $org_name/$repo_name clone 失敗。"
            return 1
        fi
    fi

    record_summary "$org_name" "$repo_name" "$repo_path"
}

# ==============================================================================
# 輔助函式：列印 Summary 表格
# ==============================================================================
print_summary_table() {
    echo ""
    echo "================================================================================================================"
    echo "                                            同步結果總覽 (SUMMARY)                                              "
    echo "================================================================================================================"

    if [ ! -s "$SUMMARY_LOG" ]; then
        echo "沒有可顯示的同步紀錄。"
        return 0
    fi

    # 輸出對齊格式的表格
    awk -F'|' '
    BEGIN {
        printf "%-18s | %-22s | %-16s | %s\n", "組織 (Organization)", "專案名 (Repository)", "分支 (Branch)", "完整路徑 (Full Path)"
        print "----------------------------------------------------------------------------------------------------------------"
    }
    {
        printf "%-18s | %-22s | %-16s | %s\n", $1, $2, $3, $4
    }
    ' "$SUMMARY_LOG"

    echo "================================================================================================================"
}

# ==============================================================================
# 模式 A：指定專案同步（檢查 CLI 參數或 REPOS_FILE）
# ==============================================================================
TARGET_REPOS=()

if [ "$#" -gt 0 ]; then
    TARGET_REPOS=("$@")
elif [ -f "$REPOS_FILE" ]; then
    while IFS= read -r repo_item; do
        [ -n "$repo_item" ] && TARGET_REPOS+=("$repo_item")
    done < <(read_valid_lines "$REPOS_FILE")
fi

if [ ${#TARGET_REPOS[@]} -gt 0 ]; then
    echo "=================================================="
    echo "檢測到指定專案清單，以併行方式 (最大 ${MAX_JOBS} 個) 進行同步"
    echo "=================================================="

    for repo_arg in "${TARGET_REPOS[@]}"; do
        repo_clean="${repo_arg%/}"
        wait_for_job_slot
        ( sync_single_repo "$repo_clean" ) &
    done

    wait
    print_summary_table
    exit 0
fi

# ==============================================================================
# 模式 B：組織批量同步
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
    echo "正在處理組織: $ORG (併行數上限: $MAX_JOBS)"
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

        wait_for_job_slot
        ( process_repo "$ORG" "$REPO_NAME" "$REPO_URL" "$REPO_PATH" ) &
    done <<< "$REPOS"

    wait
done

print_summary_table