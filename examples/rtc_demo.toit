// Copyright (C) 2025 Allen Schober.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the EXAMPLES_LICENSE file.

import gpio
import i2c
import pcf8563
import esp32

POLLING-INTERVAL-US   ::= 5_000_000   // 2 seconds
TIMER-INTERVAL-S      ::= 10          // 10 seconds
ALARM-INTERVAL-S      ::= 60          // 60 seconds
KNOWN_START_TIME      ::= Time.parse  "2025-04-26T09:41:11-08:00"

/**
Demo for the PCF8563 RTC driver that excercises the features of the real-time
clock including setting the time, setting a timer, and setting an alarm. 

The demo sets the RTC to a known time and then waits for a button press.  When 
the button is pressed, it sets a timer and an alarm. The demo then polls the RTC
for timer and alarm flags. If the timer or alarm is triggered, it prints the
time and clears the flag. The timer and alarm can be disabled by pressing the
button again.

The demo uses a device that has an i2c bus on pins 11-12 and a button on pin 42.
This can easily be modified to use different GPIO pins. 
*/
main:
  // Initialize an i2c bus and button
  i2c-bus /i2c.Bus := i2c.Bus 
      --sda=(gpio.Pin 11)
      --scl=(gpio.Pin 12)
      --frequency=10_000
      --pull-up=true
  button /gpio.Pin := gpio.Pin 42 --input --pull-up
  
  // Initialize the PCF8563 Driver
  i2c-device := i2c-bus.device pcf8563.PCF8563-I2C-ADDR
  rtc := pcf8563.Driver i2c-device

  print "PCF8563 real-time clock demo:"
  print "  - Sets RTC to a known time: $KNOWN_START_TIME"
  print "  - Press the button to set both a timer and an alarm"
  print "  - Press the button again to disable any active timer or alarm"

  // Set RTC to a known time
  rtc.set-datetime KNOWN_START_TIME

  last-button-pressed := false
  timer-active := false
  alarm-active := false
  launch-time-us := Time.monotonic-us
  last-poll-check-us := launch-time-us

  while true:
    current-time-us := Time.monotonic-us

    // --- Button Press Handling ---
    button-pressed := (button.get == 0)  
    if button-pressed and button-pressed != last-button-pressed:
      elapsed-ms := (current-time-us - launch-time-us) / 1000
      print "[$(elapsed-ms)ms] Button: pressed"

      // If a timer or alarm is running, disable them
      if (timer-active or alarm-active):
        rtc.disable-timer
        timer-active = false
        rtc.disable-alarm
        alarm-active = false
        print "  Existing RTC Timer and Alarm disabled"
        // Get the status to confirm the flags and interrupts are cleared
        interrupt-status := rtc.get-flag-and-interrupt-status
        print "  RTC Control-Status-2: $(interrupt-status)"
      else:
        // Set ESP32 system time to the RTC time
        datetime := rtc.read-datetime
        print "  RTC DateTime: $datetime"
        adjustment := Time.now.to datetime
        esp32.adjust_real_time_clock adjustment
        print "  ESP32 System Time: $(Time.now)"

        // Set Timer for TIMER-INTERVAL-S (10secs) in future
        timer-base-us := (current-time-us - launch-time-us) 
        timer-result-s := rtc.set-timer TIMER-INTERVAL-S --interrupt-enable=false  // Do not enable interrupt for this demo
        timer-launch-time-ms := (timer-base-us + timer-result-s * 1_000_000) / 1000
        print "  RTC Timer set for every $(timer-result-s)secs: around [$(timer-launch-time-ms)ms]"
        timer-active = true

        // Set Alarm for ALARM-INTERVAL-S (60secs) in future
        alarm-time := datetime + (Duration --s=ALARM-INTERVAL-S)
        rtc.set-alarm alarm-time --interrupt-enable=false  // Do not enable interrupt for this demo
        print "  RTC Alarm set for 1min: $((alarm-time.utc.with --s=0).to-iso8601-string)"
        alarm-active = true

        // Set poll check time backwards to do an immediate poll
        last-poll-check-us = current-time-us - POLLING-INTERVAL-US
    
    // save when button is pressed or released (outside of the 'if button' block above)
    last-button-pressed = button-pressed

    // --- Combined Timer and Alarm Polling ---
    // Check if enough time has passed to poll the RTC status
    if (timer-active or alarm-active) and (current-time-us - last-poll-check-us > POLLING-INTERVAL-US):
      last-poll-check-us = current-time-us
      elapsed-ms := (current-time-us - launch-time-us) / 1000

      // Read the flags and interrupts
      interrupt-status := rtc.get-flag-and-interrupt-status
      status-byte := interrupt-status[0] // Extract the byte value
      print "[$(elapsed-ms)ms] Poll RTC Control-Status-2: $(interrupt-status)"

      // Check RTC Timer Flag IF timer is active
      if timer-active:
        // Status Timer Flag: bit 2, bitmask 0x04)
        if (status-byte & pcf8563.BITMASK-CTRL-STS2-TIMER-FLAG) > 0:
          rtc-time := rtc.read-datetime
          print "  RTC Timer Flag detected at $(rtc-time)"
          rtc.clear-timer-flag
          print "  RTC Timer Flag cleared"

      // Check RTC Alarm Flag IF alarm is active
      if alarm-active:
        // Status Alarm Flag: bit 3, bitmask 0x08
        if (status-byte & pcf8563.BITMASK-CTRL-STS2-ALARM-FLAG) > 0:
          rtc-time := rtc.read-datetime
          print "  RTC Alarm Flag detected at $(rtc-time)"
          rtc.clear-alarm-flag
          print "  RTC Alarm Flag cleared"
          // Set the next alarm
          new-alarm-time := rtc-time + (Duration --s=ALARM-INTERVAL-S)
          rtc.set-alarm new-alarm-time --interrupt-enable=false  // Do not enable interrupt for this demo
          print "  RTC Alarm set for 1min: $((new-alarm-time.utc.with --s=0).to-iso8601-string)"

    sleep --ms=20  // Small delay to prevent busy waiting
