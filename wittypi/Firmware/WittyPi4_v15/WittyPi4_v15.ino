/**
 * Firmware for WittyPi 4
 *
 * Revision: 15
 *
 * Changelog:
 *   Rev 15 (2026-07-05) - downtime-hardening release (I2C_FW_REVISION 0x0F):
 *     - Fix torn-alarm-rewrite race: any write to an alarm register now
 *       sets a 5-second alarmWriteHold; processAlarmIfNeeded() skips
 *       alarm matching while the hold is active. Previously the
 *       per-byte ALARM*_TRIGGERED clear in receiveEvent un-suppressed
 *       yesterday's stale (still in-window) alarm2 while the daemon's
 *       4-transaction rewrite was mid-flight; a WDT tick in that window
 *       hard-cut power mid-boot (observed as boot flapping).
 *     - SYS_UP boot watchdog: if the Pi is powered but never signals
 *       SYS_UP within 30 minutes, cut power and sleep (reason 13 =
 *       REASON_SYS_UP_TIMEOUT). The stale in-window alarm1 re-wakes it
 *       for a retry. Previously a Pi that hung before the daemon ran
 *       kept power on forever with every backstop blind (guaranteed
 *       wake counter only ticks while asleep).
 *     - Fix lost-wake race in sleep(): flag-clears and wakeupByWatchdog
 *       are now set atomically inside cli()/sei(). Previously a WDT
 *       tick between the flag-clear and 'wakeupByWatchdog = true'
 *       consumed the alarm1 match and then had its wake request
 *       overwritten - device slept through its alarm with the
 *       TRIGGERED flag stuck at 1.
 *     - Guaranteed Wake floor: reg 49 is forced to 24 (hours) at boot
 *       when 0 or 255. Fresh EEPROM previously synced to 0, shipping
 *       the 24h backstop disabled until the daemon's first run.
 *     - I2C_TIMEOUT=20ms on the internal software I2C master. It
 *       previously compiled the no-timeout spin: a wedged RTC bus
 *       would hang the WDT ISR forever with the Pi's power off
 *       (permanent brick - no WDE reset backstop exists).
 *     - Reboot detection re-samples TXD: up to 3 extra POWER_CUT_DELAY
 *       periods (~28s total) before concluding the Pi is really off.
 *       Previously a single sample of the floating TXD line 7s after
 *       shutdown made every OS reboot a coin flip; a slow reboot got
 *       its power cut and slept until the next day's alarm.
 *     - Month-boundary alarm wrap: overdue values around -1 month are
 *       re-normalized using the previous month's real length, so an
 *       alarm missed late on the last day of a month still fires
 *       within its 24h window instead of deferring ~1 month.
 *     - delay() overflow fix: DEFAULT_ON_DELAY * 1000 now computed in
 *       unsigned long. Values 33-65s previously overflowed int16 into
 *       a ~49.7-day boot delay (brick until power cycle).
 *     - EEPROM wear fix: telemetry registers 1-6 (Vin/Vout/Iout) are
 *       no longer persisted to EEPROM. ADC jitter was rewriting those
 *       cells on nearly every WDT tick during sleep (100k-cycle spec
 *       exceeded within weeks).
 *     - alarm1Delayed is reset in powerOn() and on alarm1 register
 *       writes. A stale value previously caused a spurious wake 3s
 *       after the next scheduled shutdown ("mystery wakes").
 *   Rev 14 patch (2026-05-28e):
 *     - Bug fix: turnOffFromTXD was sticky after a reboot detection in
 *       the Timer1 ISR. The reboot branch sets turningOff = false and
 *       lights the LED but never cleared turnOffFromTXD. On the next
 *       shutdown trigger (alarm2, LV), the Timer1 ISR's reboot test
 *       `(turnOffFromTXD && PIN_TX_UP == 1)` would re-fire — PIN_TX_UP
 *       is normally HIGH on a running Pi — and cutPower() would never
 *       be called. Symptom: scheduled shutdown logs the alarm match,
 *       sets reason = REASON_ALARM2, but the Pi keeps running. Fix:
 *       clear turnOffFromTXD inside the reboot branch, AND
 *       defensively clear it whenever alarm2 or LV shutdown is
 *       initiated so those paths can never be diverted.
 *   Rev 14 patch (2026-05-28d):
 *     - TXD-shutdown PCINT0 now requires systemIsUp == true before
 *       acting on a HIGH->LOW transition. Without this guard, a
 *       TXD glitch during early Pi boot (line floating-HIGH while
 *       Pi was off, then briefly LOW as the bootloader configured
 *       GPIO-14) was triggering a false shutdown ~0.5s after
 *       alarm1 powered the Pi on — the symptom: power LED came
 *       on briefly then went off again, Pi never reached the
 *       daemon. Pi shutdown detection still works correctly
 *       once SYS_UP has been signalled.
 *   Rev 14 patch (2026-05-28c):
 *     - REVERTED RECOVERY_VOLTAGE default from 30 (3.0V) back to 255
 *       (disabled). The 3.0V default made the sleep-loop LV recovery
 *       condition fire every ~4 seconds after any scheduled alarm2
 *       shutdown (because Vin from the DC input is always >3V),
 *       auto-waking the Pi instead of letting it stay asleep. The
 *       Pi now stays asleep after alarm2 until alarm1 / button /
 *       Guaranteed Wake (24h backstop). Fresh devices without a
 *       configured RECOVERY_VOLTAGE now require an explicit user
 *       choice or daemon override; this matches the original Witty
 *       Pi 4 behaviour.
 *   Rev 14 patch (2026-05-28b):
 *     - REVERTED the "don't clear ALARM2_TRIGGERED on sleep" change
 *       from the original Rev 14 push. Keeping that flag set across
 *       sleep blocked the next scheduled shutdown when the daemon
 *       didn't rewrite alarm2 on the subsequent boot. The reboot
 *       loop this was meant to prevent is already blocked by the
 *       WDT ISR setting the flag during sleep, plus the Pi-side
 *       verify_alarm_in_future cleanup.
 *   Rev 14 (2026-05-28):
 *     - Physical button shutdown removed entirely. PCINT1 ISR no
 *       longer initiates shutdown under any circumstance. The
 *       button/GPIO-4 shared line is now untouched by firmware
 *       code — knocks, shorts, or EMI on the line cannot affect
 *       a running Pi. Scheduled (alarm2) and LV shutdowns drive
 *       turningOff + Timer1 directly, no PIN_BUTTON pulse.
 *     - Alarm1 wake from sleep sets wakeupByWatchdog = false
 *       directly (was emulateButtonClick()).
 *     - Removed: emulateButtonClick() function and the
 *       isButtonClickEmulated state flag (now unused).
 *     - Manual wake-from-sleep on button press preserved as a
 *       maintenance override.
 *     - I2C_FW_REVISION bumped to 0x0E.
 *   Rev 13 (2026-05-26):
 *     - Reliability: moved sleep() out of Timer1 ISR. Now sets
 *       a pendingSleep flag from the ISR and runs sleep() from
 *       loop() at base context. Eliminates stack-nesting risk
 *       on 512-byte SRAM (FIRMWARE_ISSUES.md #1).
 *     - Reliability: added internalBusBusy mutex guarding the
 *       softWireMaster between WDT ISR and Pi I2C transactions.
 *       Eliminates bus-collision corruption (FIRMWARE_ISSUES.md #4).
 *     - Reliability: widened overdue window in processAlarmIfNeeded
 *       from 4s to 86400s (1 day). Catches alarms missed due to
 *       WDT jitter or stale-state interruptions.
 *     - "Any power input wakes": I2C_CONF_DEFAULT_ON is enforced to
 *       1 every boot (after EEPROM sync), so the Pi powers on
 *       whenever main DC power is connected. Cannot be disabled
 *       via EEPROM persistence — field policy.
 *     - Default I2C_CONF_RECOVERY_VOLTAGE = 30 (3.0V) so even a
 *       fresh unit recovers from LV-shutdown on any reasonable
 *       DC input, without depending on the Pi daemon having run.
 *     - Removed dormant features for flash headroom:
 *       * Temperature-action shutdown/startup (registers 43-46
 *         retained as no-op for backwards compat — LM75B no
 *         longer initialized at boot).
 *       * Sleep-loop LED blink (saves field-deployment battery).
 *     - Bumped I2C_FW_REVISION to 0x0D (13).
 *   Rev 12 (2026-04-14):
 *     - Fix: Alarm2, low voltage, and temperature shutdown paths now
 *       reset Timer1 so power-cut delay is deterministic.
 *     - Removed WDT turningOff timeout (root causes now fixed by
 *       TCNT1 resets, SYS_UP retry, listenToTxd init, wider alarm
 *       window — Timer1 hardware doesn't stall).
 *     - Removed dummy load pulsing and forcePowerCutIfNeeded.
 *     - Inlined getTemperature, offset2Value, value2Offset.
 *   Rev 11 (2026-04-11):
 *     - Disable physical button from initiating shutdown while the
 *       system is running. Button still works for power-on (wake from
 *       sleep). Emulated button clicks from alarms, low voltage, and
 *       temperature triggers still initiate shutdown as before.
 *     - Increase low voltage detection grace period from 180s (3 min)
 *       to 250s (~4 min) to cover slow boots and first-boot SD card
 *       expansion. Max value for byte counter type.
 *     - Fix: forcePowerCutIfNeeded() and Timer1 reset were bypassing
 *       the button disable, causing physical button to still shut down.
 *       Both now gated by isButtonClickEmulated.
 *     - Fix: Low voltage threshold unreachable (byte < 300 always true).
 *     - Fix: SYS_UP detection blocked by LED on shared pin 0. Don't
 *       update lastSystemUp on guard failure so next PCINT retries.
 *     - Fix: listenToTxd not set if TXD already HIGH at boot. Now
 *       initialized from TXD pin state on wake.
 *     - Fix: Alarm matching window widened from 2s to 4s to prevent
 *       missed alarms from WDT timing jitter.
 *     - Fix: copyAlarm writes all 5 RTC alarm registers (was 4).
 *     - Fix: Missing endTransmission for LM75B CONF I2C read.
 *   Rev 10 (2026-04-11):
 *     - Fix: Add WDT-based turningOff safety timeout (36 seconds).
 *       If the turningOff flag remains set beyond the maximum power-cut
 *       delay plus margin, the WDT ISR forces cutPower() to prevent
 *       permanent deadlock where power is never cut and the system
 *       drains the battery indefinitely. (Issues #10, #11)
 */

