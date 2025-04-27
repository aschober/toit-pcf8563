# PCF8563 Toit Driver

A Toit driver for the PCF8563 real-time clock (RTC).

The PCF8563 is a low-power real-time clock (RTC) with an I2C interface and a built-in oscillator. It can be used to keep track of time and date and trigger interrupts even when the main power is off. This driver provides an easy-to-use interface for setting and getting the time in the real-time clock, as well as setting alarms and timers, and adjusting settings.

Helpful references:
- [NXP PCF8563 Datasheet](https://www.nxp.com/docs/en/data-sheet/PCF8563.pdf)
- [M5Stack RTC8563 Driver](https://github.com/m5stack/M5Unified/blob/5d359529b05d2f92d9e91bcf09dbd47b722538d5/src/utility/RTC8563_Class.cpp)

## Installation

Run below command:
```bash
$ jag pkg install github.com/aschober/toit-pcf8563
```

## Usage

```toit
import pcf8563

main:
  // Get access to I2C bus
  i2c-bus /i2c.Bus := i2c.Bus 
    --sda=(gpio.Pin 11)
    --scl=(gpio.Pin 12)
    --frequency=10_000
    --pull-up=true
  
  // Initialize the PCF8563 I2C Device and Driver
  i2c-device := i2c-bus.device pcf8563.PCF8563-I2C-ADDR
  rtc := pcf8563.Driver i2c-device
  
  // Set the RTC date and time to Time.now.utc
  rtc.set-datetime Time.now.utc
```

## Examples

See the `examples/` directory for usage examples:
- `rtc_demo.toit`: Simple example showing how to set time, create a timer and alarm, check status, and clear the timer and alarm

## License

MIT License - see LICENSE file for details
