class StreamSession::TurnBuilder
  MIN_WORDS_PER_TURN = 8
  MAX_WORDS_PER_TURN = 80

  def initialize(session)
    @session = session
    @buffer = []
    @started_at = nil
    @audio_start_ms = nil
    @audio_end_ms = nil
    @limit_reached = false
  end

  def limit_reached?
    @limit_reached
  end

  def handle(raw)
    handle_deepgram(raw)
  end

  def handle_deepgram(raw)
    data = JSON.parse(raw)
    ActiveRecord::Base.connection_pool.with_connection do
      TranscriptEvent.from_deepgram(@session, data)
      advance_deepgram(data)
    end
  rescue JSON::ParserError
    nil
  end

  def handle_openai_event(data)
    ActiveRecord::Base.connection_pool.with_connection do
      TranscriptEvent.from_openai(@session, data)
      advance_openai(data)
    end
  end

  def flush!
    return unless @buffer.any?
    ActiveRecord::Base.connection_pool.with_connection { close! }
  end

  private

  def advance_deepgram(data)
    text = data.dig("channel", "alternatives", 0, "transcript").to_s
    return if text.empty?

    if data["is_final"]
      @buffer << text
      @started_at ||= Time.current
      @audio_start_ms ||= ((data["start"] || 0) * 1000).to_i
      @audio_end_ms = (((data["start"] || 0) + (data["duration"] || 0)) * 1000).to_i
    end

    return unless @buffer.any?
    close! if should_close?(data)
  end

  def advance_openai(data)
    return unless data["type"] == "conversation.item.input_audio_transcription.completed"

    text = data["transcript"].to_s.strip
    return if text.empty?

    @buffer << text
    @started_at ||= Time.current
    close! if should_close_openai?
  end

  def should_close?(data)
    word_count = @buffer.join(" ").split.size
    return true if word_count >= MAX_WORDS_PER_TURN
    data["speech_final"] && word_count >= MIN_WORDS_PER_TURN
  end

  def should_close_openai?
    word_count = @buffer.join(" ").split.size
    word_count >= MIN_WORDS_PER_TURN || word_count >= MAX_WORDS_PER_TURN
  end

  def close!
    @session.turns.create!(
      text: @buffer.join(" "),
      started_at: @started_at,
      ended_at: Time.current,
      finalized_at: Time.current,
      audio_start_ms: @audio_start_ms,
      audio_end_ms: @audio_end_ms
    )
    @buffer = []
    @started_at = nil
    @audio_start_ms = nil
    @audio_end_ms = nil
    @limit_reached = @session.turn_cap_reached?
  end
end
