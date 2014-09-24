amanager-mqtt-gateway
=====================

Gateway data between Arduino Manager and MQTT


**This is a preliminary README (basically cut and pasted from my blog page where I first mentioned this code).  It will be cleaned up considerably in the next few days...
**

Arduino Manager is the most wicked cool piece of software you’ve never heard of (website is here, but you’ll most likely download it using iTunes).  It’s a very pretty dashboard that’s completely customizable that talks to an Arduino board over the network.  You can add virtual switches, graphs, LEDs, meters, etc., then label them as you wish.  Then you assign a pin on the Arduino to each item on the dashboard.  Finally, you click the “generate code” button, and it spew a bunch of C code that you paste into your Arudino editor, compile, and burn onto your Arduino board.  You’ve now got a virtual control panel or console that can control and read pins on an Arduino board.  Neat!  The Mac version of the software is kind of flaky (screen redraw issues), but the iPhone/iPad version works really well (with the one major bug being that it’s very difficult to get it to connect the very first time you configure a new connection IP/port combination – it often requires rebooting the phone).  Here’s an example of a panel I put together that monitors some things:



Here’s the problem, though.  As much as I love the UI for this app, I really don’t want to just control a single Arduino board.  That’s fun and all, but I have lots and lots of things I want to monitor and control, and they don’t all map to single pins on an embedded processor.  Some of them involve the output of various processes that run on various networked Arduinos and Linux boxes in my house, my lab, and my web hosts.  And all of that stuff is integrated using MQTT, not the proprietary protocol that Arduino Manager uses.  So what did I do?  I did what any self-respecting systems hacker would do.  I looked carefully at the arduino code that was output by the tool, and combined that with a network sniffer watching the traffic between the manager and an Arduino and reverse-engineered the protocol.  That was easier than it sounds, as the protocol is actually quite simple and easy to understand and re-implement.  Then I wrote a gateway that basically translates back and forth (within limits) between the Arduino Manager’s proprietary protocol and MQTT.  Now I can monitor and control anything I want on any machine I want, but use the very nice Arduino Manager app to do it.

So what is the proprietary protocol?  It’s actually very clever and simple.  It consists of variable names and values separated by hash signs.  Each variable is displayed below the corresponding indicator or controller in the app.  For example, if you look at my screenshot above, notice there are two items named “office” (the meter, then the LCD display below it).  The temperature data is collected by a networked arduino in my office tied to a 1-Wired Maxim DS18B20 digital temperature sensor, then passed to the MQTT broker as mqtt data (in the format “office=74.637″).  My “translator” code that I wrote then turns that into “office=74.637#” and streams it over TCP to the app on my phone.  The Arduino Manager protocol consists of the following:

1. Upon startup of the app, it connects to the specified TCP port at the specified IP address.

