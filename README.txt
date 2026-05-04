================================================================
  DayBlocker EA for MT5 — TWP ORB EA Companion
  Disables AutoTrading on dangerous news days
  Version 1.20 | May 2026
================================================================

WHAT IT DOES
============
This EA monitors the MQL5 economic calendar and a manual blocked
dates file. When it detects a dangerous event scheduled for today,
it disables AutoTrading globally (affects ALL charts/EAs on the
terminal). It re-enables AutoTrading the next day after a
configurable broker-time hour (default: 01:00 broker time).

The default configuration blocks only Flash PMI days — the one
event proven to crash grid-based EAs like TWP ORB EA in backtesting.

WHY FLASH PMI?
==============
In 16 months of backtesting across 8 pairs with real ticks:
- FOMC, CPI, NFP, ISM, GDP, PPI — grid survived and recovered
- Flash PMI — grid went 10 entries deep and wiped the account

Flash PMI is uniquely dangerous because EUR and USD PMIs almost
always release on the same day (42 out of 53 occurrences). EUR PMIs
hit at 07:15-08:30 UTC, then USD PMIs follow at 13:45 UTC — two
waves of one-directional volatility that grids can't recover from
between waves.

By blocking this one day per month (~12 days/year), you avoid the
only event that killed accounts while keeping all other profitable
trading days open.

INSTALLATION
============
1. Copy DayBlocker.mq5 to your MT5 MQL5/Experts/ folder
2. Open MetaEditor and compile DayBlocker.mq5
3. Copy blocked_dates.txt to your MT5 MQL5/Files/ folder
4. Open a NEW, SEPARATE chart in MT5 (see note below)
5. Drag DayBlocker EA onto that chart
6. IMPORTANT: Check "Allow DLL imports" in the popup dialog
   (required for toggling the AutoTrading button)
7. Load the DayBlocker.set file or configure manually
8. Only ONE instance needed — it controls AutoTrading globally

IMPORTANT — SEPARATE CHART REQUIRED:
  MT5 only allows ONE EA per chart. You cannot attach DayBlocker
  to the same chart as TWP ORB EA or any other EA.

  Open a new chart (any symbol, any timeframe) and attach
  DayBlocker there. I recommend using a 24/7 symbol like ETHUSD
  or BTCUSD — these always have tick activity which keeps the
  EA's timer running reliably even outside forex market hours.

  Example setup:
    Chart 1: EURUSD M5  → TWP ORB EA
    Chart 2: EURCAD M5  → TWP ORB EA
    Chart 3: ETHUSD M1  → DayBlocker EA  (separate, always active)

TIMEZONE / BROKER COMPATIBILITY
===============================
The EA auto-detects your broker's GMT offset on startup by
comparing TimeCurrent() vs TimeGMT(). If auto-detection fails
(some brokers return broken TimeGMT values), it falls back to
the manual InpBrokerGMTOffset input.

On startup you'll see one of these log messages:
  "Auto-detected broker GMT offset: +3"     (working correctly)
  "TimeGMT() unreliable, using manual: +3"  (fallback to input)

Common broker offsets:
  Coinexx     = GMT+3 (summer) / GMT+2 (winter)
  EXNESS      = GMT+0
  OX Securities = GMT+2
  GTC Global  = GMT+3

If you see wrong blocking times, check this setting first.

The MQL5 calendar events are always in UTC internally — the broker
offset is only needed for the re-enable timing logic.

SETTINGS
========
Event Blocking:
  Block Flash PMI days          = true  (RECOMMENDED: keep ON)
  Block ALL Trump Speaks days   = false (86 events/16mo — too many!)
  Block FOMC Rate Decision days = false (grid recovers from these)
  Block Non-Farm Payrolls days  = false (grid recovers from these)
  Block CPI days                = false (grid recovers from these)
  Block GDP days                = false (grid recovers from these)
  Block PPI days                = false (grid recovers from these)
  Block FOMC Minutes days       = false (grid recovers from these)
  Block Fed Chair Powell days   = false (grid recovers from these)
  Block ISM Manufacturing days  = false (grid recovers from these)
  Block Retail Sales days       = false (grid recovers from these)
  Block Empire State Mfg days   = false (grid recovers from these)

All event toggles are simple on/off checkboxes. You can enable
more events if you prefer extra safety — the tradeoff is fewer
trading days.

Manual Block File:
  Use blocked_dates.txt         = true
  Path to blocked dates file    = blocked_dates.txt (in MQL5/Files/)

Currency Filter:
  Currencies                    = USD,EUR

