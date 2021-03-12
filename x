#!/usr/bin/env bash
set -euo pipefail

t="${personal_github_token:?}"
u="${github_user:-Erfandarzi}"
mf="${max_follows_per_run:-200}"
mp="${max_pages_per_target:-8}"
mu="${max_unfollows_per_run:-200}"
d="${action_delay:-1}"
sf="${state_file:-./.seen.dat}"
cf="${counter_file:-./.cnt}"
kf="${cursor_file:-./.cursor.dat}"
tg="${target_accounts:-torvalds,karpathy,gustavoguanabara,yyx990803,gaearon,ruanyf,sindresorhus,bradtraversy,JakeWharton,lucidrains}"
rmx="${ratio_max:-100}"
rmn="${ratio_min:-0.001}"
rkn="${ratio_knee:-500}"
rpw="${ratio_power:-1.5}"
ghcap="${github_following_cap:-10000}"
endf="${target_end_following:-50}"

hdr=(-H "Authorization: Bearer ${t}" -H "User-Agent: sync/1.0")
w() { sleep "$d"; }

json() { jq -r "$1" 2>/dev/null || echo ""; }

gp() {
  curl -fsS "${hdr[@]}" "https://api.github.com/users/${u}" | jq '{followers,following}'
}

pg() {
  local ep="$1" pg="$2"
  curl -fsS "${hdr[@]}" "https://api.github.com/${ep}?per_page=100&page=${pg}" \
    | jq -r '.[].login' 2>/dev/null
}

fol() {
  local n=1 o="" x
  while :; do
    x="$(pg "users/${u}/following" "$n" || true)"
    [[ -z "$x" ]] && break
    o+="$x"$'\n'
    n=$((n+1))
    [[ "$n" -gt 100 ]] && break
    w
  done
  printf '%s' "$o"
}

flw() {
  local n=1 o="" x
  while :; do
    x="$(pg "users/${u}/followers" "$n" || true)"
    [[ -z "$x" ]] && break
    o+="$x"$'\n'
    n=$((n+1))
    [[ "$n" -gt 100 ]] && break
    w
  done
  printf '%s' "$o"
}

cur() {
  [[ -f "$kf" ]] || { echo "{}"; return; }
  cat "$kf"
}

putcur() {
  local a="$1" v="$2"
  cur | jq --arg k "$a" --argjson v "$v" '.[$k]=$v' > "${kf}.tmp" && mv "${kf}.tmp" "$kf"
}

seen() { [[ -f "$sf" ]] && grep -Fxq "$1" "$sf"; }

unseen() {
  [[ -f "$sf" ]] || return 0
  grep -Fxv "$1" "$sf" > "${sf}.tmp" 2>/dev/null || true
  mv "${sf}.tmp" "$sf"
}

cap_for() {
  local fc="$1"
  awk -v fc="$fc" -v maxr="$rmx" -v minr="$rmn" -v knee="$rkn" -v pow="$rpw" \
      -v ghcap="$ghcap" -v endf="$endf" 'BEGIN {
    if (fc <= 0) fc = 1
    ratio = minr + (maxr - minr) / (1 + (fc / knee) ^ pow)
    cap = fc * ratio
    tail = endf + (ghcap - endf) / (1 + (fc / (knee * 4)) ^ (pow * 1.2))
    if (tail < cap) cap = tail
    if (cap > ghcap) cap = ghcap
    if (cap < endf) cap = endf
    printf "%.4f %.0f", ratio, cap
  }'
}

prune() {
  local lim="$1" n=0 a b
  a="$(mktemp)" b="$(mktemp)"
  fol | sort -u > "$a"
  flw | sort -u > "$b"
  mapfile -t order < <(awk 'BEGIN{srand();} {print rand()"\t"$0}' "$a" | sort -n | cut -f2-)
  for x in "${order[@]}"; do
    [[ "$n" -ge "$lim" || -z "$x" ]] && break
    grep -Fxq "$x" "$b" && continue
    code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "${hdr[@]}" \
      "https://api.github.com/user/following/${x}")"
    if [[ "$code" == "204" ]]; then
      n=$((n+1))
      unseen "$x"
    elif [[ "$code" == "403" || "$code" == "429" ]]; then
      break
    fi
    w
  done
  rm -f "$a" "$b"
  echo "$n"
}

add() {
  local lim="$1" n=0 code x
  IFS=',' read -ra ts <<< "$tg"
  local off=$(( $(date +%s) / 3600 % ${#ts[@]} ))
  touch "$sf"
  for ((i=0; i<${#ts[@]}; i++)); do
    ac="${ts[$(( (i + off) % ${#ts[@]} ))]}"
    [[ "$n" -ge "$lim" ]] && break
    local p="$(cur | jq -r --arg k "$ac" '.[$k] // 1')"
    local c=0
    while [[ "$n" -lt "$lim" && "$c" -lt "$mp" ]]; do
      local ls
      ls="$(pg "users/${ac}/followers" "$p" || true)"
      [[ -z "$ls" ]] && { putcur "$ac" 1; break; }
      while IFS= read -r x; do
        [[ -z "$x" || "$n" -ge "$lim" ]] && continue
        seen "$x" && continue
        code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT "${hdr[@]}" \
          "https://api.github.com/user/following/${x}")"
        if [[ "$code" == "204" ]]; then
          echo "$x" >> "$sf"
          n=$((n+1))
        elif [[ "$code" == "403" || "$code" == "429" ]]; then
          putcur "$ac" "$((p+1))"
          echo "$n"
          return
        fi
        w
      done <<< "$ls"
      p=$((p+1))
      c=$((c+1))
      putcur "$ac" "$p"
      w
    done
  done
  echo "$n"
}

st="$(gp)"
fc="$(json .followers <<< "$st")"
fg="$(json .following <<< "$st")"
read -r dr cap < <(cap_for "$fc")
room=$((cap - fg))

pu=0
ad=0

if [[ "$room" -le 0 ]]; then
  pu="$(prune "$mu")"
else
  lim="$mf"
  [[ "$room" -lt "$lim" ]] && lim="$room"
  ad="$(add "$lim")"
  rem=$((mu - pu))
  [[ "$rem" -gt 0 ]] && pu=$((pu + $(prune "$rem")))
fi

echo "$ad" > "$cf"
echo "a=${ad} p=${pu} f=${fc} g=${fg} r=${dr} c=${cap}"
