#!/bin/bash
set -euo pipefail
if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo 'usage: replay-translation.sh input.mp3 output.jsonl [text|audio] [preset|once|always]' >&2
  exit 2
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
replay_tmp="$(mktemp -d "${TMPDIR:-/tmp}/livetranslate-replay.XXXXXX")"
trap 'rm -rf "$replay_tmp"' EXIT
ffmpeg -nostdin -v error -i "$1" -f s16le -ar 16000 -ac 1 "$replay_tmp/input.pcm"
swiftc -module-cache-path "$replay_tmp/cache" -D DEBUG -parse-as-library \
  "$repo_dir/scripts/replay-translation.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/TranslationClient.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/ServerItemLinks.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/CredentialStore.swift" \
  "$repo_dir/LiveTranslateBridge/CallAudioKit/BridgeLog.swift" \
  -o "$replay_tmp/replay"
"$replay_tmp/replay" "$replay_tmp/input.pcm" "$2" "${3:-audio}" "${4:-preset}"