Timing:
  Check interval                = 60 seconds
  Broker GMT offset (fallback)  = 3 (auto-detected if possible)
  Re-enable hour (broker time)  = 1 (01:00 broker = ~22:00 UTC on GMT+3)
  Auto re-enable next day       = true

  The re-enable logic works as follows:
  1. When a block triggers, it records today's broker date
  2. On each timer check, it looks for: new broker day + past the hour
  3. Before re-enabling, it confirms today (UTC) has no blocked events
  4. Safety fallback: if stuck >24h, forces re-enable regardless

  This is restart-safe — if the EA restarts mid-block, it will
  re-check today's events and re-block if needed, or stay clear
  if the blocked day has passed.

Testing:
  TEST MODE                     = false (set true to test blocking)
  DRY RUN                       = false (set true to log without toggling)

MANUAL BLOCKED DATES (blocked_dates.txt)
========================================
For events that can't be auto-detected (Trump tariff announcements,
elections, geopolitical events), add dates to the blocked_dates.txt
file in your MQL5/Files/ folder.

Format:
  - One date per line: YYYY-MM-DD
  - Lines starting with # are comments (ignored)
  - Text after the date is ignored (use for notes)

Example blocked_dates.txt:
  # Trump tariff events
  2025-04-02  Trump reciprocal tariffs announcement
  2025-04-08  Trump trade war escalation
  # Elections
  2025-07-21  Japan Upper House Election (block Monday)
  2025-11-04  US Election Day

Review the upcoming week's news every Sunday night. If you see a
major tariff announcement, election, or geopolitical event, add
that date to the file. The EA picks it up automatically on the
next check cycle (every 60 seconds).

TESTING
=======
Before going live, test the EA:

1. Set TEST MODE = true, DRY RUN = false
2. The AutoTrading button should turn OFF
3. The panel should show red "TRADING DISABLED"
4. Set TEST MODE = false — AutoTrading should re-enable

For safe testing without actually toggling AutoTrading:
1. Set TEST MODE = true, DRY RUN = true
2. Check the Experts log — it will say "Would disable AutoTrading"
3. No actual toggling occurs

PANEL DISPLAY
=============
The EA shows a small panel in the top-left corner:

  Green: "DAY-BLOCKER: ACTIVE (trading allowed)"
    — Normal operation, no blocked events today

  Red: "DAY-BLOCKER: TRADING DISABLED"
    — Blocked event detected, AutoTrading is OFF
    — Shows the reason and when it will re-enable
    — Expandable news list shows today's USD/EUR events

IMPORTANT NOTES
===============
- Requires "Allow DLL imports" — uses Windows user32.dll to toggle
  the AutoTrading button via PostMessageA
- Only works on Windows (not Mac/Linux) due to DLL dependency
- Only needs ONE instance on ONE chart — it's global
- If you remove the EA, it automatically re-enables AutoTrading
- The EA does NOT close existing positions — it only prevents
  NEW trades from being opened
- Works alongside the TWP ORB EA's built-in news filter (H±30min)
  as an additional layer of protection
- Restart-safe: if the EA or terminal restarts, it re-checks
  today's events and re-blocks or stays clear as appropriate

CHANGELOG
=========
v1.20 (May 2026)
  - FIXED: Re-enable timing — was using TimeGMT() which is broken
    on Coinexx (returned broker time). Now auto-detects broker GMT
    offset and falls back to manual input if detection fails.
  - FIXED: Flash PMI matching was too broad — "S&P Global
    Manufacturing PMI" matched both Flash and Final releases.
    Tightened to only match "Flash" or "S&P Global Flash" variants.
  - CHANGED: Re-enable hour is now in BROKER time (default 1 = 01:00)
    instead of UTC. Simpler and more reliable.
  - ADDED: Broker GMT offset auto-detection on startup
  - ADDED: 24h safety fallback — if stuck blocked for >24h, forces
    re-enable regardless
  - ADDED: Restart-safe blocked date tracking

v1.10 (April 2026)
  - Fixed alert spam (firing every 60 seconds)
  - Fixed calendar log spam (was logging every timer tick)
  - Added expandable news panel with color-coded events
  - Panel renders immediately on init (was waiting 60s for timer)

v1.00 (April 2026)
  - Initial release

SOURCE CODE
===========
Full source code is provided in DayBlocker.mq5. You are free to
inspect, modify, and share it. Consider having AI review the code
if you want to verify its behavior before using it.

DISCLAIMER
==========
This EA is provided as-is with no warranty. Backtest results do
not guarantee future performance. Always test on a demo account
first. Use at your own risk.
================================================================
