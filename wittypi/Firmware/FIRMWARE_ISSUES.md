# WittyPi 4 Firmware Issue Review

**Firmware:** WittyPi4.ino (Revision 7, ID 0x26)  
**Target MCU:** ATtiny841 (512 bytes SRAM)  
**Source:** https://github.com/uugear/Witty-Pi-4/tree/main/Firmware/WittyPi4  
**Review Date:** 2026-04-11  
**Patched Firmware:** `Firmware/WittyPi4/WittyPi4.ino` (now at **Rev 12** — this document covers the original Rev 7 audit and the Rev 10 fixes; subsequent Rev 11/12 changes are described in `PROJECT_CONTEXT.md`)

---

## Critical Issues

### 1. `sleep()` called from inside Timer1 ISR — stack corruption / hang risk

**Location:** `ISR(TIM1_OVF_vect)` and `forcePowerCutIfNeeded()`

**Description:**  
The Timer1 overflow ISR calls `sleep()` directly, both in the `turningOff` path and via `forcePowerCutIfNeeded()`. `sleep()` is a long-running function that:

- Re-enables interrupts with `sei()`
- Enters a `do/while` sleep loop
- Performs I2C communication (software I2C via `softWireMaster`)
- Calls `delay()`, `ledOn()`/`ledOff()`, `updatePowerMode()`
- Eventually calls `powerOn()` on wake

This means:

