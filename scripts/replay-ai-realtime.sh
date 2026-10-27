#!/bin/bash
set -euo pipefail
if [[ $# -ne 3 ]]; then
  echo 'usage: replay-ai-realtime.sh caller-one.wav caller-two.wav new-output-directory' >&2
  exit 2
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
replay_tmp="$(mktemp -d "${TMPDIR:-/tmp}/livetranslate-ai-realtime.XXXXXX")"
trap 'rm -rf "$replay_tmp"' EXIT
ffmpeg -nostdin -v error -i "$1" -f s16le -ar 16000 -ac 1 "$replay_tmp/one.pcm"
ffmpeg -nostdin -v error -i "$2" -f s16le -ar 16000 -ac 1 "$replay_tmp/two.pcm"
swiftc -module-cache-path "$replay_tmp/cache" -default-isolation MainActor -D DEBUG -parse-as-library \
  "$repo_dir/scripts/replay-ai-realtime.swift" \
  "$repo_dir/LiveTranslateBridge/Agent/CallAgent.swift" \
  "$repo_dir/LiveTranslateBridge/Agent/ChatCompletionClient.swift" \
  "$repo_dir/LiveTranslateBridge/Agent/DoubaoVoiceServices.swift" \
  "$repo_dir/LiveTranslateBridge/Agent/DoubaoRealtimeClient.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/TranslationClient.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/LiveTranslationSession.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/DoubaoTranslationClient.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/DoubaoProtocol.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/ServerItemLinks.swift" \
  "$repo_dir/LiveTranslateBridge/Translation/CredentialStore.swift" \
  "$repo_dir/LiveTranslateBridge/CallAudioKit/BridgeLog.swift" \
  -o "$replay_tmp/replay"
"$replay_tmp/replay" "$replay_tmp/one.pcm" "$replay_tmp/two.pcm" "$3"
