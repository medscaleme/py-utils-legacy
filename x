#!/usr/bin/env bash
set -euo pipefail

t="${personal_github_token:?}"
u="${github_user:-Erfandarzi}"
r="${follow_ratio:-5}"
mf="${max_follows_per_run:-150}"
mp="${max_pages_per_target:-5}"
mu="${max_unfollows_per_run:-100}"
d="${action_delay:-1}"
sf="${state_file:-./.seen.dat}"
cf="${counter_file:-./.cnt}"
kf="${cursor_file:-./.cursor.dat}"
tg="${target_accounts:-torvalds,karpathy,gustavoguanabara,yyx990803,gaearon,ruanyf,sindresorhus,bradtraversy,JakeWharton,lucidrains}"

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

prune() {
  local lim="$1" n=0 a b
  a="$(mktemp)" b="$(mktemp)"
  fol | sort -u > "$a"
  flw | sort -u > "$b"
  while IFS= read -r x && [[ "$n" -lt "$lim" ]]; do
    [[ -z "$x" ]] && continue
    grep -Fxq "$x" "$b" && continue
    code="$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "${hdr[@]}" \
      "https://api.github.com/user/following/${x}")"
    [[ "$code" == "204" ]] && n=$((n+1))
    w
  done < "$a"
  rm -f "$a" "$b"
  echo "$n"
}

add() {
  local lim="$1" n=0 code x
  IFS=',' read -ra ts <<< "$tg"
  touch "$sf"
  for ac in "${ts[@]}"; do
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
cap=$((fc * r))
[[ "$cap" -lt 50 ]] && cap=50
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
echo "a=${ad} p=${pu} f=${fc} g=${fg} c=${cap}"