#define SDA_PIN 2
#define SDA_PORT PORTB
#define SCL_PIN 0
#define SCL_PORT PORTA
// Rev15: bound the internal-bus SCL-stretch wait. Without this the library
// compiles an unconditional spin (see SoftIICMaster.h `#if I2C_TIMEOUT <= 0`);
// a wedged RTC bus would hang the WDT ISR forever with the Pi's power off.
// All call sites already tolerate a failed read (returns garbage for one
// tick; alarm matching absorbs it via the 86400s window).
#define I2C_TIMEOUT 20
#include "SoftWireMaster.h"

#include <WireS.h>
#include <core_timers.h>
#include <avr/sleep.h>
#include <EEPROM.h>

#define PIN_SYS_UP                0   // pin to listen to SYS_UP
#define PIN_LED                   0   // pin to drive white LED
#define PIN_BUTTON                1   // pin to button
#define PIN_CTRL                  3   // pin to control output
#define PIN_TX_UP                 5   // pin to listen to Raspberry Pi's TXD
#define PIN_VIN                   A1  // pin to ADC1
#define PIN_VOUT                  A2  // pin to ADC2
#define PIN_VK                    A3  // pin to ADC3

#define PIN_SDA                   4   // pin to SDA for I2C (ATtiny841 as slave)
#define PIN_SCL                   6   // pin to SCL for I2C (ATtiny841 as slave)

#define PIN_I_SDA                 2   // pin to SDA for internal I2C (ATtiny841 as master)
#define PIN_I_SCL                 10  // pin to SCL for internal I2C (ATtiny841 as master)

#define ADDRESS_LM75B           0x48  // LM75B address in internal I2C bus
#define ADDRESS_RTC             0x51  // PCF85063 address in internal I2C bus

/*
 * I2C registers
 *
 * Registers with index 0~15 are readonly
 * Registers with index 16~49 can be read/wrote
 * Registers with index >= 50 are vitual registers
 */

/*
 * read-only registers
 */
#define I2C_ID                      0   // firmware id
#define I2C_VOLTAGE_IN_I            1   // integer part for input voltage
#define I2C_VOLTAGE_IN_D            2   // decimal part (x100) for input voltage
#define I2C_VOLTAGE_OUT_I           3   // integer part for output voltage
#define I2C_VOLTAGE_OUT_D           4   // decimal part (x100) for output voltage
#define I2C_CURRENT_OUT_I           5   // integer part for output current
#define I2C_CURRENT_OUT_D           6   // decimal part (x100) for output current
#define I2C_POWER_MODE              7   // 1 if Witty Pi is powered via the DC input, 0 if direclty use 5V input
#define I2C_LV_SHUTDOWN             8   // 1 if system was shutdown by low voltage, otherwise 0
#define I2C_ALARM1_TRIGGERED        9   // 1 if alarm1 (startup) has been triggered
#define I2C_ALARM2_TRIGGERED        10  // 1 if alarm2 (shutdown) has been triggered
#define I2C_ACTION_REASON           11  // the latest action reason: 1-alarm1; 2-alarm2; 3-click; 4-low voltage; 5-voltage restored; 6-over temperature; 7-below temperature; 8-alarm1 delayed; 10-power connected; 11-reboot; 12-guaranteed wake
#define I2C_FW_REVISION             12  // the firmware revision
#define I2C_RFU_1                   13  // reserve for future usage
#define I2C_RFU_2                   14  // reserve for future usage
#define I2C_RFU_3                   15  // reserve for future usage

/*
 * readable/writable registers
 */
#define I2C_CONF_ADDRESS            16  // I2C slave address: defaul=0x08
#define I2C_CONF_DEFAULT_ON         17  // turn on RPi when power is connected: 1=yes, 0=no
#define I2C_CONF_PULSE_INTERVAL     18  // pulse interval (in seconds, for LED and dummy load): default=4 (4 sec)
#define I2C_CONF_LOW_VOLTAGE        19  // low voltage threshold (x10), 255=disabled
#define I2C_CONF_BLINK_LED          20  // how long the white LED should stay on (in ms), 0 if white LED should not blink.
#define I2C_CONF_POWER_CUT_DELAY    21  // the delay (x10) before power cut: default=70 (7 sec)
#define I2C_CONF_RECOVERY_VOLTAGE   22  // voltage (x10) that triggers recovery, 255=disabled
#define I2C_CONF_DUMMY_LOAD         23  // (Rev13: reserved/no-op, dummy load feature removed)
#define I2C_CONF_ADJ_VIN            24  // adjustment for measured Vin (x100), range from -127 to 127
#define I2C_CONF_ADJ_VOUT           25  // adjustment for measured Vout (x100), range from -127 to 127
#define I2C_CONF_ADJ_IOUT           26  // adjustment for measured Iout (x100), range from -127 to 127

#define I2C_CONF_SECOND_ALARM1      27  // Second_alarm register for startup alarm (BCD format)
#define I2C_CONF_MINUTE_ALARM1      28  // Minute_alarm register for startup alarm (BCD format)
#define I2C_CONF_HOUR_ALARM1        29  // Hour_alarm register for startup alarm (BCD format)
#define I2C_CONF_DAY_ALARM1         30  // Day_alarm register for startup alarm (BCD format)
#define I2C_CONF_WEEKDAY_ALARM1     31  // Weekday_alarm register for startup alarm (BCD format)

#define I2C_CONF_SECOND_ALARM2      32  // Second_alarm register for shutdown alarm (BCD format)
#define I2C_CONF_MINUTE_ALARM2      33  // Minute_alarm register for shutdown alarm (BCD format)
#define I2C_CONF_HOUR_ALARM2        34  // Hour_alarm register for shutdown alarm (BCD format)
#define I2C_CONF_DAY_ALARM2         35  // Day_alarm register for shutdown alarm (BCD format)
#define I2C_CONF_WEEKDAY_ALARM2     36  // Weekday_alarm register for shutdown alarm (BCD format)

#define I2C_CONF_RTC_OFFSET         37  // standard value for RTC offset register
#define I2C_CONF_RTC_ENABLE_TC      38  // set to 1 to enable temperature compensation
#define I2C_CONF_FLAG_ALARM1        39  // a flag that indicates alarm1 is triggered and not processed
#define I2C_CONF_FLAG_ALARM2        40  // a flag that indicates alarm2 is triggered and not processed

