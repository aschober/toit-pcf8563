// Copyright (C) 2025 Allen Schober.  All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import i2c
import gpio

// I2C device address for the PCF8563
PCF8563-I2C-ADDR                     ::= 0x51

// I2C register addresses
REG-CONTROL-STATUS-1                  ::= 0x00
REG-CONTROL-STATUS-2                  ::= 0x01
REG-TIME-VL-SECONDS                   ::= 0x02
REG-TIME-MINUTES                      ::= 0x03
REG-TIME-HOURS                        ::= 0x04
REG-TIME-DAYS                         ::= 0x05
REG-TIME-WEEKDAYS                     ::= 0x06
REG-TIME-CENTURY-MONTHS               ::= 0x07
REG-TIME-YEARS                        ::= 0x08
REG-ALARM-MINUTE                      ::= 0x09
REG-ALARM-HOUR                        ::= 0x0A
REG-ALARM-DAY                         ::= 0x0B
REG-ALARM-WEEKDAY                     ::= 0x0C
REG-CLKOUT-CONTROL                    ::= 0x0D
REG-TIMER-CONTROL                     ::= 0x0E
REG-TIMER                             ::= 0x0F

// Bitmask values for control registers
BITMASK-CTRL-STS2-ALARM-FLAG          ::= 0x08
BITMASK-CTRL-STS2-TIMER-FLAG          ::= 0x04
BITMASK-CTRL-STS2-ALARM-INT-ENABLED   ::= 0x02
BITMASK-CTRL-STS2-TIMER-INT-ENABLED   ::= 0x01
BITMASK-TIMER-CTRL-TIMER-ENABLED      ::= 0x80
BITMASK-TIMER-CTRL-SOURCE-CLK-1d60HZ  ::= 0x03
BITMASK-TIMER-CTRL-SOURCE-CLK-1HZ     ::= 0x01

