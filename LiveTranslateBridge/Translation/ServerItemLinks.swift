import Foundation

/// previous_item_id is also conversation ordering. An assistant role alone is
/// not proof of translation: some ASR items use that role as well.
nonisolated struct ServerItemLinks {
    private var sources = Set<String>()
    private var translations = Set<String>()
    private var predecessors: [String: String] = [:]
    private var emitted: [String: String] = [:]
    private var known = Set<String>()
    private var order: [String] = []

    mutating func observe(type: String, event: [String: Any]) -> [(output: String, source: String)] {
        let itemID = event["item_id"] as? String
        if type.hasPrefix("conversation.item.input_audio_transcription.")
            || type == "input_audio_buffer.speech_started"
            || type == "input_audio_buffer.speech_stopped" {
            if let itemID {
                remember(itemID)
                sources.insert(itemID)
                translations.remove(itemID)
                predecessors.removeValue(forKey: itemID)
            }
        }
        if type.hasPrefix("response.text.") || type.hasPrefix("response.audio_transcript.")
            || type == "response.audio.delta" || type == "response.audio.done" {
            if let itemID, event["response_id"] is String, !sources.contains(itemID) {
                remember(itemID)
                translations.insert(itemID)
            }
        }
        if type == "response.done", let response = event["response"] as? [String: Any] {
            for item in response["output"] as? [[String: Any]] ?? [] {
                if let id = item["id"] as? String, !sources.contains(id) {
                    remember(id)
                    translations.insert(id)
                }
            }
        }
        if type == "conversation.item.created" || type == "response.output_item.added"
            || type == "response.output_item.done" {
            if let item = event["item"] as? [String: Any], let id = item["id"] as? String,
               let previous = (event["previous_item_id"] ?? item["previous_item_id"]) as? String,
               id != previous, !sources.contains(id) {
                remember(id); remember(previous)
                predecessors[id] = previous
            }
        }
        var links: [(output: String, source: String)] = []
        for (output, source) in predecessors where translations.contains(output)
            && !sources.contains(output) && sources.contains(source) && emitted[output] != source {
            emitted[output] = source
            links.append((output, source))
        }
        return links
    }

    private mutating func remember(_ id: String) {
        if known.insert(id).inserted { order.append(id) }
        while order.count > 4096 {
            let old = order.removeFirst()
            known.remove(old); sources.remove(old); translations.remove(old)
            predecessors.removeValue(forKey: old); emitted.removeValue(forKey: old)
        }
    }
}
