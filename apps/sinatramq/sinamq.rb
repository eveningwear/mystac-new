require 'rubygems'
require 'sinatra'
require 'json'
require 'amqp'

enable :sessions

get '/init' do
  content_type :json
  rabbit_service = rabbit_services
   AMQP.start(:host => "#{rabbit_service['hostname']}", :port => "#{rabbit_service['port']}") do |connection|
    channel = AMQP::Channel.new(connection)
    producer = channel.fanout('task')

    10.times do |i|
      producer.publish(Marshal.dump("#{Time.now.to_s}"))
    end

    channel2 = AMQP::Channel.new(connection)
    exchange = channel2.fanout('task')

    q1 = channel2.queue('every second')
    q1.bind(exchange).subscribe { |msg|
      puts msg
      session['queued_msgs'] << msg
    }
    EventMachine::add_timer 1 do
      connection.close { EM.stop{} } unless connection.closing?
    end
  end
  content_type :json
  ''.to_json
end

get '/read_from_queue' do
  content_type :json
  session.to_json
end

get '/env' do
  content_type :json
  rabbit_service = rabbit_services
  rabbit_service.to_json
end


def rabbit_services
  services = ENV['VMC_SERVICES']
  services = JSON.parse(services)
  rabbit_service = services.find {|service| service["vendor"].downcase == "rabbitmq"}
  if rabbit_service
    rabbit_service = rabbit_service["options"]
  end
  rabbit_service
end

