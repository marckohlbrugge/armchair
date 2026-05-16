class TranscriptEvent < ApplicationRecord
  belongs_to :stream_session

  scope :ordered, -> { order(:received_at, :id) }
  scope :finals, -> { where(is_final: true) }
  scope :speech_finals, -> { where(speech_final: true) }

  after_create_commit -> {
    broadcast_append_to(stream_session, :events, target: "events")
  }

  def self.from_deepgram(stream_session, payload)
    alt = payload.dig("channel", "alternatives", 0)
    create!(
      stream_session: stream_session,
      payload: payload,
      kind: payload["type"] || "Results",
      is_final: !!payload["is_final"],
      speech_final: !!payload["speech_final"],
      transcript: alt&.dig("transcript"),
      received_at: Time.current
    )
  end

  def self.from_openai(stream_session, payload)
    kind = payload["type"].to_s
    transcript = case kind
    when "conversation.item.input_audio_transcription.delta"
      payload["delta"]
    when "conversation.item.input_audio_transcription.completed"
      payload["transcript"]
    end

    create!(
      stream_session: stream_session,
      payload: payload,
      kind: kind.presence || "openai_event",
      is_final: kind == "conversation.item.input_audio_transcription.completed",
      speech_final: kind == "conversation.item.input_audio_transcription.completed",
      transcript: transcript,
      received_at: Time.current
    )
  end
end
