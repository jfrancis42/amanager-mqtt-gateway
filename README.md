#Summary

mqtt_gateway is a piece of software that translates between Arduino Manager's (also called AManager) proprietary protocol and MQTT.

#Description

##MQTT

I'll start with ripping off from [the wikipedia article](https://en.wikipedia.org/wiki/MQTT):  "MQTT (formerly Message Queue Telemetry Transport) is a publish-subscribe based "light weight" messaging protocol for use on top of the TCP/IP protocol. It is designed for connections with remote locations where a small code footprint is required and/or network bandwidth is limited."  MQTT is very common, and clients have been written for everything from Arduinos on up to full server-class operating systems.  It's something akin to [SCADA](https://en.wikipedia.org/wiki/SCADA) reinvented for the Internet of Things.  It's use is growing by leaps and bounds, and it's the new standard for passing telemetry for everything from chat clients to burglar alarms to process control to aerospace telemetry.  It's simple enough to run on a 300baud async serial connection to a full IP stack.

##Arduino Manager (AManager)

Arduino Manager is the most wicked cool piece of software you’ve never heard of (website is [here](https://sites.google.com/site/fabboco/home/arduino-manager-for-iphone-ipad)).  It’s a very pretty dashboard that’s completely customizable that talks to an [Arduino](http://www.arduino.cc/) over an IP network.  It basically turns the Arduino into a remote-controlled I/O device.  From the AManager app, you can add virtual switches, graphs, LEDs, meters, etc., and label them as you wish.  Then you assign a pin on the Arduino to each item on the dashboard.  Finally, you click the “generate code” button, and the app spews a bunch of C code that you paste into your Arudino editor, compile, and burn onto your Arduino board.  You’ve now got a virtual control panel or console that can remotely control and read pins on an Arduino board.  There's also a version for the Mac that's quite similar, though considerably buggier.  AManager uses a simple proprietary protocol to communicate between the app and the Arduino.

##The Problem

The problem is that there is nothing remotely like the AManager app for MQTT.  There are some useful tools, many of them quite well implemented, but they're all tools for debugging and doing detailed traces of telemetry data.  There's nothing even remotely like a dashboard like AManager supplies.  Unfortunately, as beautiful and useful is AManager is, it doesn't speak MQTT.  The goal of mqtt_gateway is to marry the two technologies, allowing the use of the AManager app to monitor and control the endless variety of things available via MQTT, and not limited to the twenty I/O pins of a single Arduino device.

#mqtt_gateway

##What Services Does mqtt_gateway Provide?

mqtt_gateway provides translation, throttling, and caching services between MQTT and the proprietary AManager protocols.

###Translation

The AManager protocol is extremely simple.  It consists of ASCII strings containing a variable name, an equals sign, and a value, with a termination hash character carried as the payload of a TCP packet.  For example, the following string contains a variable named "temp" which is set to the value 69.0:

```
temp=69.000#
```

Multiple values can be strung together in a single TCP transaction, like this:

```
temp1=42#temp2=69#
```

Also, the value "1" represents "on" (for switches and LEDs), and "0" represents "off".  That's it, pretty simple.  Values sent from AManager to the Arduino are used to set pins, and values sent from the Arduino to AManager are used to display data (on virtual LEDs, meters, LCD displays, etc).  Normally, a user controls knobs, switches, and sliders, however, a virtual switch, knob, or slider created in AManager can have it's value pre-set (or reset at any time) by setting it's variable name just like any display widget.  This allows for multiple users all with the same switch or button, and it allows the software to pre-set some default control settings, or reset them to the values they were left at when the app was last run.  For example, to pre-set a switch named "light1" to 
"on", the Arduino would send the following string to the app:

```
light1=1#
```

When the AManager app connects to the Arduino after disconnect or app termination, it sends two items after successful TCP connection:  The current time/date (expressed as epoch time) and a list of switches, knobs, and sliders, so that the Arduino has the option of pre-setting those values before the users begins using the interface.  These are sent as follows:

```
$Time=1411603667#
Sync=switch1#Sync=knob2#Sync=slider3#
```

The Arduino may optionally reply by setting the values of each control listed as a "Sync" variable (it may also set them at any arbitrary future time).

MQTT is very free-form, and allows any arbitrary data to be sent on a "topic".  A topic may be thought of as a channel.  Any data sent by a publisher to a topic is received by all subscribers to that topic.  A client may be both a publisher and a subscriber on the same (or any) topics at the same time.  The philosophy of mqtt_gateway is to require all transactions to be on a single topic, and all transactions will be of the form "variable=value".  The most simple service provided by mqtt_gateway is to receive MQTT data, "bundle" it (multiple variables per TCP packet) for efficiency, add the appropriate hash marks, and forward them to the AManager app.  Likewise, it receives variables (possibly "bundled") from the app, and dispenses them one at a time as MQTT data to the specified topic to all subscribers.

###Throttling

AManager is a smartphone app, and as such, it often connects via a cell network.  Cell data is often of limited bandwidth, of high latency (and often high jitter, as well), and rarely inexpensive.  As such, it's prudent to limit the amount of bandwidth used to the minimum amount to satisfy monitoring and control requirements.  MQTT data, on the other hand, can be almost anything at almost any speed.  GPS data might update at 1hz, while temperature measurements might be flowing in 10hz, while RPM measurements are being updated at 100hz.  Rarely is this volume of data needed for human monitoring and control of a process (and if it is, using a $10 iPhone app over a cell network is probably not your best choice).  A way is needed to "smooth out" this data into something usable by humans.  This is solved in mqtt_gateway by comparing the value of each variable received over MQTT with it's previous value.  If they are the same, no data is sent to the AManager app.  Only when a variable changes is the new value sent to the app (with the exception of caching, described next).  For most data, this vastly cuts the amount of data to be transferred.  In experiments done to date, most data is reduced to about 1% of the "full bore" amount, though obviously this varies a great deal based on what kind of data is being sent.  Throttling, in this case, is the logical equivalent of compression, and data with less noise or entropy will "compress" more than "clean and quiet" data.

###Caching

Throttling is good, in terms of controlling the amount of data transferred via cell network, but introduces problems, as well.  If a data point is sent only once every sixty seconds, a user might have to wait up to 59.999 seconds to see that data represented on his AManager screen (assuming that data point is not a duplicate of the previous data point).  Consequently, mqtt_gateway caches values, and sends them at regular intervals, whether or not they've been updated, up to an expiration time.  If the variable has not been updated when that expiration time expires, the values is dropped from the cache.  This prevents long-term false indications of a variable's value (or the existence of that variable).

Also, consider the case where both Alice and Bob are controlling a light bulb.  The both have a switch in their AManager clients labeled "light".  Alice starts her client and turns on the light.  Then Bob starts his client.  Since he missed the event from Alice, he now doesn't know if the light is on or off.  His switch indicates that it's off, but it has never received a value to tell it otherwise.  The only way for Bob to truly know the status of the bulb is to turn it on himself.  Which can cause obvious problems if the bulb shouldn't be on.  mqtt_gateway caches switch, knob, and slider settings indefinitely.  There is no timeout in the cache.  These values are pushed regularly, so that users who have just connected will receive timely status updates on their switch settings.  When a new AManager client is detected (by virtue of the "Sync=x" queries), the switch values are prioritized to be updated as quickly as possible from the cache.

##What Are the Requirements to Run mqtt_gateway?

mqtt_gateway is written in ruby, and has been tested on Linux and OS/X.  It's likely to run as-is (or with few modifications) on Windows.  At present, only one gem is required:

```
sudo gem install mqtt
```

##How Do I Run mqtt_gateway?

You'll need to specify some options on the command line.  At a minimum, you need to specify an MQTT server and a topic:

```
./mqtt_gateway.rb --mqtt mqtt.server.com --topic mydata
```

The rest of the parameters are usually fine using the defaults.

##What Are the Caveats/Problems/Shortcomings of mqtt_gateway?

There are a number of shortcomings of this code (again, it was originally written to solve my own personal use case, not as a full-blown application).  Specifically:

1. The mqtt_gateway will only accept a connection from one AManager app at a time.  This is high on the list of things to change, but for the moment, if you want more than one client, you have to run more than one gateway, and put each on a different TCP port (4444, 4445, 4446, etc).
2. All MQTT traffic is published and subscribed to on a single fixed topic.
3. All traffic on the MQTT side must be of the form "var_name=value".  Simple raw values ("123") won't cause an error, but they won't do anything useful, either.
4. It's probably wise to use a sitter in cron to make sure the client gets restarted if it dies.
5. It doesn't always correctly detect the disconnect of AManager immediately.  It often takes 15-30 seconds before it realizes the client is gone and is ready to accept a new connection.
6. There is currently no provision for authentication to the MQTT server.  This will change, but the current version of code requires an open MQTT server (mosquitto works great).