#define I2C_CONF_IGNORE_POWER_MODE  41  // set 1 to ignore I2C_POWER_MODE for low voltage shutdown and recovery
#define I2C_CONF_IGNORE_LV_SHUTDOWN 42  // set 1 to ignore I2C_LV_SHUTDOWN for low voltage shutdown and recovery

#define I2C_CONF_BELOW_TEMP_ACTION  43  // (Rev13: reserved/no-op, temperature-action feature removed)
#define I2C_CONF_BELOW_TEMP_POINT   44  // (Rev13: reserved/no-op)
#define I2C_CONF_OVER_TEMP_ACTION   45  // (Rev13: reserved/no-op)
#define I2C_CONF_OVER_TEMP_POINT    46  // (Rev13: reserved/no-op)

#define I2C_CONF_DEFAULT_ON_DELAY   47  // the delay (in second) between MCU initialization and turning on Raspberry Pi, when I2C_CONF_DEFAULT_ON = 1
#define I2C_CONF_MISC               48  // 8 bits for miscellaneous configuration.
                                        //   bit-0: set to 1 to disable alarm1 (startup) delay
#define I2C_CONF_GUARANTEED_WAKE    49  // 8 bits for guarenteed wake configuration.
                                        //   bit-0~6: guaranteed wake duration (0~127)
                                        //   bit-7: guaranteed wake duration unit (0=hour, 1=day)

#define I2C_REG_COUNT               50  // number of (non-virtual) I2C registers

/*
 * virtual registers (mapped to LM75B or RCF85063)
 */
#define I2C_LM75B_TEMPERATURE       50  // mapped to temperature register in LM75B (2 bytes, readonly)
#define I2C_LM75B_CONF              51  // mapped to configuration register in LM75B
#define I2C_LM75B_THYST             52  // mapped to hysteresis temperature register in LM75B (2 bytes)
#define I2C_LM75B_TOS               53  // mapped to overtemperature register in LM75B (2 bytes)

#define I2C_RTC_CTRL1               54  // mapped to Control_1 register in PCF85063
#define I2C_RTC_CTRL2               55  // mapped to Control_2 register in PCF85063
#define I2C_RTC_OFFSET              56  // mapped to Offset register in PCF85063
#define I2C_RTC_RAM_BYTE            57  // mapped to RAM_byte register in PCF85063
#define I2C_RTC_SECONDS             58  // mapped to Seconds register in PCF85063
#define I2C_RTC_MINUTES             59  // mapped to Minutes register in PCF85063
#define I2C_RTC_HOURS               60  // mapped to Hours register in PCF85063
#define I2C_RTC_DAYS                61  // mapped to Days register in PCF85063
#define I2C_RTC_WEEKDAYS            62  // mapped to Weekdays register in PCF85063
#define I2C_RTC_MONTHS              63  // mapped to Months register in PCF85063
#define I2C_RTC_YEARS               64  // mapped to Years register in PCF85063
#define I2C_RTC_SECOND_ALARM        65  // mapped to Second_alarm register in PCF85063
#define I2C_RTC_MINUTE_ALARM        66  // mapped to Minute_alarm register in PCF85063
#define I2C_RTC_HOUR_ALARM          67  // mapped to Hour_alarm register in PCF85063
#define I2C_RTC_DAY_ALARM           68  // mapped to Day_alarm register in PCF85063
#define I2C_RTC_WEEKDAY_ALARM       69  // mapped to Weekday_alarm register in PCF85063
#define I2C_RTC_TIMER_VALUE         70  // mapped to Timer_value register in PCF85063
#define I2C_RTC_TIMER_MODE          71  // mapped to Timer_mode register in PCF85063

/**
 * Reason for latest action (used by I2C_ACTION_REASON register)
 */
#define REASON_ALARM1             1
#define REASON_ALARM2             2
#define REASON_CLICK              3
#define REASON_LOW_VOLTAGE        4
#define REASON_VOLTAGE_RESTORE    5
// REASON_OVER_TEMPERATURE  6 - reserved/removed in Rev 13
// REASON_BELOW_TEMPERATURE 7 - reserved/removed in Rev 13
#define REASON_ALARM1_DELAYED     8
#define REASON_POWER_CONNECTED    10
#define REASON_REBOOT             11
#define REASON_GUARANTEED_WAKE    12
#define REASON_SYS_UP_TIMEOUT     13  // Rev15: powered but no SYS_UP within 30min - power-cycled to retry boot


volatile byte i2cReg[I2C_REG_COUNT];

volatile char i2cIndex = 0;

volatile boolean buttonPressed = false;

volatile boolean powerIsOn = false;

volatile boolean listenToTxd = false;

volatile boolean systemIsUp = false;

volatile boolean turningOff = false;

volatile boolean wakeupByWatchdog = false;

volatile boolean ledIsOn = false;

volatile unsigned int powerCutDelay = 0;

// (Rev13: isButtonClickEmulated removed alongside emulateButtonClick.)

volatile byte skipAdjustRtcCount = 0;


volatile byte skipPulseCount = 0;

volatile byte skipLowVoltageDetectCount = 0;

// Rev13: set by Timer1 ISR, serviced by loop() to run sleep() at base
// context rather than nested inside the ISR (FIRMWARE_ISSUES.md #1).
volatile boolean pendingSleep = false;

// Rev13: mutex flag set when Pi I2C transactions are in progress on the
// internal softWireMaster bus. The WDT ISR consults it and skips RTC
// reads/writes for that tick rather than corrupting an in-flight transfer
// (FIRMWARE_ISSUES.md #4).
volatile uint8_t internalBusBusy = 0;

volatile byte alarm1Delayed = 0;

volatile byte ledUpTime = 0;

volatile byte lastButton = 1;

volatile byte lastSystemUp = 0;

volatile boolean turnOffFromTXD = false;

volatile unsigned long guaranteedWakeCounter = 0;

// Rev15: while > 0, processAlarmIfNeeded() skips alarm matching. Set to 5
// (seconds) by receiveEvent on every alarm-register write, so the WDT ISR
// never evaluates a half-written (torn) alarm block mid-rewrite. Refreshed
// per byte; the daemon's 4-transaction rewrite completes well inside it.
volatile byte alarmWriteHold = 0;

// Rev15: SYS_UP boot watchdog. Counts seconds while the Pi is powered but
// has not yet signalled SYS_UP. At SYS_UP_TIMEOUT_SECS the firmware cuts
// power and sleeps; the still-in-window alarm1 (or DEFAULT_ON on the next
// power event) re-wakes the Pi for a retry. Without this, a Pi that hangs
// before the daemon runs keeps power on forever and every backstop is
// blind (the guaranteed wake counter only ticks while asleep).
#define SYS_UP_TIMEOUT_SECS 1800
volatile unsigned int sysUpWatchdog = 0;

// Rev15: reboot-detection grace. The single TXD sample 7s after shutdown
// was a coin flip on a floating line; we now re-sample for up to 3 more
// POWER_CUT_DELAY periods before concluding the Pi is really off.
volatile byte rebootGraceCount = 0;

volatile byte lowVoltageCacheInteger = 0;

volatile byte lowVoltageCacheDecimal = 0;


SoftWireMaster softWireMaster;  // software I2C master


