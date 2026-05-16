class StreamSession::BrowserIngest
  def initialize(session, browser_ws)
    @session = session
    @browser = browser_ws
    @turns = StreamSession::TurnBuilder.new(session)
    @primary_provider = resolve_primary_provider
    @shadow_logger = nil
    @audio_chunks = 0
    @audio_bytes = 0
    @openai_primary = nil
    @openai_shadow = nil
    @deepgram = nil
    @deepgram_shadow = nil
  end

  def attach!
    log "browser ws attached, reactor_running=#{EM.reactor_running?}"
    StreamSession::Deepgram.ensure_reactor!
    log "reactor ensured, scheduling #{@primary_provider} connect"
    EM.schedule do
      begin
        start_primary
      rescue => e
        log "start_primary raised: #{e.class} #{e.message} — #{e.backtrace&.first(3)&.join(' | ')}"
        @browser&.close rescue nil
      end
    end
  end

  private

  def start_primary
    case @primary_provider
    when "openai"
      start_openai_primary
    else
      start_deepgram_primary
    end
  end

  def start_deepgram_primary
    log "opening deepgram client, api_key_present=#{StreamSession::Deepgram.api_key.present?}"
    setup_shadow_logging!
    @openai_shadow = build_openai_shadow_client
    @deepgram = StreamSession::Deepgram.open_client
    log "deepgram client created, registering callbacks"

    @deepgram.on(:open) { log "deepgram open"; mark_running }
    @deepgram.on(:error) { |event| log "deepgram error: #{event.message}" }
    @deepgram.on(:message) do |event|
      shadow_log_deepgram(event.data)
      @turns.handle(event.data)
      close_for_invite_limit! if @turns.limit_reached?
    end
    @deepgram.on(:close) do |event|
      log "deepgram closed code=#{event.code} reason=#{event.reason.inspect}"
      cleanup
    end

    register_browser_handlers(
      on_frame: method(:send_audio_to_deepgram_primary),
      on_close: method(:close_deepgram_primary)
    )
  end

  def start_openai_primary
    log "opening openai realtime whisper client"
    setup_shadow_logging!
    @deepgram_shadow = build_deepgram_shadow_client
    @openai_primary = build_openai_primary_client
    raise "failed to initialize openai primary client" unless @openai_primary

    register_browser_handlers(
      on_frame: method(:send_audio_to_openai_primary),
      on_close: method(:close_openai_primary)
    )
  end

  def register_browser_handlers(on_frame:, on_close:)
    @browser.on(:message) do |event|
      frame = event.data
      @audio_chunks += 1
      @audio_bytes += frame.bytesize
      @shadow_logger&.audio_stream_started!(chunk_bytes: frame.bytesize) if @audio_chunks == 1
      EM.schedule { on_frame.call(frame) }
    end

    @browser.on(:close) do |event|
      log "browser ws closed code=#{event.code} reason=#{event.reason.inspect}"
      EM.schedule do
        @shadow_logger&.audio_stream_finished!(chunks: @audio_chunks, bytes: @audio_bytes)
        on_close.call
      rescue => e
        log "browser close handling failed: #{e.class} #{e.message}"
      end
    end
  end

  def send_audio_to_deepgram_primary(frame)
    @deepgram&.send(frame)
    return unless @openai_shadow

    @openai_shadow.append_audio(frame)
    @openai_shadow.commit! if (@audio_chunks % shadow_commit_every_chunks).zero?
  rescue => e
    log "openai shadow append failed: #{e.class} #{e.message}"
  end

  def send_audio_to_openai_primary(frame)
    @openai_primary&.append_audio(frame)
    @openai_primary&.commit! if (@audio_chunks % shadow_commit_every_chunks).zero?
    @deepgram_shadow&.send(frame)
  rescue => e
    log "openai primary append failed: #{e.class} #{e.message}"
  end

  def close_deepgram_primary
    @openai_shadow&.commit!
    @deepgram&.send(StreamSession::Deepgram::CLOSE_MESSAGE)
  rescue => e
    log "deepgram primary close failed: #{e.class} #{e.message}"
  end

  def close_openai_primary
    @openai_primary&.commit!
    @openai_primary&.close
    @deepgram_shadow&.send(StreamSession::Deepgram::CLOSE_MESSAGE)
  rescue => e
    log "openai primary close failed: #{e.class} #{e.message}"
  end

  def build_openai_primary_client
    unless StreamSession::OpenaiRealtimeWhisper.configured?
      log "openai primary requested but OPENAI_API_KEY is missing"
      return nil
    end

    StreamSession::OpenaiRealtimeWhisper.new(on_event: method(:handle_openai_primary_event)).connect
  rescue => e
    log "failed to connect OpenAI primary STT: #{e.class} #{e.message}"
    nil
  end

  def handle_openai_primary_event(event)
    shadow_log_openai(event)
    type = event["type"].to_s

    case type
    when "open"
      mark_running
    when "conversation.item.input_audio_transcription.delta", "conversation.item.input_audio_transcription.completed"
      @turns.handle_openai_event(event)
      close_for_invite_limit! if @turns.limit_reached?
    when "error"
      log "openai primary error: #{event.dig('error', 'message') || event['message']}"
    when "close"
      log "openai primary closed code=#{event['code']} reason=#{event['reason'].inspect}"
      cleanup
    end
  end

  def mark_running
    ActiveRecord::Base.connection_pool.with_connection do
      @session.update!(status: "running", started_at: Time.current) unless @session.running?
    end
  end

  def cleanup
    @turns.flush!
    ActiveRecord::Base.connection_pool.with_connection do
      @session.update!(status: "stopped", stopped_at: Time.current)
    end
    @openai_primary&.close
    @openai_shadow&.close
    @deepgram_shadow&.close
    @shadow_logger&.close
    @browser.close rescue nil
    @openai_primary = nil
    @openai_shadow = nil
    @deepgram = nil
    @deepgram_shadow = nil
  end

  def close_for_invite_limit!
    return if @closing_for_limit
    @closing_for_limit = true
    EM.schedule do
      if @primary_provider == "openai"
        @openai_primary&.close
      else
        @deepgram&.send(StreamSession::Deepgram::CLOSE_MESSAGE)
      end
    rescue => e
      log "invite-limit close failed: #{e.class} #{e.message}"
    end
  end

  def log(msg)
    Rails.logger.info "[browser_ingest session=#{@session.id}] #{msg}"
  end

  def setup_shadow_logging!
    return unless shadow_provider
    return if @shadow_logger

    @shadow_logger = StreamSession::TranscriptionShadowLogger.new(@session)
    log "shadow STT enabled (provider=#{shadow_provider} path=#{@shadow_logger.path})"
  end

  def build_openai_shadow_client
    return unless shadow_provider == "openai"
    unless StreamSession::OpenaiRealtimeWhisper.configured?
      log "shadow STT requested but OPENAI_API_KEY is missing; continuing without shadow provider"
      return nil
    end

    StreamSession::OpenaiRealtimeWhisper.new(on_event: method(:handle_openai_shadow_event)).connect
  rescue => e
    log "failed to connect OpenAI shadow STT: #{e.class} #{e.message}"
    nil
  end

  def build_deepgram_shadow_client
    return unless shadow_provider == "deepgram"

    ws = StreamSession::Deepgram.open_client
    ws.on(:open) { log "deepgram shadow open" }
    ws.on(:error) { |event| log "deepgram shadow error: #{event.message}" }
    ws.on(:message) { |event| shadow_log_deepgram(event.data) }
    ws.on(:close) { |event| log "deepgram shadow closed code=#{event.code} reason=#{event.reason.inspect}" }
    ws
  rescue => e
    log "failed to connect Deepgram shadow STT: #{e.class} #{e.message}"
    nil
  end

  def resolve_primary_provider
    provider = ENV.fetch("STT_PROVIDER", "deepgram")
    %w[deepgram openai].include?(provider) ? provider : "deepgram"
  end

  def shadow_provider
    provider = ENV["STT_SHADOW"].presence
    return nil unless %w[deepgram openai].include?(provider)
    return nil if provider == @primary_provider
    provider
  end

  def shadow_commit_every_chunks
    ENV.fetch("STT_OPENAI_COMMIT_EVERY_CHUNKS", "12").to_i.clamp(1, 10_000)
  end

  def handle_openai_shadow_event(event)
    shadow_log_openai(event)
  end

  def shadow_log_openai(event)
    return unless @shadow_logger

    type = event["type"].to_s
    case type
    when "conversation.item.input_audio_transcription.delta"
      @shadow_logger&.provider_event!(
        provider: "openai",
        event_type: type,
        text: event["delta"],
        final: false,
        item_id: event["item_id"]
      )
    when "conversation.item.input_audio_transcription.completed"
      @shadow_logger&.provider_event!(
        provider: "openai",
        event_type: type,
        text: event["transcript"],
        final: true,
        item_id: event["item_id"]
      )
    when "error", "close", "open", "parse_error"
      @shadow_logger&.provider_event!(
        provider: "openai",
        event_type: type,
        code: event["code"],
        message: event["message"] || event.dig("error", "message")
      )
    end
  end

  def shadow_log_deepgram(raw)
    return unless @shadow_logger

    data = JSON.parse(raw)
    text = data.dig("channel", "alternatives", 0, "transcript").to_s
    return if text.blank?

    @shadow_logger.provider_event!(
      provider: "deepgram",
      event_type: "Results",
      text: text,
      final: !!data["is_final"]
    )
  rescue JSON::ParserError
    nil
  end
end
