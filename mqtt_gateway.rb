#!/usr/bin/ruby
# -*- coding: utf-8 -*-

# Jeff Francis, N0GQ, jeff@gritch.org
# http://www.gritch.org/amanager/
#
# mqtt_gateway is a piece of software that translates between Arduino
# Manager's (also called AManager) proprietary protocol and MQTT.
#
# 25.September.2014
#
# You'll need two gems that aren't part of the default ruby distro to
# use this software: mqtt and trollop.
#
# On Linux/BSD/OSX boxes, you can install them like this:
#
# sudo gem install mqtt
# sudo gem install trollop

# This sets up all of our default options.
DEBUG=false
QUEUE=false
max_at_once=6
max_old_send=3
discard_age=300
update_age=30
$port=4444
$stash_file=nil

# We need these gems to work.  These are built in...
require 'socket'
require 'time'
require 'yaml'

# ...and these are not.
require 'mqtt'
require 'trollop'

# Process the options.
opts=Trollop::options do
  opt :mqtt, "MQTT Server", :type => :string
  opt :topic, "MQTT Topic", :type => :string
  opt :port, "TCP port to listen for AManager connections (default 4444)", :type => :string
  opt :batch, "Maximum variable updates to AManager per transaction (default 6)", :type => :string
  opt :old, "Maximum old variables to refresh per transaction (default 3)", :type => :string
  opt :update, "Maximum age in seconds to resend old variable (default 30)", :type => :string
  opt :discard, "Maximum age in seconds to discard non-updated variables (default 300)", :type => :string
  opt :yaml, "Cache current status in a YAML file", :type => :string
  opt :debug, "Show extra debug info (not useful for most users)"
  opt :queue, "Dump the queue to STDOUT every few seconds (very verbose)"
end

# Override default discard time.
if opts[:discard_given]
  discard_age=opts[:discard].to_i
end

# Override default update time.
if opts[:update_given]
  update_age=opts[:update].to_i
end

# Override max number of old messages sent.
if opts[:old_given]
  max_old_send=opts[:old].to_i
end

# Override default max number of variables per transaction.
if opts[:batch_given]
  max_at_once=opts[:batch].to_i
end

# Turn on debug mode.
if opts[:debug_given]
  DEBUG=TRUE
end

# Turn on super-debug mode (queue dumping).
if opts[:queue_given]
  QUEUE=TRUE
end

# Specify the name of the mqtt server.
if opts[:mqtt_given]
  $server=opts[:mqtt]
else
  puts "--mqtt is mandatory"
  exit
end

# Specify the name of the topic.
if opts[:topic_given]
  $topic=opts[:topic]
else
  puts "--topic is mandatory"
  exit
end

# Specify the port to listen on.
if opts[:port_given]
  $port=opts[:port].to_i
end

# Specify the name of the YAML dump file.
if opts[:yaml_given]
  $stash_file=opts[:yaml]
end

$rxmutex=Mutex.new
$rx=nil
$send=Array.new

# Serialize an object as YAML.
def write_object_as_yaml(filename, object)
  File.open(filename, 'w') do |io|
    YAML::dump(object, io)
  end
end

# Deserialize a YAML object.
def read_object_from_yaml(filename, default={})
  return default unless File.exists? filename
  File.open(filename) do |io|
    return YAML::load(io)
  end
end

# This class holds all the MQTT variable info.
class Thing
  attr_accessor :name, :value, :rtime, :stime, :updated, :phoneset

  def initialize(name, value, rtime)
    @name = name.to_s
    @value = value
    @rtime = rtime
    @stime = 0
    @updated = true
    @phoneset = false
  end

  def to_s
    "Name: #{@name}\nValue: #{@value}\nReceived: #{@rtime.to_s}\nSent: #{@stime.to_s}\nUpdated: #{@updated}\nPhone-Set: #{@phoneset}"
  end

  def to_s_short
    "#{@name} #{@value} #{@rtime.to_i} #{@stime.to_i} #{@updated} #{@phoneset}"
  end
end

# This hash holds all of the Thing objects.
data=Hash.new