void setup() {
  // initialize software I2C master
  softWireMaster.begin();

  // initialize pin states and make sure power is cut
  pinMode(PIN_SYS_UP, INPUT);
  pinMode(PIN_BUTTON, INPUT_PULLUP);
  pinMode(PIN_CTRL, OUTPUT);
  pinMode(PIN_TX_UP, INPUT);
  pinMode(PIN_VIN, INPUT);
  pinMode(PIN_VOUT, INPUT);
  pinMode(PIN_VK, INPUT);
  pinMode(PIN_SDA, INPUT_PULLUP);
  pinMode(PIN_SCL, INPUT_PULLUP);
  cutPower();

  // use internal 1.1V reference
  analogReference(INTERNAL1V1);

  // initlize registers
  initializeRegisters();

  // i2c initialization
  TinyWireS.begin((i2cReg[I2C_CONF_ADDRESS] <= 0x07 || i2cReg[I2C_CONF_ADDRESS] >= 0x78) ? 0x08 : i2cReg[I2C_CONF_ADDRESS]);
  TinyWireS.onAddrReceive(addressEvent);
  TinyWireS.onReceive(receiveEvent);
  TinyWireS.onRequest(requestEvent);

  // disable global interrupts
  cli();

  // enable pin change interrupts
  GIMSK = _BV (PCIE0) | _BV (PCIE1);
  PCMSK1 = _BV (PCINT8) | _BV (PCINT9);
  PCMSK0 = _BV (PCINT5);

  // enable Timer1
  timer1_enable();

  // enable watchdog
  watchdog_enable(0);

  // enable all interrupts
  sei();

  // power on or sleep
  bool defaultOn = (i2cReg[I2C_CONF_DEFAULT_ON] == 1);
  if (defaultOn) {
    // Rev15: loop 1s chunks instead of multiplying. byte * int is 16-bit
    // on AVR; the old `delay(reg * 1000)` overflowed for a configured
    // delay of 33-65s into a ~49.7-day dead boot.
    for (byte dsec = i2cReg[I2C_CONF_DEFAULT_ON_DELAY]; dsec > 0; dsec --) {
      delay(1000);
    }
    updateRegister(I2C_ACTION_REASON, REASON_POWER_CONNECTED);
    // Rev14 patch (2026-05-28d): same stale-alarm2 guard as alarm1 wake -
    // if the EEPROM-resident alarm2 time falls within the 86400s match
    // window, the first WDT tick after powerOn() would otherwise fire
    // it and Timer1 would cut power within milliseconds. The daemon
    // rewrites alarm2 from the schedule, which clears this flag.
    updateRegister(I2C_ALARM2_TRIGGERED, 1);
    powerOn();  // power on directly
  } else {
    sleep();    // sleep and wait for button action
  }
}


void loop() {
  // Rev13: service deferred sleep from Timer1 ISR. Running sleep() here
  // (base context) keeps the Timer1 frame off the stack while WDT and
  // PCINT ISRs nest during the sleep loop.
  if (pendingSleep) {
    pendingSleep = false;
    sleep();
  }
}


// initialize the registers and synchronize with EEPROM
void initializeRegisters() {
  i2cReg[I2C_ID] = 0x26;
  i2cReg[I2C_FW_REVISION] = 0x0F;

  i2cReg[I2C_CONF_ADDRESS] = 0x08;

  // Rev13: default to "any power input wakes the Pi". On first flash or
  // after EEPROM clear, the device powers on automatically whenever main
  // DC power is applied. Pi-side software can override via I2C reg 17.
  i2cReg[I2C_CONF_DEFAULT_ON] = 1;

  i2cReg[I2C_CONF_PULSE_INTERVAL] = 4;
  i2cReg[I2C_CONF_LOW_VOLTAGE] = 255;
  i2cReg[I2C_CONF_BLINK_LED] = 100;
  i2cReg[I2C_CONF_POWER_CUT_DELAY] = 70;
  // Rev14 patch (2026-05-28c): revert RECOVERY_VOLTAGE default to 255
  // (disabled). The previous default of 30 (3.0V) caused the sleep-loop
  // LV recovery condition to fire every ~4 seconds after a scheduled
  // alarm2 shutdown, auto-waking the Pi instead of letting it stay
  // asleep until alarm1. With 255, the Pi only wakes via alarm1,
  // button, or Guaranteed Wake (24h backstop) - the intended behaviour
  // for field-deployed devices with scheduled on/off cycles.
  i2cReg[I2C_CONF_RECOVERY_VOLTAGE] = 255;

  i2cReg[I2C_CONF_ADJ_VIN] = 20;
  i2cReg[I2C_CONF_ADJ_VOUT] = 20;

  i2cReg[I2C_CONF_RTC_ENABLE_TC] = 0x01;

  // synchronize configuration with EEPROM
  for (byte i = 0; i < I2C_REG_COUNT; i ++) {
    byte val = EEPROM.read(i);
    if (val == 255) {
      EEPROM.update(i, i2cReg[i]);
    } else {
      i2cReg[i] = val;
    }
  }

  // Rev13: enforce "any power input wakes" — DEFAULT_ON is reset to 1
  // AFTER the EEPROM sync loop, overriding any value persisted from a
  // previous wittyPi.sh menu change. Field-deployed devices must never
  // be left with DEFAULT_ON=0 because the Pi daemon's enable_default_on
  // can only run after the Pi has already powered up. This is a one-way
  // policy: the device will auto-wake on power applied, period.
  i2cReg[I2C_CONF_DEFAULT_ON] = 1;
  EEPROM.update(I2C_CONF_DEFAULT_ON, 1);

  // Rev15: enforce a Guaranteed Wake floor, same one-way field policy as
  // DEFAULT_ON above. Fresh EEPROM (0xFF cells) synced reg 49 to the
  // zero-initialised RAM value, shipping the 24h backstop DISABLED until
  // the Pi daemon's first successful run - exactly when a new device is
  // most exposed. 24 = 0x18 = every 24 hours (bit7=0 -> hours), matching
  // what daemon.sh writes. 255 is also normalised (it would be re-read
  // as the EEPROM erase sentinel on the next boot and become 0).
  // (Note: 255 can't appear here - the sync loop above converts an erased
  // 0xFF cell into the zero-initialised RAM value, so 0 is the only
  // disabled state to normalise.)
  if (i2cReg[I2C_CONF_GUARANTEED_WAKE] == 0) {
    i2cReg[I2C_CONF_GUARANTEED_WAKE] = 24;
    EEPROM.update(I2C_CONF_GUARANTEED_WAKE, 24);
  }

  // Rev13: only push RTC offset to PCF85063 at boot. LM75B threshold init
  // removed (temperature-action feature is no-op since Rev 12, fully
  // dropped in Rev 13).
  writeToDevice(ADDRESS_RTC, I2C_RTC_OFFSET - I2C_RTC_CTRL1, &i2cReg[I2C_CONF_RTC_OFFSET], 1);
}


// enable watchdog timer with specified wdp (or get it from I2C_CONF_PULSE_INTERVAL)
void watchdog_enable(byte wdp) {
  cli();
  WDTCSR |= _BV(WDIE);
  WDTCSR |= 6;  // trigger every second
  sei();
}


// enable timer1 (for power cut delay)
void timer1_enable() {
  // set entire TCCR1A and TCCR1B register to 0
  TCCR1A = 0;
  TCCR1B = 0;

  // set 1024 prescaler
  bitSet(TCCR1B, CS12);
  bitSet(TCCR1B, CS10);

  // clear overflow interrupt flag
  bitSet(TIFR1, TOV1);

  // set timer counter
  TCNT1 = getPowerCutPreloadTimer(true);

  // enable Timer1 overflow interrupt
  bitSet(TIMSK1, TOIE1);
}


// disable timer1
void timer1_disable() {
  // disable Timer1 overflow interrupt
  bitClear(TIMSK1, TOIE1);
}


