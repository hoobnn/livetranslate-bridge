// Real qwen3.8 event ordering from 2026-09-22 file replay.
// Audio removed; text and identifiers replaced with synthetic fixtures.
import Foundation

nonisolated enum Qwen38RecordedFixture {
    static let json = #"""
[
  {
    "event_id": "event_1",
    "session": {
      "audio": {
        "input": {
          "format": {
            "sample_rate": 16000,
            "type": "pcm"
          },
          "turn_detection": {
            "silence_duration_ms": 2500,
            "threshold": 0.5,
            "type": "speaker_detection"
          }
        },
        "output": {
          "format": {
            "sample_rate": 24000,
            "type": "pcm"
          },
          "voice": "Tina"
        }
      },
      "id": "sess_0",
      "input_modalities": [
        "audio"
      ],
      "model": "qwen3.8-livetranslate-flash-realtime",
      "object": "realtime.session",
      "output_modalities": [
        "text",
        "audio"
      ],
      "translation": {
        "language": "en"
      }
    },
    "type": "session.created"
  },
  {
    "event_id": "event_2",
    "session": {
      "audio": {
        "input": {
          "format": {
            "sample_rate": 16000,
            "type": "pcm"
          },
          "turn_detection": {
            "create_response": true,
            "interrupt_response": true,
            "threshold": 0.5,
            "type": "speaker_detection"
          }
        },
        "output": {
          "format": {
            "sample_rate": 24000,
            "type": "pcm"
          },
          "voice": "Tina"
        }
      },
      "id": "sess_0",
      "input_modalities": [
        "audio"
      ],
      "model": "qwen3.8-livetranslate-flash-realtime",
      "object": "realtime.session",
      "output_modalities": [
        "text",
        "audio"
      ],
      "translation": {
        "language": "zh"
      },
      "turn_detection": {
        "create_response": true,
        "interrupt_response": true,
        "threshold": 0.5,
        "type": "speaker_detection"
      }
    },
    "type": "session.updated"
  },
  {
    "audio_start_ms": 200,
    "event_id": "event_3",
    "item_id": "item_1",
    "speaker_id": 1,
    "type": "input_audio_buffer.speech_started"
  },
  {
    "event_id": "event_4",
    "item": {
      "content": [
        {
          "type": "input_audio"
        }
      ],
      "id": "item_1",
      "object": "realtime.item",
      "role": "assistant",
      "status": "in_progress",
      "type": "message"
    },
    "type": "conversation.item.created"
  },
  {
    "event_id": "event_5",
    "response": {
      "conversation_id": "",
      "id": "resp_0",
      "modalities": [
        "text",
        "audio"
      ],
      "object": "realtime.response",
      "output": [],
      "output_audio_format": "pcm",
      "status": "in_progress"
    },
    "type": "response.created"
  },
  {
    "event_id": "event_6",
    "item": {
      "content": [],
      "id": "item_2",
      "object": "realtime.item",
      "role": "assistant",
      "status": "in_progress",
      "type": "message"
    },
    "output_index": 0,
    "response_id": "resp_0",
    "type": "response.output_item.added"
  },
  {
    "event_id": "event_7",
    "item": {
      "content": [],
      "id": "item_2",
      "object": "realtime.item",
      "role": "assistant",
      "status": "in_progress",
      "type": "message"
    },
    "previous_item_id": "item_1",
    "type": "conversation.item.created"
  },
  {
    "content_index": 0,
    "event_id": "event_8",
    "item_id": "item_2",
    "output_index": 0,
    "part": {
      "text": "",
      "type": "audio"
    },
    "response_id": "resp_0",
    "type": "response.content_part.added"
  },
  {
    "content_index": 0,
    "delta": "source ",
    "event_id": "event_9",
    "item_id": "item_1",
    "obfuscation": "IRFtayAfmrdQD7",
    "type": "conversation.item.input_audio_transcription.delta"
  },
  {
    "content_index": 0,
    "delta": "source ",
    "event_id": "event_10",
    "item_id": "item_1",
    "obfuscation": "I2wON9eXGlzXvY",
    "type": "conversation.item.input_audio_transcription.delta"
  },
  {
    "content_index": 0,
    "delta": "译",
    "event_id": "event_11",
    "item_id": "item_2",
    "output_index": 0,
    "response_id": "resp_0",
    "type": "response.audio_transcript.delta"
  },
  {
    "content_index": 0,
    "delta": "译",
    "event_id": "event_12",
    "item_id": "item_2",
    "output_index": 0,
    "response_id": "resp_0",
    "type": "response.audio_transcript.delta"
  },
  {
    "content_index": 0,
    "delta": "译",
    "event_id": "event_13",
    "item_id": "item_2",
    "output_index": 0,
    "response_id": "resp_0",
    "type": "response.audio_transcript.delta"
  },
  {
    "content_index": 0,
    "delta": "source ",
    "event_id": "event_14",
    "item_id": "item_1",
    "obfuscation": "PYo2gs5duMAqGE",
    "type": "conversation.item.input_audio_transcription.delta"
  },
  {
    "audio_end_ms": 27280,
    "event_id": "event_15",
    "item_id": "item_1",
    "type": "input_audio_buffer.speech_stopped"
  },
  {
    "content_index": 0,
    "event_id": "event_16",
    "item_id": "item_1",
    "transcript": "Source sentence 1 with final tail.",
    "type": "conversation.item.input_audio_transcription.completed"
  },
  {
    "content_index": 0,
    "event_id": "event_17",
    "item_id": "item_2",
    "output_index": 0,
    "response_id": "resp_0",
    "transcript": "完整译文1。",
    "type": "response.audio_transcript.done"
  },
  {
    "content_index": 0,
    "event_id": "event_18",
    "item_id": "item_2",
    "output_index": 0,
    "response_id": "resp_0",
    "type": "response.audio.done"
  },
  {
    "content_index": 0,
    "event_id": "event_19",
    "item_id": "item_2",
    "output_index": 0,
    "part": {
      "text": "这本书的显著特点之一，就是它包含了一份更为详尽的词缀列表，比同级别的其他书籍都要丰富。此外，书中还提供了练习题，让学生能够灵活运用所学英语。同样，与大多数同类教材不同，《用英语表达自我》这本书直到第三单元才正式介绍动词“to be”。",
      "type": "audio"
    },
    "response_id": "resp_0",
    "type": "response.content_part.done"
  },
  {
    "event_id": "event_20",
    "item": {
      "content": [
        {
          "text": "这本书的显著特点之一，就是它包含了一份更为详尽的词缀列表，比同级别的其他书籍都要丰富。此外，书中还提供了练习题，让学生能够灵活运用所学英语。同样，与大多数同类教材不同，《用英语表达自我》这本书直到第三单元才正式介绍动词“to be”。",
          "type": "audio"
        }
      ],
      "id": "item_2",
      "object": "realtime.item",
      "role": "assistant",
      "status": "completed",
      "type": "message"
    },
    "output_index": 0,
    "response_id": "resp_0",
    "type": "response.output_item.done"
  },
  {
    "event_id": "event_21",
    "response": {
      "conversation_id": "conv_0",
      "id": "resp_0",
      "modalities": [
        "text",
        "audio"
      ],
      "object": "realtime.response",
      "output": [
        {
          "content": [
            {
              "transcript": "完整译文1。",
              "type": "audio"
            }
          ],
          "id": "item_2",
          "object": "realtime.item",
          "role": "assistant",
          "status": "completed",
          "type": "message"
        }
      ],
      "status": "completed"
    },
    "type": "response.done"
  },
  {
    "audio_start_ms": 27280,
    "event_id": "event_22",
    "item_id": "item_3",
    "speaker_id": 1,
    "type": "input_audio_buffer.speech_started"
  },
  {
    "event_id": "event_23",
    "item": {
      "content": [
        {
          "type": "input_audio"
        }
      ],
      "id": "item_3",
      "object": "realtime.item",
      "role": "assistant",
      "status": "in_progress",
      "type": "message"
    },
    "previous_item_id": "item_2",
    "type": "conversation.item.created"
  },
  {
    "event_id": "event_24",
    "response": {
      "conversation_id": "",
      "id": "resp_1",
      "modalities": [
        "text",
        "audio"
      ],
      "object": "realtime.response",
      "output": [],
      "output_audio_format": "pcm",
      "status": "in_progress"
    },
    "type": "response.created"
  },
  {
    "event_id": "event_25",
    "item": {
      "content": [],
      "id": "item_4",
      "object": "realtime.item",
      "role": "assistant",
      "status": "in_progress",
      "type": "message"
    },
    "output_index": 0,
    "response_id": "resp_1",
    "type": "response.output_item.added"
  },
  {
    "event_id": "event_26",
    "item": {
      "content": [],
      "id": "item_4",
      "object": "realtime.item",
      "role": "assistant",
      "status": "in_progress",
      "type": "message"
    },
    "previous_item_id": "item_3",
    "type": "conversation.item.created"
  },
  {
    "content_index": 0,
    "event_id": "event_27",
    "item_id": "item_4",
    "output_index": 0,
    "part": {
      "text": "",
      "type": "audio"
    },
    "response_id": "resp_1",
    "type": "response.content_part.added"
  },
  {
    "content_index": 0,
    "delta": "source ",
    "event_id": "event_28",
    "item_id": "item_3",
    "obfuscation": "HTyc6i2CETyzGc",
    "type": "conversation.item.input_audio_transcription.delta"
  },
  {
    "content_index": 0,
    "delta": "source ",
    "event_id": "event_29",
    "item_id": "item_3",
    "obfuscation": "VDSiR9TKA6V8Zd",
    "type": "conversation.item.input_audio_transcription.delta"
  },
  {
    "content_index": 0,
    "delta": "source ",
    "event_id": "event_30",
    "item_id": "item_3",
    "obfuscation": "JlwSCJFDmpurja",
    "type": "conversation.item.input_audio_transcription.delta"
  },
  {
    "content_index": 0,
    "delta": "译",
    "event_id": "event_31",
    "item_id": "item_4",
    "output_index": 0,
    "response_id": "resp_1",
    "type": "response.audio_transcript.delta"
  },
  {
    "content_index": 0,
    "delta": "译",
    "event_id": "event_32",
    "item_id": "item_4",
    "output_index": 0,
    "response_id": "resp_1",
    "type": "response.audio_transcript.delta"
  },
  {
    "content_index": 0,
    "delta": "译",
    "event_id": "event_33",
    "item_id": "item_4",
    "output_index": 0,
    "response_id": "resp_1",
    "type": "response.audio_transcript.delta"
  },
  {
    "audio_end_ms": 57280,
    "event_id": "event_34",
    "item_id": "item_3",
    "type": "input_audio_buffer.speech_stopped"
  },
  {
    "content_index": 0,
    "event_id": "event_35",
    "item_id": "item_3",
    "transcript": "Source sentence 2 with final tail.",
    "type": "conversation.item.input_audio_transcription.completed"
  },
  {
    "content_index": 0,
    "event_id": "event_36",
    "item_id": "item_4",
    "output_index": 0,
    "response_id": "resp_1",
    "transcript": "完整译文2。",
    "type": "response.audio_transcript.done"
  },
  {
    "content_index": 0,
    "event_id": "event_37",
    "item_id": "item_4",
    "output_index": 0,
    "response_id": "resp_1",
    "type": "response.audio.done"
  },
  {
    "content_index": 0,
    "event_id": "event_38",
    "item_id": "item_4",
    "output_index": 0,
    "part": {
      "text": "给老师和学生的一点建议是，不要指望仅通过书中的练习题就能在考试中取得好成绩。除非他们在课外进行额外的学习。并且背诵每个单元开头的对话。为了保持低价，这本书采用平装。而且所有的图片和插图都是黑白的。这本教材将配套一本练习册。预计将于今年晚些时候出版。",
      "type": "audio"
    },
    "response_id": "resp_1",
    "type": "response.content_part.done"
  },
  {
    "event_id": "event_39",
    "item": {
      "content": [
        {
          "text": "给老师和学生的一点建议是，不要指望仅通过书中的练习题就能在考试中取得好成绩。除非他们在课外进行额外的学习。并且背诵每个单元开头的对话。为了保持低价，这本书采用平装。而且所有的图片和插图都是黑白的。这本教材将配套一本练习册。预计将于今年晚些时候出版。",
          "type": "audio"
        }
      ],
      "id": "item_4",
      "object": "realtime.item",
      "role": "assistant",
      "status": "completed",
      "type": "message"
    },
    "output_index": 0,
    "response_id": "resp_1",
    "type": "response.output_item.done"
  },
  {
    "event_id": "event_40",
    "response": {
      "conversation_id": "conv_0",
      "id": "resp_1",
      "modalities": [
        "text",
        "audio"
      ],
      "object": "realtime.response",
      "output": [
        {
          "content": [
            {
              "transcript": "完整译文2。",
              "type": "audio"
            }
          ],
          "id": "item_4",
          "object": "realtime.item",
          "role": "assistant",
          "status": "completed",
          "type": "message"
        }
      ],
      "status": "completed"
    },
    "type": "response.done"
  },
  {
    "event_id": "event_41",
    "type": "session.finished"
  }
]
"""#
}
