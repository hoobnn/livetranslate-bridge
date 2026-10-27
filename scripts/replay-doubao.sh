#!/bin/bash
set -euo pipefail
if [[ $# -lt 2 || $# -gt 6 ]]; then
  echo 'usage: replay-doubao.sh input.wav output.jsonl [text|audio|transcript] [source] [target] [preset|clone]' >&2
  exit 2
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
replay_tmp="$(mktemp -d "${TMPDIR:-/tmp}/livetranslate-doubao.XXXXXX")"
trap 'rm -rf "$replay_tmp"' EXIT
ffmpeg -nostdin -v error -i "$1" -f s16le -ar 16000 -ac 1 "$replay_tmp/input.pcm"
swiftc -module-cache-path "$replay_tmp/cache" -D DEBUG -parse-as-library \
  "$repo_dir/scripts/replay-doubao.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/TranslationClient.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/LiveTranslationSession.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/DoubaoTranslationClient.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/DoubaoProtocol.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/ServerItemLinks.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/CredentialStore.swift" \
  "$repo_dir/LiveTranslateBridge/CallAudioKit/BridgeLog.swift" \
  -o "$replay_tmp/replay"
"$replay_tmp/replay" "$replay_tmp/input.pcm" "$2" "${3:-text}" "${4:-en}" "${5:-zh}" "${6:-preset}"
