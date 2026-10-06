#!/bin/bash
# 把仓库里的 OWNER 占位符替换成你的 GitHub 用户名/组织名
# 用法: ./scripts/set_repo_owner.sh <owner> [repo]
set -euo pipefail
cd "$(dirname "$0")/.."

OWNER="${1:?用法: ./scripts/set_repo_owner.sh <owner> [repo]}"
REPO="${2:-CutPlayer}"

# 只替换这几种已知形态，避免误伤正文里的 "OWNER" 说明文字
FILES=(README.md CHANGELOG.md .github/ISSUE_TEMPLATE/config.yml docs/RELEASE.md)

for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  /usr/bin/sed -i '' -e "s|github\.com/OWNER/CutPlayer|github.com/${OWNER}/${REPO}|g" \
                    -e "s|github\.com/<OWNER>/CutPlayer|github.com/${OWNER}/${REPO}|g" "$f"
  echo "  已更新 $f"
done

# README 顶部那行提醒替换完成后即可删除
/usr/bin/sed -i '' -e '/发布前：把上面 CI 徽章与文末链接里的 OWNER 换成你的 GitHub 用户名/d' README.md

echo "✔ 完成。仍含 OWNER 的位置（应只剩说明文字）："
grep -rn "OWNER" README.md CHANGELOG.md docs/RELEASE.md .github/ISSUE_TEMPLATE/config.yml || echo "  （无）"