/**
The PCF8563 is a real-time clock (RTC) that communicates over I2C.
It provides timekeeping functions and can be used to set alarms and timers.

It uses the Binary Coded Decimal (BCD) format for majority of time and date
registers including seconds, minutes, hours, days, months, years, alarm-minute,
alarm-hour, and alarm-day.
*/
class Driver:
  device /i2c.Device

  constructor device/i2c.Device --interrupt/gpio.Pin?=null:
    this.device = device

    // Set Control-Status-1 register to 0x00 for normal operation
    this.device.write-reg REG-CONTROL-STATUS-1 #[0x00]
    // Set timer control to 1/60hz for power saving when timer not in use
    this.device.write-reg REG-TIMER-CONTROL #[BITMASK-TIMER-CTRL-SOURCE-CLK-1d60HZ]  

  /**
  Get voltage-low flag which indicates if Vdd dropped below Vlow and the 
  integrity of the clock is no longer guaranteed. 
  */
  get-voltage-low-flag -> bool:
    // Read the voltage low register
    voltLow := ((device.read-reg REG-TIME-VL-SECONDS 1)[0] & 0x80) > 0
    return voltLow
  
  /**
  Get the current time in UTC format.
  */
  read-time -> Time:
    // Read the time registers in binary-coded-decimal format
    timeBytes := this.device.read-reg REG-TIME-VL-SECONDS 3
    seconds := bcd-to-byte (timeBytes[0] & 0x7F)
    minutes := bcd-to-byte (timeBytes[1] & 0x7F)
    hours := bcd-to-byte (timeBytes[2] & 0x3F)
    time := Time.utc seconds minutes hours
    return time

  /**
  Get the current time and date in UTC format.
  */
  read-datetime -> Time:
    // Read the date and time registers in binary-coded-decimal format
    dateTimeBytes := this.device.read-reg REG-TIME-VL-SECONDS 7

    seconds := bcd-to-byte (dateTimeBytes[0] & 0x7F)
    minutes := bcd-to-byte (dateTimeBytes[1] & 0x7F)
    hours := bcd-to-byte (dateTimeBytes[2] & 0x3F)

    days := bcd-to-byte (dateTimeBytes[3] & 0x3F)
    weekdays := bcd-to-byte (dateTimeBytes[4] & 0x07)
    months := bcd-to-byte (dateTimeBytes[5] & 0x1F)
    century := ((dateTimeBytes[5] & 0x80) == 1) ? 1900 : 2000
    years := (bcd-to-byte (dateTimeBytes[6] & 0xFF)) + century

    datetime := Time.utc years months days hours minutes seconds
    return datetime

  /**
  Set the time (seconds, minutes, hours) in UTC format.
  If setting the time, the date is not modified.
  If going to set the time AND date, use set-datetime instead so all values are 
  are in one go and thus avoid corruption.
  */
  set-time time/Time -> none:
    timeinfo := time.utc
    bytes := #[
      byte-to-bcd timeinfo.s,
      byte-to-bcd timeinfo.m,
      byte-to-bcd timeinfo.h
    ]
    device.write-reg REG-TIME-VL-SECONDS bytes
  
  /**
  Set the date (day, weekday, month, year) in UTC format.
  If setting the date, the time is not modified.
  If going to set the time AND date, use set-datetime instead so all values are
  are in one go and thus avoid corruption.
  */
  set-date date/Time -> none:
    timeinfo := date.utc
    bytes := #[
      byte-to-bcd timeinfo.day,
      timeinfo.weekday,
      (byte-to-bcd timeinfo.month) + (timeinfo.year < 2000 ? 0x80 : 0),
      byte-to-bcd (timeinfo.year % 100)
    ]
    device.write-reg REG-TIME-DAYS bytes

  /**
  Set the time and date in UTC format.
  This function sets the time and date in one go to avoid corruption.
  */
  set-datetime dateTime/Time -> none:
    timeinfo := dateTime.utc
    bytes := #[
      byte-to-bcd timeinfo.s,
      byte-to-bcd timeinfo.m,
      byte-to-bcd timeinfo.h,
      byte-to-bcd timeinfo.day,
      timeinfo.weekday,
      (byte-to-bcd timeinfo.month) + (timeinfo.year < 2000 ? 0x80 : 0),
      byte-to-bcd (timeinfo.year % 100)
    ]
    device.write-reg REG-TIME-VL-SECONDS bytes

  /**
  Set the timer to trigger after a specified number of seconds.
  The timer can be set to trigger after a maximum of 255secs with 1sec
  resolution or trigger up to 255mins with 1min resolution.
  The timer is disabled if a negative value is passed.
  When the timer is triggered, the timer flag (TF) is set and the interrupt pin
  is pulled low if Timer Interrupt Enabled (TIE).
  Returns the number of seconds set for the timer which can differ from
  provided after-seconds depending on resolution.
  */
  set-timer after-seconds/int --interrupt-enable/bool=true -> int:
    reg-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0] & ~0x0C

    // if after-seconds negative, disable timer
    if (after-seconds < 0):
      device.write-reg REG-CONTROL-STATUS-2 #[(reg-value & ~BITMASK-CTRL-STS2-TIMER-INT-ENABLED)]
      device.write-reg REG-TIMER-CONTROL #[0x03]
      return -1

    div := 1
    // by default, set timer source clock freq to 1Hz (every second)
    type-value := 0x82 
    // if after-seconds < 270, keep timer source clock freq to 1Hz (every second)
    if (after-seconds < 270):
      if (after-seconds > 255):
        after-seconds = 255
    // if after-seconds >= 270, set timer source clock freq to 1/60Hz (every 1min)
    else:
      div = 60
      after-seconds = (after-seconds + 30) / div
      if (after-seconds > 255):
        after-seconds = 255
      type-value = 0x83 // set timer source clock freq to 1/60Hz
    
    device.write-reg REG-TIMER-CONTROL #[type-value]
    device.write-reg REG-TIMER #[after-seconds]

    if (interrupt-enable):
      // Set the timer interrupt enable bit
      control-2-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0]
          | BITMASK-CTRL-STS2-TIMER-INT-ENABLED
      device.write-reg REG-CONTROL-STATUS-2 #[control-2-value]
    else:
      // Clear the timer interrupt enable bit
      control-2-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0]
          & ~BITMASK-CTRL-STS2-TIMER-INT-ENABLED
      device.write-reg REG-CONTROL-STATUS-2 #[control-2-value]
    
    return after-seconds * div
    
  /**
  Set an alarm to trigger at specified hours and minutes.
  When the alarm is triggered, the Alarm Flag (AF) is set and the interrupt pin
  is pulled low if the Alarm Interrupt Enabled (AIE) bit was set.
  */
  set-alarm hours-utc/int minutes-utc/int --interrupt-enable/bool=true -> none:
    bytes := ByteArray 4 --initial=0xFF  // Set all bytes to enabled

    if (minutes-utc >= 0):
      bytes[0] = (byte-to-bcd minutes-utc) & 0x7F
    if (hours-utc >= 0):
      bytes[1] = (byte-to-bcd hours-utc) & 0x3F

    device.write-reg REG-ALARM-MINUTE bytes

    // Check if should set or clear the Alarm Interrupt Enable (AIE) bit
    if (interrupt-enable):
      control-2-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0]
          | BITMASK-CTRL-STS2-ALARM-INT-ENABLED
      device.write-reg REG-CONTROL-STATUS-2 #[control-2-value]
    else:
      control-2-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0]
          & ~BITMASK-CTRL-STS2-ALARM-INT-ENABLED
      device.write-reg REG-CONTROL-STATUS-2 #[control-2-value]
    return

  /**
  Set an alarm to trigger at specified time and date.
  When the alarm is triggered, the Alarm Flag (AF) is set and the interrupt pin
  is pulled low if the Alarm Interrupt Enabled (AIE) bit was set.
  */
  set-alarm time/Time --interrupt-enable/bool=true -> none:
    bytes := ByteArray 4 --initial=0xFF  // Set all bytes to enabled
    timeinfo := time.utc

    if (timeinfo.m >= 0):
      bytes[0] = (byte-to-bcd timeinfo.m) & 0x7F        // Bits 6-0
    if (timeinfo.h >= 0):
      bytes[1] = (byte-to-bcd timeinfo.h) & 0x3F        // Bits 5-0
    if (timeinfo.day >= 0):
      bytes[2] = (byte-to-bcd timeinfo.day) & 0x3F      // Bits 5-0
    if (timeinfo.weekday >= 0):
      bytes[3] = (byte-to-bcd timeinfo.weekday) & 0x07  // Bits 2-0

    device.write-reg REG-ALARM-MINUTE bytes

    // Check if should set or clear the Alarm Interrupt Enable (AIE) bit
    if (interrupt-enable):
      reg-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0] 
          | BITMASK-CTRL-STS2-ALARM-INT-ENABLED
      device.write-reg REG-CONTROL-STATUS-2 #[reg-value]
    else:
      reg-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0] 
          & ~BITMASK-CTRL-STS2-ALARM-INT-ENABLED
      device.write-reg REG-CONTROL-STATUS-2 #[reg-value]
    return

  /**
  Get the current status of the alarm and timer flags and interrupt enable bits.
  Returns a ByteArray with a single byte with the following bit values:
    - bit 7-4: Unused
    - bit 3: Alarm Flag (AF)
    - bit 2: Timer Flag (TF)
    - bit 1: Alarm Interrupt Enabled (AIE)
    - bit 0: Timer Interrupt Enabled (TIE)
  */
  get-flag-and-interrupt-status -> ByteArray:
    // Read the control status 2 register, bits 0-3
    bitmask := BITMASK-CTRL-STS2-ALARM-FLAG
        | BITMASK-CTRL-STS2-TIMER-FLAG
        | BITMASK-CTRL-STS2-ALARM-INT-ENABLED
        | BITMASK-CTRL-STS2-TIMER-INT-ENABLED
    status := (device.read-reg REG-CONTROL-STATUS-2 1)[0] & bitmask
    return #[status]

  /**
  Clear the Alarm Flag (AF) bit in the Control-Status-2 register.
  */
  clear-alarm-flag -> none:
    // Clear the alarm flag while keeping other existing bits
    reg-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0]
    device.write-reg
        REG-CONTROL-STATUS-2
        #[(reg-value & ~BITMASK-CTRL-STS2-ALARM-FLAG)]

  /**
  Clear the Timer Flag (TF) bit in the Control-Status-2 register.
  */
  clear-timer-flag -> none:
    // Clear the timer flag while keeping other existing bits
    reg-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0]
    device.write-reg
        REG-CONTROL-STATUS-2
        #[(reg-value & ~BITMASK-CTRL-STS2-TIMER-FLAG)]

  /**
  Disable the alarm and clear the alarm flag + interrupt enabled bits.
  
  The alarm is disabled by writing 0x80 to each of the four alarm registers:
  Minute_alarm, Hour_alarm, Day_alarm, Weekday_alarm.
  
  The Alarm Flag (AF) and Alarm Interrupt Enabled (AIE) bits are cleared by
  writing to the Control-Status-2 register.
  */
  disable-alarm -> none:
    // disable the four alarm registers (bit7:1=disabled)
    alarm-disable-bytes := #[0x80, 0x80, 0x80, 0x80]
    device.write-reg REG-ALARM-MINUTE alarm-disable-bytes

    // clear alarm flag and interrupt enable bits
    reg-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0]
    bitmask := BITMASK-CTRL-STS2-ALARM-FLAG 
        | BITMASK-CTRL-STS2-ALARM-INT-ENABLED
    device.write-reg REG-CONTROL-STATUS-2 #[(reg-value & ~bitmask)]

  /**
  Disable the timer and clear the timer flag + interrupt enabled bits.

  The timer is disabled and set to 1/60hz for power-saving by writing
  0x03 to the Timer-Control register.

  The Timer Flag (TF) and Timer Interrupt Enabled (TIE) bits are cleared by
  writing to the Control-Status-2 register.
  */
  disable-timer -> none:
    // disable timer (bit7:0=disabled) and set to 1/60hz (bit0-1:11) in Time Control
    device.write-reg REG-TIMER-CONTROL #[0x03]

    // clear timer flag and interrupt enable bits
    reg-value := (device.read-reg REG-CONTROL-STATUS-2 1)[0]
    bitmask := BITMASK-CTRL-STS2-TIMER-FLAG 
        | BITMASK-CTRL-STS2-TIMER-INT-ENABLED
    device.write-reg REG-CONTROL-STATUS-2 #[(reg-value & ~bitmask)]

  /**
  Helper function to convert between byte to binary-coded-decimal values.
  */
  byte-to-bcd value/int -> int:
    bcdhigh := value / 10;
    return (bcdhigh << 4) | (value - (bcdhigh * 10))

  /**
  Helper function to convert between binary-coded-decimal to byte values.
  */
  bcd-to-byte value/int -> int:
    return ((value >> 4) * 10) + (value & 0x0F)
