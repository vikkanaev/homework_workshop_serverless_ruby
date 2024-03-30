require 'uri'
require 'net/http'
require 'json'
require 'aws-sdk-s3'

def lambda_handler(event:, context:)
  payload = parse_event(event)

  if payload[:command]
    puts 'Sending default reply ¯\_(ツ)_/¯'
    result = default_reply(payload)
  else
    query = payload[:query]
    puts "Searching for query: #{query}"

    result = read_from_s3(query)
    if result.nil?
      puts "No cache found for query: #{query}"

      data = search_movie(query)
      movies = parse_movies(data)

      movie = movies.first
      result = format_reply(payload, movie)
      persist_to_s3(query, result) if result[:img_url]
      puts "Persisted cache for query: #{query}"
    else
      puts "Cache found for query: #{query}"
    end
  end

  reply2bot(payload[:chat_id], result)
rescue StandardError => e
  puts "Error: #{e}"
ensure
  {
    statusCode: 200,
    body: {
      message: 'ok'
    }
  }
end

private

def parse_event(event)
  body = JSON.parse(event['body']) || {}
  message = body['message']

  text = message['text']
  match = text&.match(%r{^/search (.*)})&.[](1)

  if match
    query = match
    command = false
  elsif text&.start_with?('/')
    query = nil
    command = true
  else
    query = text
    command = false
  end

  {
    chat_id: message['chat']['id'],
    query: query,
    command: command,
    first_name: message['from']['first_name']
  }
end

def search_movie(query)
  url = URI("https://api.themoviedb.org/3/search/movie?query=#{query}&include_adult=false&language=en-US&page=1")
  token = ENV['THEMOVIEDB_API_KEY']

  http = Net::HTTP.new(url.host, url.port)
  http.use_ssl = true

  request = Net::HTTP::Get.new(url)
  request['accept'] = 'application/json'
  request['Authorization'] = "Bearer #{token}"

  response = http.request(request)

  data = response.read_body

  JSON.parse(data)
rescue URI::InvalidURIError
  {}
end

def parse_movies(data)
  return [] if data['results'].nil?

  data['results'].map do |movie|
    {
      title: movie['title'],
      release_date: movie['release_date'],
      poster_path: movie['poster_path'],
      overview: movie['overview']
    }
  end
end

def format_reply(payload, movie)
  res = "Hello, #{payload[:first_name]}! Your query: #{payload[:query]}"
  res += "\n\nResult:\n"

  img_url = "https://image.tmdb.org/t/p/w200/#{movie[:poster_path]}" unless movie.nil?
  res += if movie.nil?
           'No results found.'
         else
           "#{movie[:title]} (#{movie[:release_date]})\n\n#{movie[:overview]}"
         end

  {
    img_url: img_url,
    text: res
  }
end

def default_reply(payload)
  {
    text: "Hello, #{payload[:first_name]}! I'm a bot that can help you search for movies. Just type the name of the movie you're looking for."
  }
end

def reply2bot(chat_id, result)
  img_url = result[:img_url]
  method = img_url.nil? ? 'sendMessage' : 'sendPhoto'
  body = {
    method: method,
    chat_id: chat_id
  }
  if method == 'sendPhoto'
    body.merge!({ photo: img_url, caption: result[:text] })
  else
    body.merge!({ text: result[:text] })
  end

  {
    statusCode: 200,
    body: body
  }
end

def s3
  @s3 ||= Aws::S3::Client.new
end

def persist_to_s3(query, result)
  s3.put_object(
    bucket: ENV['MOVIES_BUCKET'],
    key: "#{query.downcase}.json",
    body: result.to_json
  )
end

def read_from_s3(query)
  resp = s3.get_object(
    bucket: ENV['MOVIES_BUCKET'],
    key: "#{query.downcase}.json"
  )
  data = resp&.body&.read&.to_s
  return if data.nil?

  JSON.parse(data).map { |k, v| [k.to_sym, v] }.to_h
rescue Aws::S3::Errors::AccessDenied
  nil
end
