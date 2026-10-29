#!/usr/bin/env bash
# 按 images.yaml 把镜像同步到 ACR：
#   - 只同步指定平台（默认 linux/amd64）
#   - 目标中各平台 manifest digest 与上游一致则跳过
#   - tag 可任意填写（含 latest、1.26-alpine 等浮动 tag），上游不存在时给出提示
# 依赖：skopeo、yq (mikefarah v4)、jq、docker buildx（多平台时）
# 认证：沿用 docker login 写入的 ~/.docker/config.json
set -uo pipefail

CONFIG="${CONFIG:-images.yaml}"
: "${ACR_REGISTRY:?ACR_REGISTRY 未设置}"
: "${ACR_NAMESPACE:?ACR_NAMESPACE 未设置}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
ERRF="$(mktemp)"; trap 'rm -f "$ERRF"' EXIT

n_ok=0; n_skip=0; n_fail=0

err() { echo "::error::$*" >&2; }

# 规则 B：docker.io 省略主机名；其他注册表主机名中的 . 换成 -；路径中的 / 换成 _
target_name() {
  local src="$1" host="${1%%/*}" path="${1#*/}"
  if [[ "$host" == "docker.io" ]]; then
    printf '%s\n' "${path//\//_}"
  else
    printf '%s_%s\n' "${host//./-}" "${path//\//_}"
  fi | tr '[:upper:]' '[:lower:]'
}

# 上游 tag 不存在时调用：区分仓库不存在和 tag 不存在，并列出相近的 tag 供参考
report_missing() {
  local src="$1" tag="$2" tags variant hint
  if ! tags="$(skopeo list-tags --retry-times 3 "docker://$src" 2>/dev/null | jq -r '.Tags[]')"; then
    err "$src: 上游仓库不存在或无权访问，请检查 source"
    return
  fi
  # 1.26-alpine -> 只在含 -alpine 的 tag 中找；纯版本号则在全部 tag 中找
  variant=""
  [[ "$tag" == *-* ]] && variant="-${tag#*-}"
  hint="$(grep -F -- "$variant" <<<"$tags" | sort -V | tail -n 10 | paste -sd ' ')"
  err "$src:$tag 未找到，上游不存在该 tag${hint:+。相近的 tag：$hint}"
}

# 输出上游中所选平台的 manifest digest（排序去重），失败返回非 0
src_digests() {
  local src="$1" tag="$2" plats="$3" ref="$1:$2" raw single p os arch variant d errmsg
  if ! raw="$(skopeo inspect --raw --retry-times 3 "docker://$ref" 2>"$ERRF")"; then
    errmsg="$(<"$ERRF")"
    if grep -qiE 'manifest unknown|not found|404' <<<"$errmsg"; then
      report_missing "$src" "$tag"
    else
      err "$ref: 读取上游 manifest 失败：$errmsg"
    fi
    return 1
  fi

  if jq -e 'has("manifests")' >/dev/null <<<"$raw"; then
    for p in ${plats//,/ }; do
      IFS=/ read -r os arch variant <<<"$p"
      d="$(jq -r --arg os "$os" --arg arch "$arch" --arg v "${variant:-}" '
            [.manifests[]
              | select(.platform.os == $os and .platform.architecture == $arch)
              | select($v == "" or .platform.variant == $v)]
            | first | .digest // empty' <<<"$raw")"
      [[ -n "$d" ]] || { err "$ref: 上游没有 $p 平台"; return 1; }
      echo "$d"
    done | sort -u
  else
    # 上游本身是单架构镜像
    single="$(skopeo inspect --config --raw --retry-times 3 "docker://$ref" | jq -r '.os + "/" + .architecture')" \
      || { err "$ref: 读取 config 失败"; return 1; }
    [[ "$plats" == "$single" ]] \
      || { err "$ref: 上游是单架构镜像（$single），与要求的 $plats 不符"; return 1; }
    skopeo inspect --format '{{.Digest}}' --retry-times 3 "docker://$ref"
  fi
}

# 输出目标中已有的平台 manifest digest（排序），不存在则输出空
dst_digests() {
  local ref="$1" raw
  raw="$(skopeo inspect --raw "docker://$ref" 2>/dev/null)" || return 0
  if jq -e 'has("manifests")' >/dev/null <<<"$raw"; then
    jq -r '.manifests[].digest' <<<"$raw" | sort -u
  else
    skopeo inspect --format '{{.Digest}}' "docker://$ref" 2>/dev/null
  fi
}

# 返回值：0 已同步，2 跳过，其他 失败
sync_one() {
  local src="$1" tag="$2" plats="$3" target="$4" name dst want have d
  local -a digests refs

  [[ "${src%%/*}" == *.* ]] \
    || { err "$src: 请写完整路径，如 docker.io/library/nginx"; return 1; }

  name="${target:-$(target_name "$src")}"
  (( ${#name} <= 64 )) \
    || { err "$name 超过 64 个字符，请用 target 字段指定短名"; return 1; }
  dst="$ACR_REGISTRY/$ACR_NAMESPACE/$name:$tag"

  want="$(src_digests "$src" "$tag" "$plats")" || return 1
  have="$(dst_digests "$dst")"
  if [[ -n "$have" && "$have" == "$want" ]]; then
    echo "skip: $dst（digest 未变化）"
    return 2
  fi

  mapfile -t digests <<<"$want"
  if (( ${#digests[@]} == 1 )); then
    # 单平台：直接按 digest 复制，目标 digest 与上游完全一致
    skopeo copy --retry-times 3 --preserve-digests \
      "docker://$src@${digests[0]}" "docker://$dst" || return 1
  else
    # 多平台：用所选平台的 manifest 组装一个新的 index
    refs=()
    for d in "${digests[@]}"; do refs+=("$src@$d"); done
    docker buildx imagetools create -t "$dst" "${refs[@]}" || return 1
  fi

  [[ "$(dst_digests "$dst")" == "$want" ]] \
    || { err "$dst: 推送后校验 digest 不一致"; return 1; }
  echo "synced: $dst"
}

{
  echo "| 镜像 | 平台 | 结果 |"
  echo "|---|---|---|"
} >> "$SUMMARY"

while IFS='|' read -r -u 3 src tag plats target; do
  echo "::group::$src:$tag -> [$plats]"
  sync_one "$src" "$tag" "$plats" "$target"; rc=$?
  echo "::endgroup::"
  case $rc in
    0) n_ok=$((n_ok + 1));     r="已同步" ;;
    2) n_skip=$((n_skip + 1)); r="跳过" ;;
    *) n_fail=$((n_fail + 1)); r="**失败**" ;;
  esac
  echo "| \`$src:$tag\` | $plats | $r |" >> "$SUMMARY"
done 3< <(
  yq -o=json '.' "$CONFIG" | jq -r '
    (.defaults.platforms // ["linux/amd64"]) as $dp
    | .images[] | . as $img | .tags[]
    | [ $img.source,
        .,
        (($img.platforms // $dp) | join(",")),
        ($img.target // "") ]
    | join("|")'
)

echo "同步 $n_ok，跳过 $n_skip，失败 $n_fail" | tee -a "$SUMMARY"
(( n_fail == 0 ))
