class SseWriter
  def initialize(stream)
    @stream = stream
  end

  def <<(chunk)
    return self if chunk.nil? || chunk.empty?
    payload = { delta: chunk.to_s }.to_json
    @stream.write "data: #{payload}\n\n"
    self
  end

  def event(name, data = {})
    @stream.write "event: #{name}\ndata: #{data.to_json}\n\n"
  end
end