- The Timer1 ISR return address remains on the stack the entire time the MCU is asleep
- The WDT ISR fires during sleep (that's how the sleep loop works), creating nested ISR contexts
- The WDT ISR itself calls `emulateButtonClick()`, `processAlarmIfNeeded()` (I2C), and `adjustRTCIfNeeded()` (more I2C) — all stacking on top of the Timer1 ISR frame
- On an ATtiny841 with only 512 bytes of SRAM, this nesting can overflow the stack

**Symptoms:** Random hangs, failure to wake up, failure to shut down, unpredictable behavior after power cycling.

**Likely root cause of startup/shutdown failures.**

**Recommended Fix:** Set a flag in the Timer1 ISR and handle the sleep transition in `loop()` or via a state machine running outside ISR context.

---

### 2. Missing `endTransmission()` for LM75B CONF register read

**Location:** `requestEvent()`, LM75B CONF branch

**Description:**  
When the Raspberry Pi reads the LM75B configuration register (virtual register I2C_LM75B_CONF), the code calls `beginTransmission()` but never calls `endTransmission()`:

```cpp
if (i2cIndex == I2C_LM75B_CONF) {
  softWireMaster.requestFrom(ADDRESS_LM75B, 1);
  TinyWireS.write(softWireMaster.read());
  // endTransmission() is MISSING
} else {
  softWireMaster.requestFrom(ADDRESS_LM75B, 2);
  TinyWireS.write(softWireMaster.read());
  TinyWireS.write(softWireMaster.read());
  softWireMaster.endTransmission();  // only called for non-CONF
}
```

This leaves the internal I2C bus in an undefined state.

**Symptoms:** Subsequent I2C transactions to the LM75B or RTC may fail, causing incorrect temperature readings, missed alarms, or spurious voltage-based shutdowns/recoveries.

---

### 3. EEPROM writes inside ISRs — blocking delays

**Location:** `updateRegister()` called from WDT ISR, Timer1 ISR, and pin change ISRs

**Description:**  
`updateRegister()` calls `EEPROM.update()`, which takes approximately 3.4ms when the value has changed. This is called from multiple interrupt contexts:

- WDT ISR via `processAlarmIfNeeded()`, `processLowVoltageIfNeeded()`, `handleTemperatureActtonsIfNeeded()`
- Timer1 ISR via the `forcePowerCutIfNeeded()` -> `sleep()` path
- Pin change ISRs (PCINT0_vect, PCINT1_vect)

**Symptoms:** A 3.4ms block inside an ISR can cause missed I2C transactions from the Raspberry Pi (I2C clock timeout), missed pin change interrupts, and incorrect power-cut timing.

---

## High-Severity Issues

### 4. Software I2C operations in WDT ISR — bus collision

**Location:** `ISR(WDT_vect)` -> `processAlarmIfNeeded()` -> `readFromDevice()` -> `softWireMaster`

**Description:**  
The WDT ISR performs I2C transactions using `softWireMaster`. If the WDT fires while the main `requestEvent()` or `receiveEvent()` callback is mid-transaction on the same `softWireMaster` instance, the I2C bus state is corrupted.

**Symptoms:** RTC returns garbage time values, causing alarms to fire at wrong times or never fire. Temperature reads may return incorrect values, leading to spurious temperature-based shutdowns.

---

### 5. 180-second brownout vulnerability window

**Location:** `processLowVoltageIfNeeded()`

**Description:**  
Low voltage detection is disabled for the first 180 seconds (3 minutes) after power-on:

```cpp
if (skipLowVoltageDetectCount < 180) {
    return;
}
```

The counter increments once per second via the WDT ISR. During this window, if input voltage drops (e.g., battery sag under boot load), the Raspberry Pi can experience brownout.

**Symptoms:** SD card corruption during boot if input voltage drops below safe operating levels within the first 3 minutes.

---

### 6. `copyAlarm` only writes 4 of 5 alarm registers to RTC

**Location:** `copyAlarm()`

**Description:**  
The PCF85063 RTC has 5 alarm registers at addresses 0x0B-0x0F (Second, Minute, Hour, Day, Weekday). The function only writes 4:

```cpp
void copyAlarm(byte offset) {
  for (byte i = 0; i < 4; i ++) {  // should be i < 5
    writeToDevice(ADDRESS_RTC, 0x0B + i, &i2cReg[offset + i], 1);
  }
}
```

The Weekday alarm register (0x0F) is never written to the RTC.

**Symptoms:** Weekday-based alarms may not fire correctly via the RTC alarm interrupt. The pre-loading mechanism for upcoming alarms (the `overdue < 0 && overdue >= -2` path in `processAlarmIfNeeded()`) won't set up the RTC alarm properly.

---

## Moderate Issues

### 7. EEPROM 255 sentinel conflicts with valid register values

**Location:** `initializeRegisters()`

**Description:**  
The code uses 255 as a sentinel for "uninitialized EEPROM":

```cpp
byte val = EEPROM.read(i);
if (val == 255) {
  EEPROM.update(i, i2cReg[i]);  // write default
} else {
  i2cReg[i] = val;  // use stored value
}
```

However, 255 is a valid value for several registers. For example, `I2C_CONF_ADJ_VIN` (index 24) interpreted as a signed byte: 255 = -1, meaning -0.01V adjustment. A user-set value of 255 would be treated as uninitialized on next boot and silently reset to the default (20).

**Affected registers:** Any writable register where 255 is a meaningful user-configured value (adjustment registers in particular).

---

### 8. RTC offset overflow in temperature compensation

**Location:** `adjustRTCIfNeeded()`

**Description:**  
The temperature compensation calculates an adjustment value `adj` and adds it to the base offset:

```cpp
byte data = value2Offset(offset2Value(i2cReg[I2C_CONF_RTC_OFFSET]) + adj);
```

- `offset2Value()` returns a value in the range -64 to +63 (7-bit two's complement)
- `adj` can range from approximately 0 to -13 at extreme temperatures
- If the sum exceeds the -64 to +63 range, `value2Offset()` silently wraps to an incorrect value

**Symptoms:** RTC drift at extreme temperatures when combined with a large user-configured offset.

---

### 9. Non-atomic multi-variable state transitions

**Location:** Multiple ISRs (PCINT0_vect, PCINT1_vect, WDT_vect)

**Description:**  
State transitions involve setting multiple volatile variables sequentially:

```cpp
turningOff = true;
systemIsUp = false;
```

This pattern appears in PCINT0_vect, PCINT1_vect, and indirectly in the WDT ISR. An interrupt can fire between the two assignments, observing an inconsistent state where both `turningOff` and `systemIsUp` are true.

**Symptoms:** Shutdown sequence may execute twice, or a shutdown may not complete correctly if the intermediate state triggers conflicting logic in another ISR.

---

## Critical — User-Identified Issues

### 10. TXD shutdown path never cuts power — `systemIsUp` deadlock

**Location:** `ISR(PCINT0_vect)` (TXD detection) and `ISR(TIM1_OVF_vect)` (power cut timer)

**Description:**  
When the firmware detects the Raspberry Pi has shut down via the TXD pin going low, `ISR(PCINT0_vect)` sets `turningOff = true` and `systemIsUp = false`, then resets the Timer1 countdown via `TCNT1 = getPowerCutPreloadTimer(true)`:

```cpp
// ISR(PCINT0_vect) — TXD goes low
if (listenToTxd && systemIsUp) {
  listenToTxd = false;
  systemIsUp = false;
  turningOff = true;
  turnOffFromTXD = true;
  ledOff();
  TCNT1 = getPowerCutPreloadTimer(true);
}
```

The power cut depends on Timer1 counting down `powerCutDelay` to zero. However, `systemIsUp` is set to false immediately, before the power cut countdown completes. If any downstream logic requires `systemIsUp == true` to complete the shutdown (as seen in other firmware variants with `cutPowerIfNeeded()`), the system enters a deadlock: power is never cut because the function is waiting for a condition that can never be satisfied.

In revision 7, the `ISR(TIM1_OVF_vect)` does check `turningOff` directly (not `systemIsUp`) for the final power cut, which partially mitigates this. However, the premature clearing of `systemIsUp` still creates a window where the system is in an inconsistent state — it believes the Pi is down but hasn't yet cut power, and other ISRs (WDT) that check `systemIsUp` will behave as if the system is off while 5V is still being supplied.

**Symptoms:** System hangs with power still on after Pi shutdown. The Pi is off but WittyPi never cuts 5V and never enters sleep, draining the battery indefinitely.

**Status: MITIGATED in Rev 10** — WDT-based 36-second safety timeout forces `cutPower()` if `turningOff` remains stuck. See Rev 10 changelog.

---

### 11. `turningOff` flag blocks `systemIsUp` recovery — permanent shutdown deadlock

**Location:** `ISR(PCINT1_vect)`, SYS_UP detection guard

**Description:**  
The SYS_UP detection in `ISR(PCINT1_vect)` has a guard that prevents `systemIsUp` from being set while `turningOff` is true:

```cpp
if (!ledIsOn && powerIsOn && !turningOff && !systemIsUp && systemUp == 1) {
  updateRegister(I2C_LV_SHUTDOWN, 0);
  systemIsUp = true;
}
```

This creates a deadly sequence:

1. **Shutdown initiates** (button click, alarm2, or TXD detection) — sets `turningOff = true` and `systemIsUp = false`
2. **Pi hasn't actually shut down yet** — takes several seconds to complete its shutdown sequence
3. **SYS_UP pin is still HIGH** during this period (Pi is still running)
4. **PCINT1_vect fires** (due to noise on the button pin, or any PCINT1 source) — reads `systemUp == 1` from the SYS_UP pin
5. **The guard condition FAILS** because `turningOff == true` — so `systemIsUp` is never set back to true
6. **Timer1 overflow fires** — `turningOff` is true, so it proceeds to the power cut path. If it's a TXD-initiated shutdown (`turnOffFromTXD == true`) and `PIN_TX_UP` reads HIGH (Pi is rebooting or still up), it clears `turningOff` and treats it as a reboot. **But if the timing is wrong** — the TXD pin is momentarily low during shutdown — the firmware cuts power and sleeps while the Pi may still be writing to the SD card.

The deeper issue: once `turningOff` is set, there is **no recovery path** that re-establishes `systemIsUp = true`. If anything interrupts or delays the Timer1 power-cut countdown (e.g., `forcePowerCutIfNeeded()` calling `sleep()` from ISR context — issue #1), the system can get permanently stuck with `turningOff = true`, `systemIsUp = false`, and power still on.

**Symptoms:**
- System never cuts power after a shutdown command, draining the battery
- SD card corruption if power is cut while the Pi is mid-write during its shutdown sequence
- After a failed shutdown attempt, the system cannot re-detect SYS_UP, making it unresponsive to future startup/shutdown cycles until a hard power cycle

**Status: MITIGATED in Rev 10** — The 36-second turningOff timeout forces `cutPower()` and resets all state flags (`turningOff`, `turnOffFromTXD`, `systemIsUp`), breaking the deadlock. After timeout, the MCU remains awake (does not call `sleep()` to avoid issue #1) at higher idle power until the next alarm or button press triggers a normal cycle. Root cause (premature `systemIsUp` clearing and missing recovery path) remains in the code but cannot cause permanent deadlock.

---

## Rev 10 Verification Summary

All 18 review checks passed (agent review, 2026-04-11):

| Category | Checks | Result |
|----------|--------|--------|
| Timeout mechanism correctness | 5 checks | All PASS |
| Shutdown path regressions (6 paths) | 7 checks | All PASS |
| Edge cases (double-cut, ISR concurrency, post-timeout wake, margin) | 4 checks | All PASS |
| SRAM impact | 2 checks | All PASS |

**Advisory:** After the safety timeout fires, the MCU runs at full power (not power-down sleep) until the next wake/sleep cycle. This is the correct tradeoff vs. calling `sleep()` from ISR context (issue #1).

---

## Architecture Notes

- `loop()` is empty — all logic runs in ISRs (WDT, Timer1, pin change) and the `setup()` function
- The shared `softWireMaster` instance is used from both ISR and non-ISR contexts without locking
- PIN_SYS_UP and PIN_LED share physical pin 0 (dual-purpose by hardware design); the `!ledIsOn` guard in PCINT1_vect mitigates false SYS_UP detection, but the ordering of `ledIsOn` flag vs pin state changes creates small race windows
