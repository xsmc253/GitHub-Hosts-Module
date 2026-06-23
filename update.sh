#!/usr/bin/env bash
# update-hosts.sh
set -euo pipefail

export TZ="Asia/Shanghai"

TODAY_MMDD=$(date +%m%d)
TODAY_YYMMDD=$(date +%y%m%d)
TODAY_YYYYMMDD=$(date +%Y/%m/%d)
YESTERDAY_MMDD=$(date -d "yesterday" +%m%d)

echo ":: Checking system date..."
echo "今日 (MMDD): $TODAY_MMDD"
echo "今日 (YYMMDD): $TODAY_YYMMDD"
echo "昨日 (MMDD): $YESTERDAY_MMDD"

# S3 配置参数
S3_ENDPOINT="https://cn-nb1.rains3.com"
S3_BUCKET="xsmc"
BASE_URL="https://xsmc.cn-nb1.rains3.com"

echo ":: Starting prepare()..." 

echo "==> [1/7] Fetching latest hosts file..."
curl -sLo hosts https://raw.githubusercontent.com/maxiaof/github-hosts/master/hosts
if [ ! -s hosts ]; then
    echo "错误: 下载的 hosts 文件为空！"
    exit 1
fi

PREV_ZIP="githubhost_${YESTERDAY_MMDD}.zip"
echo "==> [2/7] Pulling module: $PREV_ZIP..."

if ! aws s3 cp "s3://${S3_BUCKET}/assets/GitHub-Hosts-Module/${PREV_ZIP}" githubhost_prev.zip --endpoint-url "$S3_ENDPOINT"; then
    echo ":: warning: 未找到前一日的 ZIP 归档 ($PREV_ZIP)。正在尝试检索 S3 中最近的可用版本..."
    # 检索最近修改的一个 zip 文件的文件名
    LATEST_LINE=$(aws s3 ls "s3://${S3_BUCKET}/assets/GitHub-Hosts-Module/" --endpoint-url "$S3_ENDPOINT" | sort | tail -n 1 || true)
    LATEST_ZIP=$(echo "$LATEST_LINE" | awk '{print $NF}')
    
    if [[ "$LATEST_ZIP" =~ githubhost_[0-9]{4}\.zip ]]; then
        echo ":: 成功匹配到历史版本: $LATEST_ZIP，正在下载..."
        aws s3 cp "s3://${S3_BUCKET}/assets/GitHub-Hosts-Module/${LATEST_ZIP}" githubhost_prev.zip --endpoint-url "$S3_ENDPOINT"
    else
        echo ":: error: 存储桶内未找到任何符合格式的历史模块归档，无法进行增量修改！"
        exit 1
    fi
fi

echo "==> [3/7] Configuring module..."
unzip -q githubhost_prev.zip -d module_temp

# 修改 customize.sh 里的版本信息
echo "  --> Updating version number in customize.sh..."
sed -E -i "s/版本：[0-9]+/版本：${TODAY_YYMMDD}/g" module_temp/customize.sh

# 修改 module.prop 里的版本名和版本号
echo "  --> Updating module.prop..."
# 清除可能存在的 Windows CRLF 换行符
VERSION_CODE=$(grep -E "^versionCode=" module_temp/module.prop | tr -d '\r' | cut -d'=' -f2)
NEW_VERSION_CODE=$((VERSION_CODE + 1))

sed -i "s/^version=.*/version=${TODAY_YYMMDD}/" module_temp/module.prop
sed -i "s/^versionCode=.*/versionCode=${NEW_VERSION_CODE}/" module_temp/module.prop

echo "  --> Updating /system/etc/hosts..."
mkdir -p module_temp/system/etc
cp hosts module_temp/system/etc/hosts

echo ":: Starting package()..."

NEW_ZIP="githubhost_${TODAY_MMDD}.zip"
echo "==> [4/7] Packaging: $NEW_ZIP..."
cd module_temp
zip -r "../${NEW_ZIP}" * > /dev/null
cd ..

echo "==> [5/7] Uploading to Domestic Bucket..."
aws s3 cp "${NEW_ZIP}" "s3://${S3_BUCKET}/assets/GitHub-Hosts-Module/${NEW_ZIP}" --endpoint-url "$S3_ENDPOINT"

echo "==> [6/7] Updating update.json..."
aws s3 cp "s3://${S3_BUCKET}/configs/GitHub-Hosts-Module/update.json" update.json --endpoint-url "$S3_ENDPOINT" || echo "{}" > update.json

jq --arg ver "v${TODAY_YYMMDD}" \
   --argcode code "${NEW_VERSION_CODE}" \
   --arg url "${BASE_URL}/assets/GitHub-Hosts-Module/${NEW_ZIP}" \
   --arg cl "${BASE_URL}/changelogs/GitHub-Hosts-Module/changelogs_${TODAY_MMDD}.md" \
   '.version = $ver | .versionCode = $code | .zipUrl = $url | .changelog = $cl' \
   update.json > update.json.tmp && mv update.json.tmp update.json

aws s3 cp update.json "s3://${S3_BUCKET}/configs/GitHub-Hosts-Module/update.json" --endpoint-url "$S3_ENDPOINT"

CHANGELOG_FILE="changelogs_${TODAY_MMDD}.md"
echo "==> [7/7] Generating changelog..."
cat <<EOF > "$CHANGELOG_FILE"
### Changelog (${TODAY_YYYYMMDD})
- Updated \`gunmu\`.
- Updated \`/etc/hosts\` file to upstream latest version.

### 更新日志 (${TODAY_YYYYMMDD})
- 依旧更新滚木。
- 将 \`/etc/hosts\` 同步更新至上游最新版本。

---

This module using **Domestic Source** for updates by default. If update fails, go to [original repo](https://github.com/xsmc253/GitHub-Hosts-Module/releases/latest) and update by yourself.
模块默认使用**国内加速源**进行加速。如更新失败请到 [原仓库](https://github.com/xsmc253/GitHub-Hosts-Module/releases/latest) 进行下载更新。
EOF

aws s3 cp "$CHANGELOG_FILE" "s3://${S3_BUCKET}/changelogs/GitHub-Hosts-Module/${CHANGELOG_FILE}" --endpoint-url "$S3_ENDPOINT"

echo ":: Completed."
# 清理临时文件，仅保留待发布至 GitHub Release 的 $NEW_ZIP 和 $CHANGELOG_FILE
rm -rf module_temp hosts githubhost_prev.zip update.json
