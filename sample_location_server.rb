#!/usr/bin/ruby1.9
#
# Capture events from Meraki CMX Location Push API, Version 1.0.
#
# DISCLAIMERS:
#
# 1. This code is for sample purposes only. Before running in production,
# you should probably add SSL/TLS support by running this server behind a
# TLS-capable reverse proxy like nginx.
#
# 2. You should also test that your server is capable of handling the rate
# of events that will be generated by your networks. A good rule of thumb is
# that your server should be able to process all your network's nodes once per
# minute. So if you have 100 nodes, your server should respond to each request
# within 600 ms. For more than 100 nodes, you will probably need a multithreaded
# web app.
#
# To use this webapp:
#   - Ensure that you have ruby 1.9.3
#   - Ensure that you have set up a Redis instance and saved its URL
#     as the environment variable REDIS_URL
#   - Ensure that you have the validator and secret saved as 
#     VALIDATOR and SECRET environment variables (more below)
#   - Set up your database and put it's URL in the DATABASE_URL
#     environment variable  
#   - If you are not running with Heroku, run 'bundle install' to ensure your 
#     machine has the required gems.
#
# Let's say you plan to run this server on a host called pushapi.example.com.
# Go to Meraki's Dashboard and configure the CMX Location Push API with the url
# "http://pushapi.example.com:4567/events", choose a secret, and make note of
# the validation code that Dashboard provides. This secret and validator should
# be set in the environment variables SECRET and VALIDATOR.
#
# Now click the "Validate server" link in CMX Location Push API configuration in
# Dashboard. Meraki's servers will perform a get to this server, and you will
# see a log message like this:
#
#   [26/Mar/2013 11:52:09] "GET /events HTTP/1.1" 200 6 0.0024
#
# If you do not see such a log message, check your firewall and make sure
# you're allowing connections to port 4567. You can confirm that the server
# is receiving connections on the port using
#
#   telnet pushapi.example.com 4567
#
# Once Dashboard has confirmed that the URL you provided returns the expected
# validation code, it will begin posting events to your URL. The events are
# encapsulated in a JSON post of the following form:
#
#   {"secret":<push secret>,"version":"2.0","type":"DevicesSeen","data":<data>}
#
# The "data" field is composed of the CMX data fields. For example:
#
#   {
#     "apFloors":"San Francisco>500 TF>5th"
#     "apMac":"11:22:33:44:55:66",
#     "observations":[
#       {
#         "clientMac":"aa:bb:cc:dd:ee:ff",
#         "seenTime":"1970-01-01T00:00:00Z",
#         "seenEpoch":0,
#         "ipv4":"/123.45.67.89",
#         "ipv6":"/ff11:2233:4455:6677:8899:0:aabb:ccdd",
#         "rssi":24,
#         "ssid":"Cisco WiFi",
#         "manufacturer":"Meraki",
#         "os":"Linux",
#         "location":{
#           "lat":37.77057805947924,
#           "lng":-122.38765965945927,
#           "unc":15.13174349529074
#         }
#       },...
#     ]
#   }
#
# This app will then begin logging the received JSON in a human-readable format.
# For example, when a client probes one of your access points, you'll see a log
# message like this:
#
#   [2013-03-26T11:51:57.920806 #25266]  INFO -- : AP 11:22:33:44:55:66 on ["5th Floor"]:
#   {"ipv4"=>"123.45.67.89", "location"=>{"lat"=>37.77050089978862, "lng"=>-122.38686903158863, 
#   "unc"=>11.39537928078731}, "seenTime"=>"2014-05-15T15:48:14Z", "ssid"=>"Cisco WiFi",
#   "os"=>"Linux", "clientMac"=>"aa:bb:cc:dd:ee:ff",
#   "seenEpoch"=>1400168894, "rssi"=>16, "ipv6"=>nil, "manufacturer"=>"Meraki"} 
#
# After your first client pushes start arriving (this may take a minute or two),
# you can get a JSON blob describing the last client probe using:
#
#   pushapi.example.com:4567/clients/{mac}
#
# where {mac} is the client mac address. For example,
#
#   http://pushapi.example.com:4567/clients/aa:bb:cc:dd:ee:ff
#
# may return
#
#   {"id":65,"mac":"aa:bb:cc:dd:ee:ff","seenAt":"2014-05-15T15.48.14Z",
#   "lat":37.77050089978862,"lng":-122.38686903158863,"unc":11.39537928078731,
#   "manufacturer":"Meraki","os":"Linux","floors":["5th Floor"]}
#
# You can also view the sample frontend at
#
#   http://pushapi.example.com:4567/
#
# Try connecting your mobile to your network, and entering your mobile's WiFi MAC in
# the frontend.

require 'rubygems'
require 'sinatra'
require 'resque'
require 'digest/sha1'
require_relative 'job'

# ---- Set up Sinatra -----

# zip content when possible
use Rack::Deflater

if ENV['SECRET'] && ENV['VALIDATOR']
  SECRET = ENV['SECRET']
  VALIDATOR = ENV['VALIDATOR']
else
  puts "Environment variables VALIDATOR and SECRET required."
  exit 1
end

# ---- Load anonimization data --------

# NAMES = CSV.read("initials.csv")
# puts "Loaded #{NAMES.length} names"

# ---- Set up the database -------------

# Creates schema defined in db_setup.rb in your database
# WARNING: Drops your tables to create schema, use 'auto_upgrade!'
# if you want to keep your tables
DataMapper.auto_migrate!

# ---- Set up routes -------------------

# Serve the frontend.
get '/' do
  send_file File.join(settings.public_folder, 'index.html')
end

# This is used by the Meraki API to validate this web app.
# In general it is a Bad Thing to change this.
get '/events' do
  VALIDATOR
end

# Return the distinct values for floors
# This is used to populate the floors dropdown
get '/floors' do
  floors = repository(:default).adapter.select('select distinct floors from clients')
  JSON.generate(floors)
end

# Respond to Meraki's push events. Here we're just going
# to write the most recent events to our database.
post '/events' do
  if request.media_type != "application/json"
    logger.warn "got post with unexpected content type: #{request.media_type}"
    return
  end
  request.body.rewind
  Resque.enqueue(LocationData, request.body.read)
  ""
end

# This matches
#    /clients/<mac>
# and returns a client with a given mac address, or empty JSON
# if the mac is not in the database.
get '/clients/:mac' do |m|
  name = m.sub "%20", " "
  puts "Request name is #{name}"
  content_type :json
  client = Client.first(:mac => name)
  logger.info("Retrieved client #{client}")
  client != nil ? JSON.generate(client) : "{}"
end

# This matches
#   /clients OR /clients/
# and returns a JSON blob of all clients.
# Optional query parameters eventType and floors can be used to 
# filter the clients
get %r{/clients/?} do
  query = {:seenEpoch.gt => (Time.new - 900).to_i}
  if params[:eventType] and params[:eventType] != "All"
    query[:eventType] = params[:eventType]
  end

  if params[:floors] and params[:floors] != "All"
    query[:floors] = params[:floors]
  end

  if Client.count >= 6000
    logger.warn "Number of rows above 6000. Deleting all rows."
    Client.destroy
  end

  content_type :json
  clients = Client.all(query) #Client.all(:seenEpoch.gt => (Time.new - 300).to_i)
  JSON.generate(clients)
end

