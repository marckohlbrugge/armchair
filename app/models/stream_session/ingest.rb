require "open3"

class StreamSession::Ingest
  def initialize(stream_session)
    @session = stream_session
    @turns = StreamSession::TurnBuilder.new(stream_session)
    @shadow_logger = nil
    @openai_shadow = nil
  end

  def run
    @session.update!(status: "running", started_at: Time.current)
    abort_session!("session has no stream URL") if @session.youtube_url.blank?

    stream_url = resolve_stream_url(@session.youtube_url)
    setup_shadow_logging!

    EM.run do
      ws = StreamSession::Deepgram.open_client
      @openai_shadow = build_openai_shadow_client
      audio_io = nil
      pump = nil

      ws.on :open do
        log "deepgram connected, starting ffmpeg"
        audio_io = open_audio_pipe(stream_url)
        pump = start_pump(ws, audio_io, @openai_shadow)
      end

      ws.on :message do |event|
        shadow_log_deepgram(event.data)
        @turns.handle(event.data)
      end

      ws.on :close do |event|
        log "deepgram closed: #{event.code}"
        @turns.flush!
        @openai_shadow&.close
        audio_io&.close
        pump&.kill
        @session.update!(status: "stopped", stopped_at: Time.current)
        @shadow_logger&.close
        EM.stop
      end

      trap("INT") do
        ws.close
      rescue => e
        log "INT trap close failed: #{e.class} #{e.message}"
      end
    end
  end

  private

  # Sites like X/Twitter serve signed, short-lived HLS URLs that have to be
  # fetched fresh from the machine doing the ingesting (JWTs are IP-pinned).
  # yt-dlp's `-g` prints the direct stream URL; we fall back to the raw input
  # if yt-dlp isn't available or doesn't recognize the site, so pasting a
  # plain .m3u8/Icecast URL still works without a round-trip.
  def resolve_stream_url(url)
    stdout, stderr, status = Open3.capture3(
      "yt-dlp", "-g", "--no-warnings",
      "-f", "bestaudio/best",
      "--extractor-retries", "5",
      "--sleep-requests", "2",
      url
    )
    http_line = stdout.lines.map(&:strip).find { |l| l.start_with?("http") }
    if status.success? && http_line
      log "yt-dlp resolved stream URL"
      http_line
    else
      log "yt-dlp did not resolve (exit=#{status.exitstatus}): #{stderr.lines.last&.strip} — using raw URL"
      url
    end
  rescue Errno::ENOENT
    log "yt-dlp not on PATH — using raw URL"
    url
  end

  def open_audio_pipe(url)
    cmd = %(ffmpeg -hide_banner -nostdin -loglevel fatal \
      -user_agent "Mozilla/5.0" \
      -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
      -i #{url.shellescape} \
      -f s16le -acodec pcm_s16le -ac 1 -ar 16000 pipe:1).gsub(/\s+/, " ")
    IO.popen(cmd, "rb")
  end

  def start_pump(ws, audio_io, openai_shadow)
    Thread.new do
      chunks = 0
      bytes = 0
      begin
        while (chunk = audio_io.read(3200))
          chunks += 1
          bytes += chunk.bytesize
          @shadow_logger&.audio_stream_started!(chunk_bytes: chunk.bytesize) if chunks == 1
          EM.schedule { ws.send(chunk) }
          EM.schedule do
            openai_shadow&.append_audio(chunk)
            openai_shadow&.commit! if openai_shadow && (chunks % shadow_commit_every_chunks).zero?
          rescue => e
            log "openai shadow append failed: #{e.class} #{e.message}"
          end
        end
      rescue IOError
        log "audio pipe closed while reading; shutting down pump"
      ensure
        @shadow_logger&.audio_stream_finished!(chunks:, bytes:)
        EM.schedule do
          openai_shadow&.commit!
          ws.send(StreamSession::Deepgram::CLOSE_MESSAGE)
        rescue => e
          log "pump close send failed: #{e.class} #{e.message}"
        end
      end
    end
  end

  def setup_shadow_logging!
    return unless shadow_openai?

    @shadow_logger = StreamSession::TranscriptionShadowLogger.new(@session)
    log "shadow STT enabled (provider=openai path=#{@shadow_logger.path})"
  end

  def build_openai_shadow_client
    return unless shadow_openai?
    unless StreamSession::OpenaiRealtimeWhisper.configured?
      log "shadow STT requested but OPENAI_API_KEY is missing; continuing without shadow provider"
      return nil
    end

    StreamSession::OpenaiRealtimeWhisper.new(on_event: method(:handle_openai_shadow_event)).connect
  rescue => e
    log "failed to connect OpenAI shadow STT: #{e.class} #{e.message}"
    nil
  end

  def shadow_openai?
    ENV["STT_SHADOW"] == "openai"
  end

  def shadow_commit_every_chunks
    ENV.fetch("STT_OPENAI_COMMIT_EVERY_CHUNKS", "12").to_i.clamp(1, 10_000)
  end

  def handle_openai_shadow_event(event)
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

  def log(msg)
    Rails.logger.info "[session=#{@session.id}] #{msg}"
    puts "[session=#{@session.id}] #{msg}"
  end

  def abort_session!(reason)
    @session.update!(status: "stopped", stopped_at: Time.current)
    abort "[ingest] #{reason}"
  end
end