2. The app then passes the first of two elements.  It tells you what time the phone thinks it is in epoch time (ie, “$Time$=123456789#").  In my code, I simply ignore this.

3.  The app then passes a request to tell it where to set all of it’s knobs and switches (ie, in case you left a switch “on” last time you used it, you want it to show up as “on” this time).  This consists of the variable name “Sync” with the value of the variable to be synced (the name of the switch).  This looks like “Sync=self_destruct#”.

4.  The Arduino then passes back the values for the switches, such as “self_destruct=0#”.

5.  The Arduino and the app then start sending values back and forth as they change, for example “office=74.845#” from the Arduino to the app, or “self_destruct=1#” from the app to the Arduino.  Multiple values can be stacked in a single transaction, such as “this=1#that=2#foo=69.42#”.

That’s it.  Told you it was simple and clever.

The initial version of my gateway was dumb and simple.  All mqtt traffic shares a single mqtt topic, and consists of “varname=value”.  As new values appeared, they were translated by the gateway and sent on their way.  Which worked, in as far as it went.  But there were problems.  Let’s suppose you were monitoring a temperature, monitoring a light level, and controlling a light bulb.  And let’s assume that the system being controlled sends a new temperature every sixty seconds and a new light level every 100ms.  Here are some fun problems:

1. First, I connect to the gateway with my app, and by default, my light switch is off.  But is the light on or off?  How did I leave it the last time?  A dumb gateway that simply translates requests back and forth has no idea.  My switch says off, but I might have left the light on the last time I connected.  What to do?  I could turn the switch on, and be sure the light is on, then turn it back off to be sure it’s off, but the only way to be 100% certain the light is off is to first turn it on.  That’s bad.

2. I have to sit and stare at an empty temperature field for potentially as much as 60 seconds before I see a value.  Why?  Because I only get a new value when the gateway gets a new value.

3.  I get a light level update ten times per second.  That’s a lot of updates.  Far more than I can possibly interpret, not to mention the waste of expensive cell phone data bandwidth.

This led to version two of the gateway, which implemented some caching and buffering.  In this version, copies of all variables and their values, as well as a timestamp of when they were last updated and when they were last sent, is kept in memory (and periodically written to a YAML file for safekeeping in the event of a process crash).  This allows me to do some useful things:

1. For data that is updated frequently, I can make sure that it’s only pushed to the phone app if it changes. So getting a sample every 100ms is no big deal, I only push a value to the phone if it’s different than it was last time.

2. For values received infrequently, I can send them to the phone on a regular schedule so you never have to wait too long for your screen to update (assuming you come in mid-way between updates from the actual sensor).  I also periodically re-send data from #1, even if it hasn’t changed, for the same reason.

3. I can expire old variables and throw them away if they aren’t changed or updated for a specified period of time (to avoid sending overly stale data to the client, which would mask problems, such as sensors that have stopped sending data).

4. Last, but not least, I store switch data (from virtual switches and knobs in the app) forever, so that I can always sync up the switch state no matter how long ago it was last set.  This is also useful if you have more than one app (or mqtt client) controlling the switch setting.  If Alice and Bob are both controlling the light switch, you want Bob’s light switch to flip to off if Alice turns hers off.

So there it is.  It’s not perfect, but it does work rather nicely, given some limitations.  What are the limitations?  There are several:

1. All of your MQTT data (both sent and received) must be under the same topic.

2. Your MQTT data must be formatted in the form “var_name=value”.  Meaning your clients need to parse out (and or prepend) the “varname=” bit.

3. I haven’t tested it with all of the Arduino Manger widget types.  Those known to work properly include:  Display, Guage, LED, Switch, Secured Switch, Knob, and Slider.  Switch & LED probably works, but I haven’t tried it.

4. Push Button doesn’t work.  Well, not correctly.  The issue is that when you push the button, the app sends “button=1#”, but never follows up with a “button=0″.  That’s because the app generates code for the Arduino that knows that the variable “button” corresponds to a button, and automatically does the right thing.  There’s no such equivalent in MQTT.  So you can use a button if you want, just be aware that you can only turn it on once, and that’s it.  There’s no “off”.  Not very useful.

5. The code only allows a single client to connect.  Yes, I’m lazy and should fix this.  But I haven’t.  If you want to talk to multiple clients, you’ll have to run multiple gateways on different TCP ports, and assign a port per user.  Yes, this is wasteful, blah blah blah. This is a fun project, not a real product.

6. There is some stuff hard-coded in the gateway that shouldn’t be.  For example, writing current state to the YAML file in /tmp/ will probably break on Windows (I don’t own a Windows machine to find out, but it works fine on Mac and Linux).

7. You’ll need to set up a creds.yaml file to hold some of the necessary config data.  Why?  Because I wrote it that way.  Feel free to change it.  And you’ll have to change the path to the file (it’s hard-coded as /home/jfrancis/creds.yaml).  The file should look like this:

—

mqtthost: my.mqtt.server.com

mqtttopic: topic_name

8. I currently haven’t added code to do logging in to the MQTT server, it assumes a wide-open server.  I’ll probably add that at some point.

 

I’ll probably put this up on github or something at some point, but for the moment, you can grab it here.  You’ll need ruby to run it, you’ll need a sitter to watch it (and restart it when necessary), and you’ll need to install the mqtt ruby gem (“sudo gem install mqtt”).