# Recalculate and update the queue depth every n seconds.
def calc_queue(n)
  depth=0
  # Wait one "cycle" to start.
  sleep n
  loop {
    $rxmutex.synchronize {
      depth=0
      $rx.each_key do |key|
        if $rx[key].updated
          depth=depth+1
        end
      end
    }
    if !$rx.has_key?('Q')
      $rx['Q']=Thing.new('Q',0,Time.now())
    end
    $rx['Q'].value=depth
    $rx['Q'].updated=true
    puts "Queue:  #{depth}" if DEBUG
    if QUEUE
      $rx.each_key do |key|
        puts "#{key} #{$rx[key].to_s_short}"
      end
    end
    # Stash our current state.
    if $stash_file
      write_object_as_yaml($stash_file, $rx)
    end
    sleep n
  }
end

# Subscribe to the given channel and update the data structure as new
# values come in.
def mqtt_sub(myserver, mytopic)
  puts "mqtt_sub() thread started..." if DEBUG
  MQTT::Client.connect(myserver) do |mqtt|
    puts "mqtt_sub() thread connected..." if DEBUG
    mqtt.get(mytopic) do |topic,rxmsg|
      now=Time.now()
      this,that=rxmsg.split('=')
      $rxmutex.synchronize {
        if $rx.has_key?(this)
          $rx[this].rtime=now
          if $rx[this].value==that
            puts "Redundant value: #{rxmsg}" if DEBUG
          else
            puts "New value: #{rxmsg}" if DEBUG
            $rx[this].updated=true
            $rx[this].value=that
          end
        else
          puts "New variable: #{rxmsg}" if DEBUG
          $rx[this]=Thing.new(this, that, now)
        end
      }
    end
  end
end

# Start the queue depth thread.
qthread=Thread.new { calc_queue(5) }
qthread.abort_on_exception=true

# Start the MQTT subscriber thread.
subthread=Thread.new { mqtt_sub($server, $topic) }
subthread.abort_on_exception=true