// put MCU into sleep to save power
void sleep() {
  timer1_disable();                       // disable Timer1
  ADCSRA &= ~_BV(ADEN);                   // ADC off
  set_sleep_mode(SLEEP_MODE_PWR_DOWN);    // power-down mode
  sleep_enable();                         // sets the Sleep Enable bit in the MCUCR Register (SE BIT)

  // Clear both alarm triggered flags so alarms can re-fire on next match
  // without requiring the Pi daemon to write to alarm registers first.
  //
  // (A previous Rev 14 patch kept ALARM2_TRIGGERED set across sleep to
  // defend against an alarm2 reboot loop on auto-recovery, but it had
  // the side effect of permanently blocking the next scheduled
  // shutdown if anything went wrong with the daemon's alarm2 rewrite
  // on the subsequent boot. Reverted: the reboot loop is independently
  // prevented because the WDT ISR runs throughout sleep — when the
  // alarm time matches during sleep, processAlarmIfNeeded sets the
  // flag itself but takes no action because powerIsOn is false. By
  // the time auto-recovery brings the Pi back online, the flag is
  // already set, so the second match doesn't re-fire. The Pi-side
  // verify_alarm_in_future on every daemon boot is an additional
  // layer for stale past alarms.)
  // Rev15: the flag-clears and the wakeupByWatchdog arm must be atomic
  // with respect to the WDT ISR. Previously a WDT tick landing between
  // the flag-clear and 'wakeupByWatchdog = true' (a ~7ms window - two
  // EEPROM writes) could match an in-window alarm1, request the wake
  // (wakeupByWatchdog = false), and then have that request overwritten
  // - leaving ALARM1_TRIGGERED stuck at 1 with the device asleep until
  // Guaranteed Wake. cli/sei makes the whole entry sequence one unit;
  // a pending WDT tick fires right after sei() and is evaluated with
  // consistent state.
  cli();
  updateRegister(I2C_ALARM1_TRIGGERED, 0);
  updateRegister(I2C_ALARM2_TRIGGERED, 0);

  GIMSK = _BV (PCIE1);                    // only enable interrupt for switch (PCINT9)
  PCMSK1 = _BV (PCINT9);
  wakeupByWatchdog = true;
  sei();
  do {
    sleep_cpu();                          // sleep
    if (wakeupByWatchdog) {               // wake up by watch dog

      boolean guaranteedWake = false;
      unsigned long guaranteedWakeThreshold = (i2cReg[I2C_CONF_GUARANTEED_WAKE] & 0x7F);
      if (guaranteedWakeThreshold > 0) {
        guaranteedWakeCounter ++;
        if (guaranteedWakeCounter >= guaranteedWakeThreshold * ((i2cReg[I2C_CONF_GUARANTEED_WAKE] & 0x80) > 0 ? 86400 : 3600)) {
          float vin = updatePowerMode();
          if (i2cReg[I2C_POWER_MODE] == 0) {
            guaranteedWake = true;
          } else {
            float vrec = (i2cReg[I2C_CONF_RECOVERY_VOLTAGE] == 255) ? 0.0f : ((float)i2cReg[I2C_CONF_RECOVERY_VOLTAGE]) / 10;
            if (vin >= vrec) {
              guaranteedWake = true;
            } else {
              guaranteedWakeCounter = 0; // input voltage is too low, will try again later
            }
          }
        }
        if (guaranteedWake) {
          wakeupByWatchdog = false;
          updateRegister(I2C_ACTION_REASON, REASON_GUARANTEED_WAKE);  // guarantee wake up in given duration
        }
      }

      skipPulseCount ++;
      if (!guaranteedWake && skipPulseCount >= i2cReg[I2C_CONF_PULSE_INTERVAL]) {
        skipPulseCount = 0;

        // Rev13: sleep-loop LED blink removed to save field battery and
        // free flash for safety improvements. The LED still flashes on
        // button press (PCINT1 ISR) so user interaction is unchanged.

        // update power mode and get input voltage
        float vin = updatePowerMode();

        // check input voltage if shutdown because of low voltage, and recovery voltage has been set
        // will skip checking I2C_LV_SHUTDOWN if I2C_CONF_LOW_VOLTAGE is set to 0xFF
        if ((i2cReg[I2C_POWER_MODE] == 1 || i2cReg[I2C_CONF_IGNORE_POWER_MODE] == 1)
            && (i2cReg[I2C_LV_SHUTDOWN] == 1 || i2cReg[I2C_CONF_LOW_VOLTAGE] == 255 || i2cReg[I2C_CONF_IGNORE_LV_SHUTDOWN] == 1)
            && i2cReg[I2C_CONF_RECOVERY_VOLTAGE] != 255) {
          float vrec = ((float)i2cReg[I2C_CONF_RECOVERY_VOLTAGE]) / 10;
          if (vin >= vrec) {
            wakeupByWatchdog = false;       // recovery from low voltage shutdown
            updateRegister(I2C_ACTION_REASON, REASON_VOLTAGE_RESTORE);
          }
        }
      }
    }
  } while (wakeupByWatchdog);             // quit sleeping if wake up by button

  cli();                                  // disable interrupts
  sleep_disable();                        // clear SE bit
  ADCSRA |= _BV(ADEN);                    // ADC on
  timer1_enable();                        // enable Timer1

  GIMSK = _BV (PCIE0) | _BV (PCIE1);
  PCMSK1 = _BV (PCINT8) | _BV (PCINT9);
  sei();                                  // enable all required interrupts

  // tap the button to wake up
  listenToTxd = digitalRead(PIN_TX_UP);  // start listening if TXD already HIGH
  systemIsUp = false;
  turningOff = false;
  powerOn();
  TCNT1 = getPowerCutPreloadTimer(true);
}


// Rev15: shared immediate-cut arming used by alarm2, LV shutdown and the
// SYS_UP boot watchdog (factored out to save flash - the chip is full).
// Timer1's overflow ISR performs the actual cutPower() ~ms later.
void armImmediateCut() {
  turnOffFromTXD = false;
  turningOff = true;
  systemIsUp = false;
  powerCutDelay = 0;
  TCNT1 = 65534;
}


// cut 5V output on GPIO header
void cutPower() {
  powerIsOn = false;
  digitalWrite(PIN_CTRL, 0);
  turnOffFromTXD = false;
}


// output 5V to GPIO header
void powerOn() {
  powerIsOn = true;
  guaranteedWakeCounter = 0;
  skipLowVoltageDetectCount = 0;
  // Rev15: fresh session - no stale delayed-alarm1 or boot-watchdog state
  alarm1Delayed = 0;
  sysUpWatchdog = 0;
  digitalWrite(PIN_CTRL, 1);
  updatePowerMode();
}


// turn on white LED
void ledOn() {
  ledIsOn = true;
  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, 1);
  ledUpTime = 0;
}


// turn off white LED
void ledOff() {
  digitalWrite(PIN_LED, 0);
  pinMode(PIN_LED, INPUT);
  ledIsOn = false;
}


// get voltage at specific pin
float getAdcVoltageAtPin(byte pin) {
  return 0.061290322580645 * analogRead(pin);    // 57*1.1/1023~=0.06129
}



// get voltage at cathode
float getCathVoltage() {
  return 0.001075f * analogRead(PIN_VK);
}

// get actual adjust value for given register
float getAdjustValue(byte regId) {
  return (float)((char)i2cReg[regId]) / 100.0f;
}

// update power mode according to input voltage, and return the input voltage
float updatePowerMode() {
  byte bk = ADCSRA;
  ADCSRA |= _BV(ADEN);
  float vin = getAdcVoltageAtPin(PIN_VIN);
  ADCSRA = bk;
  updateRegister(I2C_POWER_MODE, (vin > 5.25f) ? 1 : 0);
  return vin;
}


// get input voltage
float getInputVoltage() {
  if (lowVoltageCacheInteger == 0) {
    float v = getAdcVoltageAtPin(PIN_VIN);
    v += getAdjustValue(I2C_CONF_ADJ_VIN);
    updateRegister(I2C_VOLTAGE_IN_I, getIntegerPart(v));
    updateRegister(I2C_VOLTAGE_IN_D, getDecimalPart(v));
    return v;
  } else {
    return (float)lowVoltageCacheInteger + ((float)lowVoltageCacheDecimal) / 100;
  }
}


// get output voltage
float getOutputVoltage() {
  float v = getAdcVoltageAtPin(PIN_VOUT);
  float vk = getCathVoltage();
  v = v - vk + getAdjustValue(I2C_CONF_ADJ_VOUT);
  updateRegister(I2C_VOLTAGE_OUT_I, getIntegerPart(v));
  updateRegister(I2C_VOLTAGE_OUT_D, getDecimalPart(v));
  return v;
}


// get output current
float getOutputCurrent() {
  float v = getCathVoltage();
  float i = v / 0.05 + getAdjustValue(I2C_CONF_ADJ_IOUT);
  updateRegister(I2C_CURRENT_OUT_I, getIntegerPart(i));
  updateRegister(I2C_CURRENT_OUT_D, getDecimalPart(i));
  return i;
}






// get integer part of given number
byte getIntegerPart(float v) {
  return (byte)v;
}


// get decimal part of given number
byte getDecimalPart(float v) {
  return (byte)((v - getIntegerPart(v)) * 100);
}


// get the preload timer value for power cut
unsigned int getPowerCutPreloadTimer(boolean reset) {
  if (reset) {
    powerCutDelay = i2cReg[I2C_CONF_POWER_CUT_DELAY];
  }
  unsigned int actualDelay = 0;
  if (powerCutDelay > 83) {
    actualDelay = 83;
  } else {
    actualDelay = powerCutDelay;
  }
  powerCutDelay -= actualDelay;
  return 65535 - 781 * actualDelay;
}


// receives a sequence of start|address|direction bit from i2c master
boolean addressEvent(uint16_t slaveAddress, uint8_t startCount) {
  if (startCount > 0 && TinyWireS.available()) {
    i2cIndex = TinyWireS.read();
  }
  return true;
}


