require "base64"
require "faye/websocket"
require "json"

class StreamSession::OpenaiRealtimeWhisper
  URL = "wss://api.openai.com/v1/realtime"
  API_PCM_RATE = 24_000

  def self.configured?
    api_key.present?
  end

  def self.api_key
    ENV["OPENAI_API_KEY"].presence || Rails.application.credentials.openai_api_key
  end

  def initialize(model: ENV.fetch("STT_OPENAI_REALTIME_MODEL", "gpt-realtime-whisper"), language: ENV["STT_OPENAI_LANGUAGE"].presence || "en", on_event: nil)
    @model = model
    @language = language
    @on_event = on_event
    @client = nil
    @resample_carry = nil
  end

  def connect
    @client = Faye::WebSocket::Client.new(
      "#{URL}?intent=transcription",
      nil,
      headers: {
        "Authorization" => "Bearer #{self.class.api_key}"
      }
    )

    @client.on :open do
      emit(type: "open")
      @client.send(session_update_payload.to_json)
    end

    @client.on :message do |event|
      payload = JSON.parse(event.data)
      emit(payload)
    rescue JSON::ParserError
      emit(type: "parse_error", raw: event.data.to_s)
    end

    @client.on :error do |event|
      emit(type: "error", message: event.message)
    end

    @client.on :close do |event|
      emit(type: "close", code: event.code, reason: event.reason)
    end

    self
  end

  def append_audio(chunk)
    return unless @client
    @client.send(
      {
        type: "input_audio_buffer.append",
        audio: Base64.strict_encode64(resample_16k_to_24k_pcm16le(chunk))
      }.to_json
    )
  end

  def commit!
    return unless @client
    @client.send({ type: "input_audio_buffer.commit" }.to_json)
  end

  def close
    @client&.close
  end

  private

  def emit(payload)
    normalized = payload.respond_to?(:stringify_keys) ? payload.stringify_keys : payload
    @on_event&.call(normalized)
  end

  def session_update_payload
    {
      type: "session.update",
      session: {
        type: "transcription",
        audio: {
          input: {
            format: {
              type: "audio/pcm",
              rate: API_PCM_RATE
            },
            transcription: {
              model: @model,
              language: @language
            },
            turn_detection: nil
          }
        }
      }
    }
  end

  # Ingest currently emits mono PCM16LE at 16 kHz for Deepgram. OpenAI Realtime
  # transcription sessions require >= 24 kHz for audio/pcm, so shadow mode
  # upsamples in-process with a lightweight linear interpolation.
  def resample_16k_to_24k_pcm16le(chunk)
    samples = chunk.unpack("s<*")
    return chunk if samples.empty?

    if @resample_carry
      samples.unshift(@resample_carry)
      @resample_carry = nil
    end

    if samples.length.odd?
      @resample_carry = samples.pop
    end

    out = []
    samples.each_slice(2) do |a, b|
      midpoint = ((a + b) / 2.0).round
      out << a << midpoint << b
    end

    out.pack("s<*")
  end
end
