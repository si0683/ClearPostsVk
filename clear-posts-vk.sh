#!/usr/bin/env bash

set -Eeuo pipefail

API_VERSION="5.199"
REQUEST_DELAY="0.40"

for command_name in curl jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Ошибка: требуется команда %s.\n' "$command_name" >&2
    exit 1
  fi
done

printf 'Токен должен быть получен приложением VK типа Standalone с правом wall.\n'
read -r -s -p 'Вставьте access token VK: ' VK_TOKEN
printf '\n'
if [[ -z "$VK_TOKEN" ]]; then
  printf 'Ошибка: токен не указан.\n' >&2
  exit 1
fi
trap 'unset VK_TOKEN' EXIT

read -r -p 'Вставьте ссылку на сообщество VK: ' COMMUNITY_URL
if [[ ! "$COMMUNITY_URL" =~ ^(https?://)?(www\.|m\.)?vk\.(ru|com)/ ]]; then
  printf 'Ошибка: нужна ссылка вида https://vk.ru/club123456 или https://vk.ru/name.\n' >&2
  exit 1
fi

SCREEN_NAME="$({ printf '%s' "$COMMUNITY_URL" | sed -E 's|^https?://||; s|^(www\.|m\.)?vk\.(ru|com)/||; s|[/?#].*$||'; })"
if [[ -z "$SCREEN_NAME" ]]; then
  printf 'Ошибка: в ссылке не найден адрес сообщества.\n' >&2
  exit 1
fi

vk_api() {
  local method="$1"
  shift
  curl --silent --show-error --fail-with-body \
    --request POST "https://api.vk.com/method/${method}" \
    --data-urlencode "access_token=${VK_TOKEN}" \
    --data-urlencode "v=${API_VERSION}" \
    "$@"
}

api_error() {
  jq -r '.error.error_msg // empty' <<<"$1"
}

if [[ "$SCREEN_NAME" =~ ^(club|public|event)([0-9]+)$ ]]; then
  GROUP_ID="${BASH_REMATCH[2]}"
else
  RESOLVE_RESPONSE="$(vk_api utils.resolveScreenName --data-urlencode "screen_name=${SCREEN_NAME}")"
  ERROR_TEXT="$(api_error "$RESOLVE_RESPONSE")"
  if [[ -n "$ERROR_TEXT" ]]; then
    printf 'Ошибка VK API: %s\n' "$ERROR_TEXT" >&2
    exit 1
  fi

  OBJECT_TYPE="$(jq -r '.response.type // empty' <<<"$RESOLVE_RESPONSE")"
  GROUP_ID="$(jq -r '.response.object_id // empty' <<<"$RESOLVE_RESPONSE")"
  if [[ ! "$OBJECT_TYPE" =~ ^(group|page|event)$ || -z "$GROUP_ID" ]]; then
    printf 'Ошибка: ссылка ведёт не на сообщество VK.\n' >&2
    exit 1
  fi
fi

OWNER_ID="-${GROUP_ID}"
OFFSET=0
TOTAL=0
POST_IDS=()

printf 'Получаю список записей…\n'
while :; do
  PAGE_RESPONSE="$(vk_api wall.get \
    --data-urlencode "owner_id=${OWNER_ID}" \
    --data-urlencode 'count=100' \
    --data-urlencode "offset=${OFFSET}")"
  ERROR_TEXT="$(api_error "$PAGE_RESPONSE")"
  if [[ -n "$ERROR_TEXT" ]]; then
    printf 'Ошибка VK API: %s\n' "$ERROR_TEXT" >&2
    exit 1
  fi

  if (( OFFSET == 0 )); then
    TOTAL="$(jq -r '.response.count // 0' <<<"$PAGE_RESPONSE")"
  fi
  mapfile -t PAGE_IDS < <(jq -r '.response.items[]?.id' <<<"$PAGE_RESPONSE")
  if (( ${#PAGE_IDS[@]} == 0 )); then
    break
  fi
  POST_IDS+=("${PAGE_IDS[@]}")
  OFFSET=$((OFFSET + ${#PAGE_IDS[@]}))
  if (( OFFSET >= TOTAL )); then
    break
  fi
done

printf 'Сообщество: https://vk.ru/club%s\n' "$GROUP_ID"
printf 'Найдено записей: %d\n' "${#POST_IDS[@]}"
if (( ${#POST_IDS[@]} == 0 )); then
  exit 0
fi

printf 'Удаление необратимо. Для продолжения введите: УДАЛИТЬ %s\n' "$GROUP_ID"
read -r CONFIRMATION
if [[ "$CONFIRMATION" != "УДАЛИТЬ ${GROUP_ID}" ]]; then
  printf 'Отменено. Ничего не удалено.\n'
  exit 0
fi

DELETED=0
for POST_ID in "${POST_IDS[@]}"; do
  DELETE_RESPONSE="$(vk_api wall.delete \
    --data-urlencode "owner_id=${OWNER_ID}" \
    --data-urlencode "post_id=${POST_ID}")"
  ERROR_TEXT="$(api_error "$DELETE_RESPONSE")"
  if [[ -n "$ERROR_TEXT" ]]; then
    printf '\nОстановка после %d из %d записей. Ошибка: %s\n' \
      "$DELETED" "${#POST_IDS[@]}" "$ERROR_TEXT" >&2
    exit 1
  fi
  if [[ "$(jq -r '.response // 0' <<<"$DELETE_RESPONSE")" != "1" ]]; then
    printf '\nОстановка: VK не подтвердил удаление записи %s.\n' "$POST_ID" >&2
    exit 1
  fi
  DELETED=$((DELETED + 1))
  printf '\rУдалено %d из %d…' "$DELETED" "${#POST_IDS[@]}"
  sleep "$REQUEST_DELAY"
done

printf '\nГотово. Удалено записей: %d.\n' "$DELETED"
