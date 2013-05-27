require 'rubygems'
require 'sinatra'

get '/' do
  'sinatra app'
end

get '/hello' do
  'hello, world'
end

get '/crash' do
  $suicide = Thread.new do
    sleep 1
    exit!
  end
  'seppuku'
end

get '/data/:size' do
  'x' * params[:size].to_i
end

put '/data' do
  data = request.body.read.to_s
  "received #{data.length} bytes"
end
