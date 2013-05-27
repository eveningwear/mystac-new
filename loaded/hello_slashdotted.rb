require 'loadspec'
require 'fileutils'
include FileUtils

app_name = "foo"
instances = 1
HttpLoad.set_default_url = 'foo.b29.me'

vmc 'push', app_name

# load on app gradually escalates
http_load :rate => 1, :duration => 120
http_load :rate => 5, :duration => 120
http_load :rate => 99, :duration => 120

#increase in num instances
vmc 'instances', app_name, 10

# dev replaces original app with a buggy one
cd 'buggy'
vmc 'push', app_name
cd ..

http_load :rate => 99, :duration =>  60
http_load :rate => 33, :duration =>  60

# dev grabs crash info and logs from a few semi-random instances
[1,3,5,7].each { |instance|
    vmc 'crashlogs', app_name, '--instance', |instance|
}

# dev deploys a fixed app, users notice and start banging on it again
vmc 'push',app_name

vmc 'instances', app_name, 20

http_load :rate => 66, :duration =>  60
http_load :rate => 99, :duration => 120,
vmc 'instances', app_name, 40

http_load :rate=> 55, :duration => 120

# dev starts running short on credit to pay for his silly app; reduce instances
vmc 'instances', app_name, 15

http_load :rate=> 80, :duration => 120

# word gets out that this app doesn't scale, users leave in droves
http_load :rate =>  33, :duration =>  60

# dev gives up on the cloud and seeks employment as fast food cook
vmc 'delete',app_name

