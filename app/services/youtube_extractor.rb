# frozen_string_literal: true

# YouTubeExtractor - YouTube 영상에서 콘텐츠 추출
#
# 사용법:
#   result = YouTubeExtractor.extract("https://www.youtube.com/watch?v=VIDEO_ID")
#   result[:title]       # 영상 제목
#   result[:description] # 영상 설명
#   result[:channel]     # 채널명
#   result[:content]     # 전체 콘텐츠 (제목 + 설명 + 메타)
#
class YouTubeExtractor
  require "net/http"
  require "uri"
  require "json"

  class ExtractionError < StandardError; end

  HEADERS = {
    "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
    "Accept-Language" => "ko-KR,ko;q=0.9,en;q=0.8"
  }.freeze

  def self.extract(url)
    new(url).extract
  end

  def initialize(url)
    @url = url
    @video_id = extract_video_id(url)
  end

  def extract
    raise ExtractionError, "Invalid YouTube URL: #{@url}" unless @video_id

    html = fetch_page
    parse_content(html)
  rescue StandardError => e
    raise ExtractionError, "Failed to extract: #{e.message}"
  end

  private

  def extract_video_id(url)
    uri = URI.parse(url)

    if uri.host&.include?("youtu.be")
      uri.path.delete_prefix("/")
    elsif uri.host&.include?("youtube.com")
      params = URI.decode_www_form(uri.query || "").to_h
      params["v"]
    end
  rescue URI::InvalidURIError
    nil
  end

  def fetch_page
    uri = URI.parse("https://www.youtube.com/watch?v=#{@video_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri)
    HEADERS.each { |k, v| request[k] = v }

    response = http.request(request)
    raise ExtractionError, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    response.body
  end

  def parse_content(html)
    title = extract_title(html)
    description = extract_description(html)
    channel = extract_channel(html)
    views = extract_views(html)
    duration = extract_duration(html)

    content_parts = []
    content_parts << "제목: #{title}" if title
    content_parts << "채널: #{channel}" if channel
    content_parts << "조회수: #{number_with_comma(views)}" if views
    content_parts << "길이: #{duration}" if duration
    content_parts << "\n설명:\n#{description}" if description.present?

    {
      video_id: @video_id,
      url: @url,
      title: title,
      description: description,
      channel: channel,
      views: views.to_i,
      duration: duration,
      content: content_parts.join("\n"),
      extracted_at: Time.current
    }
  end

  def extract_title(html)
    match = html.match(/"title":"([^"]+)"/)
    return unescape_unicode(match[1]) if match

    match = html.match(/<title>([^<]+) - YouTube<\/title>/)
    match&.[](1)
  end

  def extract_description(html)
    match = html.match(/"shortDescription":"([^"]*)"/)
    return nil unless match

    desc = unescape_unicode(match[1])
    desc.gsub('\n', "\n")
  end

  def extract_channel(html)
    match = html.match(/"ownerChannelName":"([^"]+)"/)
    match&.[](1)
  end

  def extract_views(html)
    match = html.match(/"viewCount":"(\d+)"/)
    match&.[](1)
  end

  def extract_duration(html)
    match = html.match(/"lengthSeconds":"(\d+)"/)
    return nil unless match

    seconds = match[1].to_i
    minutes = seconds / 60
    secs = seconds % 60
    "#{minutes}:#{secs.to_s.rjust(2, '0')}"
  end

  def unescape_unicode(str)
    str.gsub(/\\u([0-9a-fA-F]{4})/) { [$1.to_i(16)].pack("U") }
       .gsub(/\\n/, "\n")
       .gsub(/\\r/, "")
       .gsub(/\\"/, '"')
  end

  def number_with_comma(num)
    return nil unless num
    num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
  end
end
