#!/usr/bin/ruby

DEBUG=false
QUEUE=false

max_at_once=6
max_old_send=3
discard_age=300
update_age=30

require 'socket'
require 'mqtt'
require 'time'
require 'yaml'

$stash_file="/tmp/mqtt.yaml"

$rxmutex=Mutex.new
$rx=nil

$send=Array.new

creds=YAML.load(File.read("/home/jfrancis/creds.yaml"))

def write_object_as_yaml(filename, object)
  File.open(filename, 'w') do |io|
    YAML::dump(object, io)
  end
end

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
    write_object_as_yaml($stash_file, $rx)
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
subthread=Thread.new { mqtt_sub(creds['mqtthost'], creds['mqtttopic']) }
subthread.abort_on_exception=true

loop {
  $rx=Hash.new
  $rx=read_object_from_yaml($stash_file) if File.exist?($stash_file)

  # Listen for AManager to connect, then start processing data.
  a=TCPServer.new(nil,4444)
  connection=a.accept
  client_connected=true

  # This is for sending stuff from the phone to MQTT.
  MQTT::Client.connect(creds['mqtthost']) do |c|

    # Loop forever (or at least until the app closes/sleeps).
    while client_connected do
      # Is there data waiting for us (from the phone)?
      ready=IO.select([connection],nil,nil,1)

      # Process stuff sent by the phone.  Just sent it as it comes, no
      # need for the cool buffering like on $rx.  Still some bugs
      # here. TODO: fix them.
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
              c.publish(creds['mqtttopic'], tmp_msg)
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
          write_object_as_yaml($stash_file, $rx)

          # Tell the loop to start over.
          client_connected=false
        end
      end
    end
  end
}