# And here we go with the main thread. Run forever. Well, or until
# something breaks...
loop {
  $rx=Hash.new
  if $stash_file
    $rx=read_object_from_yaml($stash_file) if File.exist?($stash_file)
  end

  # Listen for AManager to connect, then start processing data.
  a=TCPServer.new(nil,$port)
  connection=a.accept
  client_connected=true

  # This is for sending stuff from the phone to MQTT.
  MQTT::Client.connect($server) do |c|

    # Loop forever (or at least until the app closes/sleeps).
    while client_connected do
      # Is there data waiting for us (from the phone)?
      ready=IO.select([connection],nil,nil,1)

      # Process stuff sent by the phone.  Just sent it as it comes, no
      # need for the cool buffering like on $rx.
      if ready
        r=connection.recv(1024).split('#')
        if r.length>0
          puts "phone sent: " + r.join('#') + '#' if DEBUG
          r.each do |n|
            (name,value)=n.split('=')
            if name=="Sync"
              # This is special. "Wake up" any values asked for by the
              # phone (they're syncing state, so the sooner we send
              # it, the sooner the switches on the phone will sync up
              # and show the right values). We set the sent time to
              # zero, the received time to now, and updated to true to
              # ensure that these values go to the top of the list of
              # things to send.
              puts "sync: #{name}=#{value}" if DEBUG
              if $rx.has_key?(value)
                $rxmutex.synchronize {
                  $rx[value].rtime=Time.now()
                  $rx[value].stime=0
                  $rx[value].updated=true
                }
              end
            else
              # If the user sends data from the phone, throw it in the
              # queue at high priority for sending. Also, note that
              # it's from the phone (this makes it immune from
              # purging).
              puts "sending: #{n}" if DEBUG
              tmp_msg="#{name}=#{value}"
              c.publish($topic, tmp_msg)
              if $rx.has_key?(name)
                $rxmutex.synchronize {
                  $rx[name].rtime=Time.now()
                  $rx[name].stime=0
                  $rx[name].value=value
                  $rx[name].updated=true
                  $rx[name].phoneset=true
                }
              else
                $rxmutex.synchronize {
                  $rx[name]=Thing.new(name,value,Time.now())
                }
              end
            end
          end
        end
      end
      
      # Loop through our Thing data structure and send what needs sending.
      send_msg=""
      $rxmutex.synchronize {
        
        now=Time.now()

        # First, throw away stuff that's really old (the value hasn't
        # been updated in discard_age seconds). Values sent from the
        # phone are immune from discarding.
        $rx.each_key do |key|
          if now.to_i-$rx[key].rtime.to_i>discard_age and !$rx[key].phoneset
            $rx.delete(key)
          end
        end

        # Now make a list of data that's newer than discard_age, but
        # hasn't been sent to the phone in at least update_age seconds,
        # but doesn't contain an updated value (ie, a list of stuff to
        # re-send the old values to the phone for to keep the phone screen
        # updated).
        old=Hash.new
        $rx.each_key do |key|
          if now.to_i-$rx[key].stime.to_i>update_age
            old[key]=true
          end
        end
        puts "#{old.length} old values to send" if DEBUG

        # Finally, make a list if data that's got new values (the stuff
        # that's changed since the last time we sent it).  These values
        # get priority in the sending queue.
        updated=Hash.new
        $rx.each_key do |key|
          if $rx[key].updated
            updated[key]=true
          end
        end
        puts "#{updated.length} updated values to send" if DEBUG
        
        # Now figure out what we're actually going to send to the phone
        # and send it.  This gets complicated.  We can send a maximum of
        # max_at_once values per update to the phone.  If the sum of old
        # and updated values to be sent is less than or equal to this, we
        # send everything.  Otherwise, data gets sent based on space
        # available, with priority going to new data (but old data always
        # gets up to max_old_send slots).
        send_count=0
        send_msg=""
        oldcount=old.length
        updatedcount=updated.length
        
        # Easy case first.  If the total count <= the maximum allowed,
        # just send everything.
        if oldcount+updatedcount<=max_at_once
          updated.each_key do |key|
            send_msg=send_msg+key+"="+$rx[key].value.to_s+"#"
            $rx[key].stime=now
            $rx[key].updated=false
            send_count=send_count+1
          end
          old.each_key do |key|
            send_msg=send_msg+key+"="+$rx[key].value.to_s+"#"
            $rx[key].stime=now
            $rx[key].updated=false
            send_count=send_count+1
          end
        else
          # If that's not the case, break it down and send some of each.

          # First, send up to max_old_send old messages.
          if oldcount>0
            old.each_key do |key|
              if send_count<max_old_send
                send_msg=send_msg+key+"="+$rx[key].value.to_s+"#"
                $rx[key].stime=now
                $rx[key].updated=false
                send_count=send_count+1
                oldcount=oldcount-1
                old.delete(key)
              end
            end
          end

          # Now add new messages until we either run out of them, or reach
          # maximum message length.
          if updatedcount>0
            updated.each_key do |key|
              if send_count<max_at_once
                send_msg=send_msg+key+"="+$rx[key].value.to_s+"#"
                $rx[key].stime=now
                $rx[key].updated=false
                send_count=send_count+1
              end
            end
          end

          # Finally, if there's any space left, send more old messages (if
          # there are any).
          if oldcount>0 and send_count<max_at_once
            old.each_key do |key|
              if send_count<max_at_once
                send_msg=send_msg+key+"="+$rx[key].value.to_s+"#"
                $rx[key].stime=now
                $rx[key].updated=false
                send_count=send_count+1
                old.delete(key)
              end
            end
          end

        end
      }

      # Send the data to the phone (if any).
      if send_msg.length>0
        puts "->#{send_msg}<-" if DEBUG
        begin
          connection.write(send_msg)
        rescue Errno::EPIPE
          puts "Client disconnected..." if DEBUG

          # Close open stuff.
          connection.close
          a.close

          # Write the latest data to the file.
          if $stash_file
            write_object_as_yaml($stash_file, $rx)
          end

          # Tell the loop to start over.
          client_connected=false
        end
      end
    end
  end
}
