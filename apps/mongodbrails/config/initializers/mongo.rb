services = ENV['VMC_SERVICES']
services = JSON.parse(services)
mongodb_service = services.find {|service| service["vendor"].downcase == "mongodb"}
if mongodb_service
  mongodb_service = mongodb_service["options"]
end



MongoMapper.connection = Mongo::Connection.new(mongodb_service['hostname'], mongodb_service['port'])
MongoMapper.database = mongodb_service['db']
#TODO: need to get Mongo to work in secure mode  it's required
#MongoMapper.database.authenticate(mongodb_service['login'], mongodb_service['secret'])

#if defined?(PhusionPassenger)
#   PhusionPassenger.on_event(:starting_worker_process) do |forked|
#     MongoMapper.connection.connect_to_master if forked
#   end
#end



#MongoMapper.database = 'db'