// receives a sequence of data from i2c master (master writes to this device)
void receiveEvent(int count) {
  internalBusBusy = 1;  // Rev13: claim the softWireMaster bus
  if (TinyWireS.available()) {
    i2cIndex = TinyWireS.read();
    if (i2cIndex >= I2C_LM75B_TEMPERATURE && i2cIndex <= I2C_LM75B_TOS) {  // mapped to LM75B's register
      softWireMaster.beginTransmission(ADDRESS_LM75B);
      softWireMaster.write(i2cIndex - I2C_LM75B_TEMPERATURE);
      if (i2cIndex == I2C_LM75B_CONF) {
        softWireMaster.write(TinyWireS.read());
      } else if (i2cIndex != I2C_LM75B_TEMPERATURE) {
        softWireMaster.write(TinyWireS.read());
        softWireMaster.write(TinyWireS.read());
      }
      softWireMaster.endTransmission();
    } else if (i2cIndex >= I2C_RTC_CTRL1 && i2cIndex <= I2C_RTC_TIMER_MODE) {  // mapped to RTC's register
      softWireMaster.beginTransmission(ADDRESS_RTC);
      softWireMaster.write(i2cIndex - I2C_RTC_CTRL1);
      softWireMaster.write(TinyWireS.read());
      softWireMaster.endTransmission();
    } else if (i2cIndex >= I2C_CONF_ADDRESS && i2cIndex < I2C_REG_COUNT) {  // non-virtual, writable i2c register
      if (TinyWireS.available()) {
        // clear alarm triggered flag if alam is changed
        // Rev15: any alarm-register write also arms alarmWriteHold - the
        // Pi writes each alarm as 4 separate transactions, and clearing
        // TRIGGERED at the first byte re-armed the OLD (still in-window)
        // alarm value for the duration of the rewrite; a WDT tick landing
        // in that window hard-cut power mid-boot. The hold pauses alarm
        // evaluation, refreshed per byte, expiring ~5s after the last
        // one - far longer than the rewrite takes. (Registers 27-36 are
        // contiguous: alarm1 then alarm2.)
        if (i2cIndex >= I2C_CONF_SECOND_ALARM1 && i2cIndex <= I2C_CONF_WEEKDAY_ALARM2) {
          alarmWriteHold = 5;
          if (i2cIndex <= I2C_CONF_WEEKDAY_ALARM1) {
            updateRegister(I2C_ALARM1_TRIGGERED, 0);
            // a rewritten alarm1 invalidates any pending delayed-start
            // state (stale alarm1Delayed caused a spurious wake 3s after
            // the next scheduled shutdown)
            alarm1Delayed = 0;
          } else {
            updateRegister(I2C_ALARM2_TRIGGERED, 0);
          }
        }

        // update the register value
        updateRegister(i2cIndex, TinyWireS.read());

        // if RTC offset value is changed, immediately update to RTC
        if (i2cIndex == I2C_CONF_RTC_OFFSET) {
          updateRegister(I2C_RTC_OFFSET, i2cReg[I2C_CONF_RTC_OFFSET]);
          writeToDevice(ADDRESS_RTC, I2C_RTC_OFFSET - I2C_RTC_CTRL1, &i2cReg[I2C_CONF_RTC_OFFSET], 1);
        }
      }
    }
  }
  internalBusBusy = 0;  // Rev13: release the softWireMaster bus
}


// i2c master requests data from this device (master reads from this device)
void requestEvent() {
  internalBusBusy = 1;  // Rev13: claim the softWireMaster bus
  switch (i2cIndex) {
    case I2C_VOLTAGE_IN_I:
      getInputVoltage();
      break;
    case I2C_VOLTAGE_OUT_I:
      getOutputVoltage();
      break;
    case I2C_CURRENT_OUT_I:
      getOutputCurrent();
      break;
    case I2C_POWER_MODE:
      updatePowerMode();
      break;
  }

  if (i2cIndex >= I2C_LM75B_TEMPERATURE && i2cIndex <= I2C_LM75B_TOS) {  // mapped to LM75B's register
    softWireMaster.beginTransmission(ADDRESS_LM75B);
    softWireMaster.write(i2cIndex - I2C_LM75B_TEMPERATURE);
    if (i2cIndex == I2C_LM75B_CONF) {
      softWireMaster.requestFrom(ADDRESS_LM75B, 1);
      TinyWireS.write(softWireMaster.read());
      softWireMaster.endTransmission();
    } else {
      softWireMaster.requestFrom(ADDRESS_LM75B, 2);
      TinyWireS.write(softWireMaster.read());
      TinyWireS.write(softWireMaster.read());
      softWireMaster.endTransmission();
    }
  } else if (i2cIndex >= I2C_RTC_CTRL1 && i2cIndex <= I2C_RTC_TIMER_MODE) {  // mapped to RTC's register
    softWireMaster.beginTransmission(ADDRESS_RTC);
    softWireMaster.write(i2cIndex - I2C_RTC_CTRL1);
    softWireMaster.requestFrom(ADDRESS_RTC, 1);
    TinyWireS.write(softWireMaster.read());
    softWireMaster.endTransmission();
  } else {
    TinyWireS.write(i2cReg[i2cIndex]);  // direct i2c register
  }
  internalBusBusy = 0;  // Rev13: release the softWireMaster bus
}


// watchdog interrupt routine
ISR (WDT_vect) {
  // turn off white LED after delay
  ledUpTime++;
  if (ledUpTime == 3) {
    ledUpTime = 0;
    ledOff();
  }

  // Rev15: SYS_UP boot watchdog. If the Pi has been powered for
  // SYS_UP_TIMEOUT_SECS without ever signalling SYS_UP, it hung before
  // the daemon could run - cut power and sleep so the still-in-window
  // alarm1 (or the next power event) retries the boot. Counted here,
  // before the internalBusBusy early-return, so busy ticks still count.
  // Normal boots reset this via PCINT1's SYS_UP branch within ~60s.
  // (Counter resets live in powerOn() and PCINT1's SYS_UP branch - it can
  // only tick inside one powered-but-not-up phase, so no else-reset needed.)
  if (powerIsOn && !systemIsUp && !turningOff) {
    sysUpWatchdog ++;
    if (sysUpWatchdog >= SYS_UP_TIMEOUT_SECS) {
      sysUpWatchdog = 0;
      updateRegister(I2C_ACTION_REASON, REASON_SYS_UP_TIMEOUT);
      armImmediateCut();
    }
  }

  // Rev13: if the Pi is mid-transaction on the internal softWireMaster
  // (via receiveEvent/requestEvent), skip RTC/LM75B touches this tick.
  // Bus collisions otherwise corrupt RTC reads and produce garbage time
  // / missed alarms (FIRMWARE_ISSUES.md #4). Cost: one missed WDT tick
  // (~1 second), which is harmless given the 86400s alarm match window.
  if (internalBusBusy) {
    return;
  }

  // process low voltage
  if (skipLowVoltageDetectCount < 250) {
    skipLowVoltageDetectCount ++;
  }
  processLowVoltageIfNeeded();



  // process RTC alarms
  processAlarmIfNeeded();

  // adjust RTC
  adjustRTCIfNeeded();

  // process delayed Alarm1 (startup)
  if (!powerIsOn && alarm1Delayed > 0) {
    alarm1Delayed ++;
    if (alarm1Delayed == 4) {
      alarm1Delayed = 0;
      updateRegister(I2C_ACTION_REASON, REASON_ALARM1_DELAYED);
      // Rev13: wake from sleep directly. Previously this called
      // emulateButtonClick() to trigger PCINT1's wake path.
      wakeupByWatchdog = false;
    }
  }

}


// pin state change interrupt routine for PCINT0_vect (PCINT0~7)
ISR (PCINT0_vect) {
  if (digitalRead(PIN_TX_UP) == 1) {
    if (!listenToTxd) {
      // start listen to TXD pin;
      listenToTxd = true;
    }
  } else {
    // Rev14 patch (2026-05-28d): require systemIsUp before treating a
    // TXD LOW as a Pi shutdown signal. Without this guard, the TXD
    // line glitching during early Pi boot (the line can be floating-
    // HIGH while Pi is off, then transition LOW briefly as the
    // bootloader configures GPIO-14 / UART_TXD) was triggering a
    // false shutdown ~0.5s after alarm1 powered the Pi on. The
    // daemon's SYS_UP pulse (PCINT1) sets systemIsUp = true once
    // the Pi has actually finished its critical-path boot, so by
    // then a TXD LOW genuinely means "Pi is shutting down". Until
    // then, ignore TXD edges as boot-time noise.
    if (listenToTxd && powerIsOn && systemIsUp) {
     listenToTxd = false;
     systemIsUp = false;
     turningOff = true;
     turnOffFromTXD = true;
     rebootGraceCount = 0;   // Rev15: fresh grace budget for this shutdown
     ledOff(); // turn off the white LED
     TCNT1 = getPowerCutPreloadTimer(true);
    }
  }
}


