#!/usr/bin/env ruby
# Usage: bin/rails runner script/stt_bakeoff_report.rb <stream-session-id> [shadow-log-path]

require "json"

session_id = ARGV[0] or abort "Usage: bin/rails runner script/stt_bakeoff_report.rb <stream-session-id> [shadow-log-path]"
session = StreamSession.find(session_id)
log_path = ARGV[1].presence || Rails.root.join("log/stt_shadow_#{session.id}.jsonl").to_s

abort "Shadow log not found: #{log_path}" unless File.exist?(log_path)

rows = File.readlines(log_path, chomp: true).filter_map do |line|
  JSON.parse(line)
rescue JSON::ParserError
  nil
end

abort "No rows in shadow log: #{log_path}" if rows.empty?

audio_start = rows.find { |row| row["type"] == "audio_stream_started" }&.dig("mono_ms")
abort "No audio_stream_started event in: #{log_path}" unless audio_start

provider_events = rows.select { |row| row["type"] == "provider_event" }

deepgram_partial = provider_events.select { |row| row["provider"] == "deepgram" && !row["final"] && row["text"].present? }
deepgram_final = provider_events.select { |row| row["provider"] == "deepgram" && row["final"] && row["text"].present? }
openai_partial = provider_events.select { |row| row["provider"] == "openai" && !row["final"] && row["text"].present? }
openai_final = provider_events.select { |row| row["provider"] == "openai" && row["final"] && row["text"].present? }

def first_latency_ms(events, audio_start)
  return nil if events.empty?
  (events.first["mono_ms"] - audio_start).round(1)
end

def tokenize(text)
  text.to_s.downcase.scan(/[a-z0-9']+/)
end

def word_distance(a, b)
  m = a.length
  n = b.length
  return n if m.zero?
  return m if n.zero?

  dp = Array.new(m + 1) { Array.new(n + 1, 0) }
  (0..m).each { |i| dp[i][0] = i }
  (0..n).each { |j| dp[0][j] = j }

  (1..m).each do |i|
    (1..n).each do |j|
      cost = a[i - 1] == b[j - 1] ? 0 : 1
      dp[i][j] = [
        dp[i - 1][j] + 1,
        dp[i][j - 1] + 1,
        dp[i - 1][j - 1] + cost
      ].min
    end
  end

  dp[m][n]
end

def normalized_word_distance(a_text, b_text)
  a = tokenize(a_text)
  b = tokenize(b_text)
  baseline = [ a.length, b.length ].max
  return 0.0 if baseline.zero?
  (word_distance(a, b) / baseline.to_f).round(4)
end

paired_count = [ deepgram_final.length, openai_final.length ].min
distances = (0...paired_count).map do |index|
  normalized_word_distance(deepgram_final[index]["text"], openai_final[index]["text"])
end

puts "STT bakeoff report"
puts "session_id: #{session.id}"
puts "shadow_log: #{log_path}"
puts "turns_persisted: #{session.turns.count}"
puts
puts "Latency from first audio chunk:"
puts "  deepgram first partial: #{first_latency_ms(deepgram_partial, audio_start) || "n/a"} ms"
puts "  deepgram first final:   #{first_latency_ms(deepgram_final, audio_start) || "n/a"} ms"
puts "  openai first partial:   #{first_latency_ms(openai_partial, audio_start) || "n/a"} ms"
puts "  openai first final:     #{first_latency_ms(openai_final, audio_start) || "n/a"} ms"
puts
puts "Transcript output counts:"
puts "  deepgram partial/final: #{deepgram_partial.length}/#{deepgram_final.length}"
puts "  openai partial/final:   #{openai_partial.length}/#{openai_final.length}"
puts
if paired_count.zero?
  puts "No comparable final transcripts yet."
else
  avg_distance = (distances.sum / distances.length).round(4)
  puts "Comparable final pairs: #{paired_count}"
  puts "Average normalized word distance (0=identical): #{avg_distance}"
end
