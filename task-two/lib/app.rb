require 'uri'
require 'net/http'
require 'json'
require 'aws-sdk-dynamodb'
require 'digest'

TTL = 7 * 24 * 60 * 60 # 7 days

def lambda_handler(event:, context:)
  payload = parse_event(event)

  if payload[:command]
    puts 'Sending default reply ¯\_(ツ)_/¯'
    result = default_reply(payload)
  else
    query = payload[:query]
    puts "Searching for query: #{query}"

    movie = load_from_dynamodb(query)
    movie = validate_ttl(movie)
    result = format_reply(payload, movie) unless movie.nil?

    if result.nil?
      puts "No cache found for query: #{query}"

      data = search_movie(query)
      movies = parse_movies(data)

      movie = movies.first
      result = format_reply(payload, movie)
      persist(query, movie) if result[:img_url]
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
      overview: movie['overview'],
      timestamp: Time.now.to_i + TTL
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

def persist(query, movie)
  search_string = query.downcase.strip
  item = movie.merge({ id: digest(search_string), query: search_string })

  resp = dynamodb.put_item(
    table_name: ENV['DYNAMODB_TABLE'],
    item: item,
    return_consumed_capacity: 'TOTAL'
  )
end

def load_from_dynamodb(query)
  search_string = query.downcase.strip

  resp = dynamodb.get_item(
    table_name: ENV['DYNAMODB_TABLE'],
    key: { id: digest(search_string) }
  )

  puts "DynamoDB response: #{resp}"
  item = resp.item
  return nil if item.nil?

  item.transform_keys(&:to_sym)
end

def dynamodb
  @dynamodb ||= Aws::DynamoDB::Client.new
end

def digest(str)
  Digest::MD5.hexdigest str
end

# Be cautious that DynamoDB does not delete expired items immediately.
# That's why we are handling the TTL validation in the code.
def validate_ttl(movie)
  return nil if movie.nil?

  puts "Validating TTL for movie: #{movie['title']}"
  ttl = movie[:timestamp].to_i

  if ttl < Time.now.to_i
    puts 'TTL is invalid'
    return nil
  end

  puts 'TTL is valid'
  movie
end