// pin state change interrupt routine for PCINT1_vect (PCINT8~15)
ISR (PCINT1_vect) {
  byte button = digitalRead(PIN_BUTTON);
  byte systemUp = digitalRead(PIN_SYS_UP);

  if (button != lastButton) {
    if (button == 0) {   // button is pressed, PCINT9
      if (!buttonPressed) {
        buttonPressed = true;
        // Rev13: physical button is intentionally inert while the Pi is
        // running. No shutdown is initiated regardless of how the press
        // arrives — this protects the device from accidental knocks or
        // shorts on the shared button/GPIO-4 line. Scheduled shutdowns
        // (alarm2, low voltage) bypass this path entirely and drive
        // turningOff + Timer1 directly.
        if (!powerIsOn) {
          // Manual wake from sleep is preserved as a maintenance override.
          ledOn();
          updateRegister(I2C_ACTION_REASON, REASON_CLICK);
          wakeupByWatchdog = false; // signal sleep loop to exit
        }
      }
    } else {  // button is released
      buttonPressed = false;
    }
  }

  if (systemUp != lastSystemUp) {
    if (systemUp == 0) {
      lastSystemUp = 0;
    } else if (!ledIsOn && powerIsOn && !turningOff && !systemIsUp) {  // system is up, PCINT8
      // clear the low-voltage shutdown flag when sys_up signal arrives
      updateRegister(I2C_LV_SHUTDOWN, 0);
      systemIsUp = true;
      sysUpWatchdog = 0;   // Rev15: Pi booted - disarm the boot watchdog
      lastSystemUp = 1;
    }
    // if guard failed (LED on), don't update lastSystemUp — retry on next PCINT trigger
  }

  lastButton = button;
}


// timer1 overflow interrupt routine
ISR (TIM1_OVF_vect) {
  if (powerCutDelay == 0) {
    // cut the power after delay
    TCNT1 = getPowerCutPreloadTimer(true);

    if (turningOff) {
      if (turnOffFromTXD && digitalRead(PIN_TX_UP) == 1) {  // if it is rebooting
        turningOff = false;
        // Rev14e: clear turnOffFromTXD here. Previously this branch left the
        // flag "sticky" — so the NEXT time turningOff was set (e.g. by alarm2
        // or LV shutdown), this branch would be re-entered as long as
        // PIN_TX_UP happened to be HIGH (which it normally is on a running
        // Pi), and cutPower() would never be called. Net effect: scheduled
        // shutdown silently no-ops once a reboot has been observed, until
        // the next clean cutPower()/loop-side reset.
        turnOffFromTXD = false;
        updateRegister(I2C_ACTION_REASON, REASON_REBOOT);
        ledOn();
      } else if (turnOffFromTXD && rebootGraceCount < 3) {
        // Rev15: TXD still LOW - but during a reboot the line floats
        // through the bootloader/GPU phase and can easily still be LOW
        // at the first sample. Give it up to 3 more POWER_CUT_DELAY
        // periods (~28s total with the 7s default) before deciding this
        // is a real shutdown. A single-sample miss here previously cut
        // power mid-reboot and the device slept until the next day's
        // alarm1 - triggered most often by checkInternet.sh's own
        // recovery reboot.
        rebootGraceCount ++;
        // TCNT1 was already reloaded above; just skip the cut this round.
      } else {  // cut the power and defer sleep to loop()
        // (rebootGraceCount re-arms at the next PCINT0 TXD shutdown)
        cutPower();
        // Rev13: do not call sleep() from inside this ISR. Sleep is a
        // long-running call that nests WDT/PCINT ISRs on top of the
        // Timer1 frame, risking SRAM exhaustion on the 512-byte ATtiny
        // (FIRMWARE_ISSUES.md #1). Set a flag and let loop() handle it
        // at base context, with the ISR stack already unwound.
        pendingSleep = true;
      }
    }
  } else {
    TCNT1 = getPowerCutPreloadTimer(false);

  }
}


// update I2C register and save to EEPROM
void updateRegister(byte index, byte value) {
  i2cReg[index] = value;
  // Rev15: never persist the live telemetry registers (Vin/Vout/Iout,
  // regs 1-6). ADC jitter changes them on nearly every measurement, so
  // EEPROM.update was rewriting those cells on almost every WDT tick
  // during sleep - exceeding the 100k-cycle endurance spec in weeks.
  if (index >= I2C_VOLTAGE_IN_I && index <= I2C_CURRENT_OUT_D) {
    return;
  }
  if (index < I2C_REG_COUNT) {
    EEPROM.update(index, value);
  }
}


// (Rev13: emulateButtonClick() removed. The function previously drove
// PIN_BUTTON LOW to trigger PCINT1 for two purposes:
//   - waking the Pi from sleep on alarm1 (now done via wakeupByWatchdog)
//   - signalling shutdown via the now-removed button shutdown path
// Driving the shared button/GPIO-4 line was risky on its own and the
// remaining functionality is achieved without it.)


// check wether alarm can be triggered
boolean canTriggerAlarm() {
  if (powerIsOn || i2cReg[I2C_POWER_MODE] == 0) {
    return true;
  }
  byte bk = ADCSRA;
  ADCSRA |= _BV(ADEN);
  float vin = getInputVoltage();
  ADCSRA = bk;
  float vlow = ((float)i2cReg[I2C_CONF_LOW_VOLTAGE]) / 10;
  if (i2cReg[I2C_LV_SHUTDOWN] == 1) {
    if (vin > vlow) {
      float vrec = ((float)i2cReg[I2C_CONF_RECOVERY_VOLTAGE]) / 10;
      if (i2cReg[I2C_CONF_RECOVERY_VOLTAGE] == 255 || vin > vrec) {
        return true;
      }
    }
  } else {
    if (vin > vlow || i2cReg[I2C_CONF_LOW_VOLTAGE] == 255) {
      return true;
    } else {
      // this will update the I2C_LV_SHUTDOWN flag when Vin drop under Vlow after shutdown
      updateRegister(I2C_LV_SHUTDOWN, 1);
    }
  }
  return false;
}


// (Rev15 note: a month-boundary wrap fix for the day-of-month-relative
// overdue calculation was prototyped but dropped for flash budget - the
// ATtiny841 is at 99% capacity. The residual gap: an alarm missed ON the
// last day of a month appears ~1 month in the future the next morning
// and won't catch up via the 86400s window. Bounded to one lost day by
// the Guaranteed Wake floor enforced at boot since Rev15.)


