require 'rubygems'
require 'sinatra'

$suicide = Thread.new do
  sleep 5
  exit!
end

get '/' do
  'sinatra app'
end

get '/hello' do
  'hello, world'
end

get '/data/:size' do
  'x' * params[:size].to_i
end

put '/data' do
  data = request.body.read.to_s
  "received #{data.length} bytes"
end
