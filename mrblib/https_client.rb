class HttpsClient
  HTTP_1_1 = ' HTTP/1.1'
  CRLF = "\r\n"
  HOST = 'Host: '
  CON_CL = 'Connection: close'
  KV_DELI = ': '
  CONTENT_LENGTH = 'Content-Length'
  CONTENT_LENGTH_DC = CONTENT_LENGTH.downcase
  TRANSFER_ENCODING = 'Transfer-Encoding'
  TRANSFER_ENCODING_DC = TRANSFER_ENCODING.downcase
  CHUNKED = 'chunked'
  TRAILER = 'Trailer'
  TRAILER_DC = TRAILER.downcase
  FINAL_CHUNK = "0#{CRLF}#{CRLF}"

  DELETE = 'DELETE '
  GET    = 'GET '
  HEAD   = 'HEAD '
  PATCH  = 'PATCH '
  POST   = 'POST '
  PUT    = 'PUT '

  Response = Struct.new(:minor_version, :status, :msg, :headers, :body)

  def initialize(options = {})
    @tls_config = options.fetch(:tls_config) do
      Tls::Config.new
    end
    @tls_client = options.fetch(:tls_client) do
      Tls::Client.new @tls_config
    end
    @phr = Phr.new
  end

  def delete(url, headers = nil, &block)
    do_request DELETE, url, headers, nil, false, true, &block
  end

  def get(url, headers = nil, &block)
    do_request GET, url, headers, nil, false, true, &block
  end

  def head(url, headers = nil, &block)
    do_request HEAD, url, headers, nil, false, false, &block
  end

  def patch(url, body, headers = nil, &block)
    do_request PATCH, url, headers, body, true, true, &block
  end

  def post(url, body, headers = nil, &block)
    do_request POST, url, headers, body, true, true, &block
  end

  def put(url, body, headers = nil, &block)
    do_request PUT, url, headers, body, true, true, &block
  end

  def cleanup
    @phr.reset
    @tls_client.close
  rescue
  end

  def do_request(method, url, headers, body, request_body, response_body, &block)
    url = URL.parse(url)

    buf = make_request(method, url, headers)

    @tls_client.connect(url.host, url.port)
    @tls_client.write(buf)

    if request_body then
      send_body(body)
    else
      @tls_client.write CRLF
    end

    response, pret, buf = read_response(&block)

    return pret unless response # parser error

    read_body(response, pret, buf, &block) if response_body

    self
  ensure
    cleanup
  end

  def read_body(response, pret, buf)
    response.body = String(buf[pret..-1])
    headers = @phr.headers.to_h

    if headers.key? CONTENT_LENGTH_DC
      cl = Integer(headers[CONTENT_LENGTH_DC])
      yield response
      yielded = response.body.bytesize
      until yielded == cl
        response.body = @tls_client.read(32_768)
        yield response
        yielded += response.body.bytesize
      end
    elsif headers.key?(TRANSFER_ENCODING_DC) && headers[TRANSFER_ENCODING_DC].casecmp(CHUNKED) == 0
      unless headers.key? TRAILER_DC
        @phr.consume_trailer = true
      end
      loop do
        pret = @phr.decode_chunked(response.body)
        case pret
        when Fixnum
          yield response
          break
        when :incomplete
          yield response
          response.body = @tls_client.read(32_768)
        when :parser_error
          return pret
        end
      end
    else
      yield response
      loop do
        response.body = @tls_client.read(32_768)
        yield response
      end
    end
  end

  def read_response
    buf = @tls_client.read
    pret = nil
    response = nil

    loop do
      pret = @phr.parse_response(buf)
      case pret
      when Fixnum
        response = Response.new(@phr.minor_version,
          @phr.status, @phr.msg, @phr.headers)
        yield response
        break
      when :incomplete
        buf << @tls_client.read
      when :parser_error
        return pret
      end
    end

    return response, pret, buf
  end

  def send_body(body)
    case body
    when String
      buf = "#{CONTENT_LENGTH}#{KV_DELI}#{body.bytesize}#{CRLF}#{CRLF}"
      @tls_client.write(buf)
      @tls_client.write(body)
    when Enumerable
      buf = "#{TRANSFER_ENCODING}#{KV_DELI}#{CHUNKED}#{CRLF}#{CRLF}"
      @tls_client.write(buf)
      body.each do |chunk|
        ch = String(chunk)
        next if ch.bytesize == 0
        @tls_client.write("#{ch.bytesize.to_s(16)}#{CRLF}#{ch}#{CRLF}")
      end
      @tls_client.write(FINAL_CHUNK)
    when Fiber
      buf = "#{TRANSFER_ENCODING}#{KV_DELI}#{CHUNKED}#{CRLF}#{CRLF}"
      @tls_client.write(buf)
      while body.alive? && chunk = body.resume
        ch = String(chunk)
        next if ch.bytesize == 0
        @tls_client.write("#{ch.bytesize.to_s(16)}#{CRLF}#{ch}#{CRLF}")
      end
      @tls_client.write(FINAL_CHUNK)
    else
      raise ArgumentError, "Cannot handle #{body.class}"
    end
  end

  def make_request(method, url, headers)
    buf = "#{method}#{url.path}#{HTTP_1_1}#{CRLF}#{HOST}#{url.host}#{CRLF}"

    if headers
      headers.each do |kv|
        buf << "#{kv[0]}#{KV_DELI}#{kv[1]}#{CRLF}"
      end
    else
      buf << "#{CON_CL}#{CRLF}"
    end

    buf
  end
end