// process the alarm from RTC, if exists
void processAlarmIfNeeded() {
  // Rev15: skip alarm evaluation entirely while an alarm block rewrite is
  // in flight (see alarmWriteHold). Costs at most ~5s of match latency,
  // absorbed by the 86400s window.
  if (alarmWriteHold > 0) {
    alarmWriteHold --;
    return;
  }

  // get current time from RTC
  byte seconds = bcd2dec(readFromDevice(ADDRESS_RTC, I2C_RTC_SECONDS - I2C_RTC_CTRL1) & 0x7F);
  byte minutes = bcd2dec(readFromDevice(ADDRESS_RTC, I2C_RTC_MINUTES - I2C_RTC_CTRL1));
  byte hours = bcd2dec(readFromDevice(ADDRESS_RTC, I2C_RTC_HOURS - I2C_RTC_CTRL1));
  byte date = bcd2dec(readFromDevice(ADDRESS_RTC, I2C_RTC_DAYS - I2C_RTC_CTRL1));
  long cur_ts = getTimestamp(date, hours, minutes, seconds);

  // get startup (alarm1) time
  seconds = bcd2dec(i2cReg[I2C_CONF_SECOND_ALARM1]);
  minutes = bcd2dec(i2cReg[I2C_CONF_MINUTE_ALARM1]);
  hours = bcd2dec(i2cReg[I2C_CONF_HOUR_ALARM1]);
  date = bcd2dec(i2cReg[I2C_CONF_DAY_ALARM1]);
  long alarm1_ts = getTimestamp(date, hours, minutes, seconds);

  // get shutdown (alarm2) time
  seconds = bcd2dec(i2cReg[I2C_CONF_SECOND_ALARM2]);
  minutes = bcd2dec(i2cReg[I2C_CONF_MINUTE_ALARM2]);
  hours = bcd2dec(i2cReg[I2C_CONF_HOUR_ALARM2]);
  date = bcd2dec(i2cReg[I2C_CONF_DAY_ALARM2]);
  long alarm2_ts = getTimestamp(date, hours, minutes, seconds);

  boolean canTrigger = canTriggerAlarm();
  boolean alarm1HasTriggered = (alarm1_ts == 0 || i2cReg[I2C_ALARM1_TRIGGERED] == 1);
  boolean alarm2HasTriggered = (alarm2_ts == 0 || i2cReg[I2C_ALARM2_TRIGGERED] == 1);

  long overdue_alarm1 = cur_ts - alarm1_ts;
  long overdue_alarm2 = cur_ts - alarm2_ts;

  // Rev13: widened overdue window from 4s to 86400s (one day). Catches
  // alarms missed due to WDT timing jitter or interrupted register writes
  // that left a partial state. With Pi-side Guaranteed Wake enabled at
  // 24h, any alarm older than 1 day will be superseded by guaranteed
  // wake recovery, so the wider window can't fire ancient stale state.
  if (canTrigger && !alarm1HasTriggered && overdue_alarm1 >= 0 && overdue_alarm1 < 86400) {  // Alarm 1: startup
    updateRegister(I2C_ALARM1_TRIGGERED, 1);
    updateRegister(I2C_CONF_FLAG_ALARM1, 1);
    if (!powerIsOn) {
      updateRegister(I2C_ACTION_REASON, REASON_ALARM1);
      // Rev14 patch (2026-05-28d): suppress any stale alarm2 across the
      // wake. The alarm2 registers still hold the previous shutdown
      // time-of-day, and the widened 86400s match window means alarm2
      // would re-match on the first WDT tick after powerOn(). Without
      // this guard, that match fires turningOff=true; TCNT1=65534; and
      // Timer1 cuts power within milliseconds - the Pi's power LED
      // comes on briefly then goes dark and the device never boots.
      // The daemon's next alarm2 register write will clear this flag
      // via receiveEvent, so normal scheduled shutdowns still work.
      updateRegister(I2C_ALARM2_TRIGGERED, 1);
      // Rev13: wake from sleep directly. Previously emulateButtonClick()
      // pulsed PIN_BUTTON to trigger PCINT1's wake handler.
      wakeupByWatchdog = false;
    } else {
      // power is not cut yet, will power on later if alarm1 delay is allowed
      if ((i2cReg[I2C_CONF_MISC] & 0x01) == 0) {
        alarm1Delayed = 1;
      }
    }
  } else if (canTrigger && !alarm2HasTriggered && overdue_alarm2 >= 0 && overdue_alarm2 < 86400) {  // Alarm 2: shutdown
    updateRegister(I2C_ALARM2_TRIGGERED, 1);
    updateRegister(I2C_CONF_FLAG_ALARM2, 1);
    if (powerIsOn && !turningOff) {
      updateRegister(I2C_ACTION_REASON, REASON_ALARM2);
      // Rev13: shut down without touching PIN_BUTTON. Setting turningOff
      // and arming Timer1 is sufficient - Timer1's overflow ISR will call
      // cutPower() and defer sleep() to loop(). The button line is no
      // longer manipulated for shutdown so a noisy GPIO-4 share is safe.
      // (armImmediateCut also clears turnOffFromTXD - Rev14e fix - so
      // this path can never be diverted into the Timer1 reboot branch.)
      armImmediateCut();
    }
  } else if (!alarm1HasTriggered && overdue_alarm1 < 0 && overdue_alarm1 >= -2) {
    reset_rtc_alarm();
    copyAlarm(I2C_CONF_SECOND_ALARM1);
  } else if (!alarm2HasTriggered && overdue_alarm2 < 0 && overdue_alarm2 >= -2) {
    reset_rtc_alarm();
    copyAlarm(I2C_CONF_SECOND_ALARM2);
  }
}


// enable alarm and clear the alarm flag (if exists)
void reset_rtc_alarm() {
  byte data = 0x80;
  writeToDevice(ADDRESS_RTC, 0x01, &data, 1);
}


// copy alarm data to RTC's alarm registers
void copyAlarm(byte offset) {
  for (byte i = 0; i < 5; i ++) {
    writeToDevice(ADDRESS_RTC, 0x0B + i, &i2cReg[offset + i], 1);
  }
}



// process low voltage
void processLowVoltageIfNeeded() {
  lowVoltageCacheInteger = 0;
  // do not detect low voltage too soon since power on
  if (skipLowVoltageDetectCount < 250) {
    return;
  }
  // if input voltage is not fixed 5V, detect low voltage
  if (powerIsOn
      && (i2cReg[I2C_POWER_MODE] == 1 || i2cReg[I2C_CONF_IGNORE_POWER_MODE] == 1)
      && (i2cReg[I2C_LV_SHUTDOWN] == 0 || i2cReg[I2C_CONF_IGNORE_LV_SHUTDOWN] == 1)
      && i2cReg[I2C_CONF_LOW_VOLTAGE] != 255) {
    float vin = getInputVoltage();
    float vlow = ((float)i2cReg[I2C_CONF_LOW_VOLTAGE]) / 10;
    if (vin < vlow) {  // input voltage is below the low voltage threshold
      lowVoltageCacheInteger = i2cReg[I2C_VOLTAGE_IN_I];
      lowVoltageCacheDecimal = i2cReg[I2C_VOLTAGE_IN_D];
      updateRegister(I2C_LV_SHUTDOWN, 1);
      updateRegister(I2C_ACTION_REASON, REASON_LOW_VOLTAGE);
      // Rev13: same direct shutdown pattern as alarm2 - no PIN_BUTTON pulse.
      armImmediateCut();
    }
  }
}



// software I2C master read data from device on internal I2C bus
byte readFromDevice(byte address, byte index) {
  softWireMaster.beginTransmission(address);
  softWireMaster.write(index);
  softWireMaster.requestFrom((int)address, 1);
  byte data = softWireMaster.read();
  softWireMaster.endTransmission();
  return data;
}


// software I2C master write data to device on internal I2C bus
void writeToDevice(byte address, byte index, byte* data, byte count) {
  softWireMaster.beginTransmission(address);
  softWireMaster.write(index);
  for (byte i = 0; i < count; i ++) {
    softWireMaster.write(data[i]);
  }
  softWireMaster.endTransmission();
}


// convert BCD data to DEC data
byte bcd2dec(byte bcd) {
  return (bcd / 16 * 10) + (bcd % 16);
}


// get timestamp for given date and time
long getTimestamp(byte date, byte hours, byte minutes, byte seconds) {
  return (long)date * 86400 + (long)hours * 3600 + (long)minutes * 60 + seconds;
}




// adjust the RTC with offset value and the temperature compensation data (when TC is enabled)
void adjustRTCIfNeeded() {
  skipAdjustRtcCount ++;
  if (skipAdjustRtcCount == 255) {  // no need to adjust too frequently
    skipAdjustRtcCount = 0;

    if (i2cReg[I2C_CONF_RTC_ENABLE_TC] == 1) {
      char t = readFromDevice(ADDRESS_LM75B, 0);
      char adj = 0;
      if (t < 26) {
        adj = (t - 26) * 0.1267f;
      } else if (t > 32 && t <= 42) {
        adj = (t - 32) * -0.0922f;
      } else if (t > 42) {
        adj = -0.922f + (t - 42) * -0.2765f;
      }
      // inline offset2Value then value2Offset
      byte os = i2cReg[I2C_CONF_RTC_OFFSET];
      char ov = ((os & 0x40) == 0) ? (os & 0x3F) : ((os & 0x3F) - 0x40);
      char nv = ov + adj;
      byte data = (nv >= 0) ? (byte)nv : (0x80 + nv);
      writeToDevice(ADDRESS_RTC, I2C_RTC_OFFSET - I2C_RTC_CTRL1, &data, 1);
    } else {
      writeToDevice(ADDRESS_RTC, I2C_RTC_OFFSET - I2C_RTC_CTRL1, &i2cReg[I2C_CONF_RTC_OFFSET], 1);
    }
  }
}


