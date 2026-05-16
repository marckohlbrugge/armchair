require "json"
require "thread"

class StreamSession::TranscriptionShadowLogger
  def initialize(stream_session, path: nil)
    @session = stream_session
    @path = path.presence || Rails.root.join("log/stt_shadow_#{stream_session.id}.jsonl").to_s
    @mutex = Mutex.new
    @io = File.open(@path, "a")
  end

  attr_reader :path

  def audio_stream_started!(chunk_bytes:)
    write(type: "audio_stream_started", chunk_bytes:)
  end

  def audio_stream_finished!(chunks:, bytes:)
    write(type: "audio_stream_finished", chunks:, bytes:)
  end

  def provider_event!(provider:, event_type:, text: nil, final: nil, item_id: nil, code: nil, message: nil)
    write(
      type: "provider_event",
      provider:,
      event_type:,
      text: text.presence,
      final:,
      item_id: item_id.presence,
      code:,
      message: message.presence
    )
  end

  def close
    @mutex.synchronize do
      @io.close unless @io.closed?
    end
  end

  private

  def write(payload)
    row = {
      session_id: @session.id,
      wall_time: Time.current.iso8601(6),
      mono_ms: monotonic_ms
    }.merge(payload).compact

    @mutex.synchronize do
      return if @io.closed?
      @io.write("#{row.to_json}\n")
      @io.flush
    end
  rescue IOError
    nil
  end

  def monotonic_ms
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round(3)
  end
end
