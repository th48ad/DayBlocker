//+------------------------------------------------------------------+
//| DayBlocker.mq5 — Disable AutoTrading on dangerous news days      |
//| Checks MQL5 economic calendar + manual blocked_dates.txt          |
//| When a blocked event is found for today, disables AutoTrading     |
//| globally. Re-enables at session end or next non-blocked day.      |
//+------------------------------------------------------------------+
#property copyright "Thomas Hill (hill0795@gmail.com)"
#property version   "1.10"
#property link      "mailto:hill0795@gmail.com"
#property description "Blocks AutoTrading on Flash PMI days, Trump tariff days, and custom dates"
#property strict

//--- Windows API for toggling AutoTrading button
#import "user32.dll"
int PostMessageA(int hWnd, int Msg, int wParam, int lParam);
int GetAncestor(int hWnd, int nFlags);
#import

#define WM_COMMAND 0x0111
#define MT5_AUTOTRADING_CMD 32851
#define GA_ROOT 2

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "═══ Event Blocking ═══"
input bool   InpBlockFlashPMI          = true;    // Block Flash PMI days (US + EUR)
input bool   InpBlockTrumpSpeaks       = false;   // Block ALL Trump Speaks days (too many!)
input bool   InpBlockFOMCDecision      = false;   // Block FOMC Rate Decision days
input bool   InpBlockNFP               = false;   // Block Non-Farm Payrolls days
input bool   InpBlockCPI               = false;   // Block CPI days
input bool   InpBlockGDP               = false;   // Block GDP days
input bool   InpBlockPPI               = false;   // Block PPI days
input bool   InpBlockFOMCMinutes       = false;   // Block FOMC Minutes days
input bool   InpBlockPowellSpeaks      = false;   // Block Fed Chair Powell days
input bool   InpBlockISM               = false;   // Block ISM Manufacturing PMI days
input bool   InpBlockRetailSales       = false;   // Block Retail Sales days
input bool   InpBlockEmpireState       = false;   // Block Empire State Mfg Index days

input group "═══ Manual Block File ═══"
input bool   InpUseBlockFile           = true;    // Use blocked_dates.txt file
input string InpBlockFilePath          = "blocked_dates.txt"; // Path to blocked dates file (in MQL5/Files/)

input group "═══ Currency Filter ═══"
input string InpCurrencies             = "USD,EUR"; // Currencies to check (comma-separated)

input group "═══ Timing ═══"
input int    InpCheckIntervalSec       = 60;      // Check interval (seconds)
input int    InpBrokerGMTOffset        = 3;       // Broker GMT offset FALLBACK (Coinexx=3, EXNESS=0). Auto-detected if possible.
input int    InpReEnableHour           = 1;       // Re-enable hour in BROKER time (next day). E.g. 1 = 01:00 broker = 22:00 UTC on GMT+3
input bool   InpReEnableNextDay        = true;    // Auto re-enable on next non-blocked day

input group "═══ Testing ═══"
input bool   InpTestMode               = false;   // TEST MODE: Block today regardless of news
input bool   InpDryRun                 = false;   // DRY RUN: Log only, don't actually toggle AutoTrading

input group "═══ Display ═══"
input bool   InpShowPanel              = true;    // Show status panel
input color  InpBlockedColor           = clrRed;  // Panel color when blocked
input color  InpActiveColor            = clrLime; // Panel color when active

//+------------------------------------------------------------------+
//| GLOBALS                                                           |
//+------------------------------------------------------------------+
// Reliable UTC: auto-detect broker offset if possible, fall back to manual input
int g_brokerGMTOffset = 0;
bool g_offsetDetected = false;

void DetectBrokerGMTOffset()
{
    datetime broker = TimeCurrent();
    datetime gmt = TimeGMT();
    int diffSeconds = (int)(broker - gmt);

    // If TimeGMT() works, diff should be the broker offset (e.g. 10800 for GMT+3)
    // If TimeGMT() is broken (returns broker time), diff ≈ 0
    if(MathAbs(diffSeconds) > 60)
    {
        // TimeGMT() works — auto-detected
        g_brokerGMTOffset = (int)MathRound((double)diffSeconds / 3600.0);
        g_offsetDetected = true;
        Print("[DayBlocker] Auto-detected broker GMT offset: +", g_brokerGMTOffset);
    }
    else
    {
        // TimeGMT() broken — use manual input
        g_brokerGMTOffset = InpBrokerGMTOffset;
        g_offsetDetected = false;
        Print("[DayBlocker] TimeGMT() unreliable, using manual offset: +", g_brokerGMTOffset);
    }
}

datetime GetUTC() { return TimeCurrent() - g_brokerGMTOffset * 3600; }

bool g_isBlocked = false;
bool g_wasAutoTradingOn = false;
string g_blockReason = "";
string g_currencies[];
datetime g_lastCheck = 0;
string g_blockedDates[];      // From file
int g_blockedDateCount = 0;
string g_lastCalendarLogDate = "";  // Only log calendar count once per day
datetime g_blockedDate = 0;         // The broker date when we blocked (for re-enable logic)

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
    // Detect broker GMT offset (auto or manual fallback)
    DetectBrokerGMTOffset();

    // Parse currencies
    StringSplit(InpCurrencies, ',', g_currencies);
    for(int i = 0; i < ArraySize(g_currencies); i++)
        StringTrimLeft(g_currencies[i]);

    // Load blocked dates file
    LoadBlockedDates();

    // Set timer
    EventSetTimer(InpCheckIntervalSec);

    // Log calendar status once on init
    MqlDateTime initDt;
    TimeToStruct(GetUTC(), initDt);
    initDt.hour = 0; initDt.min = 0; initDt.sec = 0;
    datetime initDayStart = StructToTime(initDt);
    MqlCalendarValue initValues[];
    int initTotal = CalendarValueHistory(initValues, initDayStart, initDayStart + 86400);
    if(initTotal > 0)
        Print("[DayBlocker] Calendar: ", initTotal, " events found for ", TimeToString(initDayStart, TIME_DATE));
    else if(GetLastError() == 5401)
        Print("[DayBlocker] WARNING: Broker does not support MQL5 calendar. Use blocked_dates.txt instead.");
    else
        Print("[DayBlocker] Calendar: 0 events for today");

    // On restart: set g_blockedDate to today so re-enable logic works correctly
    MqlDateTime initNow;
    TimeToStruct(TimeCurrent(), initNow);
    initNow.hour = 0; initNow.min = 0; initNow.sec = 0;
    g_blockedDate = StructToTime(initNow);

    // Initial check and draw
    FetchUpcomingNews();
    CheckAndBlock();
    UpdatePanel();

    Print("[DayBlocker] Initialized. Checking every ", InpCheckIntervalSec, "s");
    Print("[DayBlocker] Currencies: ", InpCurrencies);
    Print("[DayBlocker] Flash PMI: ", InpBlockFlashPMI ? "BLOCK" : "allow");
    Print("[DayBlocker] Re-enable: ", InpReEnableHour, ":00 broker time next day");
    Print("[DayBlocker] Manual file: ", InpUseBlockFile ? InpBlockFilePath : "disabled");

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();

    // Re-enable AutoTrading if we blocked it
    if(g_isBlocked)
    {
        EnableAutoTrading();
        Print("[DayBlocker] Re-enabled AutoTrading on shutdown");
    }

    ObjectsDeleteAll(0, "DB_");
}

//+------------------------------------------------------------------+
//| Timer function                                                    |
//+------------------------------------------------------------------+
void OnTimer()
{
    CheckAndBlock();
    UpdatePanel();
}

//+------------------------------------------------------------------+
//| Main check logic                                                  |
//+------------------------------------------------------------------+
void CheckAndBlock()
{
    MqlDateTime now;
    TimeToStruct(TimeCurrent(), now);  // Use broker time (reliable on all brokers)

    // Check if we should re-enable
    // Logic: if the broker date has changed since we blocked, AND
    // it's past the re-enable hour (in broker time), re-enable.
    // InpReEnableHour is treated as BROKER hour since TimeGMT() is unreliable.
    // On Coinexx GMT+3: setting 1 = 01:00 broker = ~22:00 UTC
    if(g_isBlocked && InpReEnableNextDay)
    {
        // Get today's broker date (midnight)
        MqlDateTime todayDt;
        TimeToStruct(TimeCurrent(), todayDt);
        todayDt.hour = 0; todayDt.min = 0; todayDt.sec = 0;
        datetime todayDate = StructToTime(todayDt);

        // Re-enable if: it's a new day AND past the re-enable hour
        // OR if it's been more than 24 hours since we blocked
        bool newDay = (todayDate > g_blockedDate);
        bool pastHour = (now.hour >= InpReEnableHour);
        bool over24h = (TimeCurrent() - g_blockedDate > 86400 + InpReEnableHour * 3600);

        if((newDay && pastHour) || over24h)
        {
            // Check if TODAY (broker date) is also blocked
            if(!IsDayBlocked(GetUTC()))
            {
                EnableAutoTrading();
                g_isBlocked = false;
                g_blockReason = "";
                Print("[DayBlocker] Re-enabled AutoTrading (new day, past hour ", InpReEnableHour, ":00 broker time)");
            }
            else
            {
                Print("[DayBlocker] Would re-enable but TODAY is also blocked");
            }
        }
    }

    // If already blocked, just make sure AutoTrading stays off (someone might toggle it manually)
    if(g_isBlocked)
    {
        if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
        {
            DisableAutoTrading();  // Re-disable silently, no alert
            Print("[DayBlocker] AutoTrading was re-enabled manually — blocking again");
        }
        return;  // Don't re-check, don't re-alert
    }

    // Check if today is blocked
    if(!g_isBlocked)
    {
        string reason = "";
        bool blocked = false;

        if(InpTestMode)
        {
            blocked = true;
            reason = "TEST MODE — simulating blocked day";
        }
        else
        {
            blocked = IsDayBlocked(GetUTC(), reason);
        }

        if(blocked)
        {
            g_isBlocked = true;
            g_blockReason = reason;

            // Record the broker date we blocked on (for re-enable logic)
            MqlDateTime bdt;
            TimeToStruct(TimeCurrent(), bdt);
            bdt.hour = 0; bdt.min = 0; bdt.sec = 0;
            g_blockedDate = StructToTime(bdt);

            DisableAutoTrading();
            Print("[DayBlocker] *** BLOCKED *** Reason: ", reason);
        }
    }
}

//+------------------------------------------------------------------+
//| Check if a specific day is blocked                                |
//+------------------------------------------------------------------+
bool IsDayBlocked(datetime checkTime, string &reason)
{
    // 1. Check manual blocked dates file
    if(InpUseBlockFile && IsInBlockedDatesFile(checkTime))
    {
        reason = "Manual block (blocked_dates.txt)";
        return true;
    }

    // 2. Check MQL5 economic calendar
    if(IsBlockedByCalendar(checkTime, reason))
        return true;

    return false;
}

bool IsDayBlocked(datetime checkTime)
{
    string dummy = "";
    return IsDayBlocked(checkTime, dummy);
}

//+------------------------------------------------------------------+
//| Check MQL5 Economic Calendar for blocked events                   |
//+------------------------------------------------------------------+
bool IsBlockedByCalendar(datetime checkTime, string &reason)
{
    // Get start and end of the day (UTC)
    MqlDateTime dt;
    TimeToStruct(checkTime, dt);
    dt.hour = 0; dt.min = 0; dt.sec = 0;
    datetime dayStart = StructToTime(dt);
    datetime dayEnd = dayStart + 86400;

    MqlCalendarValue values[];
    int total = CalendarValueHistory(values, dayStart, dayEnd);

    if(total <= 0)
    {
        int err = GetLastError();
        // No per-tick logging for zero events either
        return false;
    }

    // No per-tick logging — calendar count logged only on init

    for(int i = 0; i < total; i++)
    {
        MqlCalendarEvent event;
        if(!CalendarEventById(values[i].event_id, event))
            continue;

        // Only check HIGH and MODERATE importance
        if(event.importance < CALENDAR_IMPORTANCE_MODERATE)
            continue;

        // Get country for currency check
        MqlCalendarCountry country;
        if(!CalendarCountryById(event.country_id, country))
            continue;

        // Check if currency matches our filter
        bool currencyMatch = false;
        for(int c = 0; c < ArraySize(g_currencies); c++)
        {
            if(StringFind(country.currency, g_currencies[c]) >= 0)
            {
                currencyMatch = true;
                break;
            }
        }
        if(!currencyMatch) continue;

        string eventName = event.name;

        // Check each blocking rule
        if(InpBlockFlashPMI && (StringFind(eventName, "Flash Manufacturing PMI") >= 0 ||
                                 StringFind(eventName, "Flash Services PMI") >= 0 ||
                                 StringFind(eventName, "S&P Global Flash") >= 0))
        {
            reason = "Flash PMI: " + country.currency + " " + eventName;
            return true;
        }

        if(InpBlockTrumpSpeaks && StringFind(eventName, "Trump") >= 0)
        {
            reason = "Trump: " + eventName;
            return true;
        }

        if(InpBlockFOMCDecision && (StringFind(eventName, "Federal Funds Rate") >= 0 ||
                                     StringFind(eventName, "FOMC Statement") >= 0 ||
                                     StringFind(eventName, "FOMC Economic Projections") >= 0))
        {
            reason = "FOMC Decision: " + eventName;
            return true;
        }

        if(InpBlockNFP && StringFind(eventName, "Non-Farm") >= 0)
        {
            reason = "NFP: " + eventName;
            return true;
        }

        if(InpBlockCPI && (StringFind(eventName, "CPI m/m") >= 0 ||
                            StringFind(eventName, "Core CPI") >= 0))
        {
            reason = "CPI: " + eventName;
            return true;
        }

        if(InpBlockGDP && (StringFind(eventName, "GDP q/q") >= 0 ||
                            StringFind(eventName, "Advance GDP") >= 0 ||
                            StringFind(eventName, "Prelim GDP") >= 0 ||
                            StringFind(eventName, "Final GDP") >= 0))
        {
            reason = "GDP: " + eventName;
            return true;
        }

        if(InpBlockPPI && (StringFind(eventName, "PPI m/m") >= 0 ||
                            StringFind(eventName, "Core PPI") >= 0))
        {
            reason = "PPI: " + eventName;
            return true;
        }

        if(InpBlockFOMCMinutes && StringFind(eventName, "FOMC Meeting Minutes") >= 0)
        {
            reason = "FOMC Minutes: " + eventName;
            return true;
        }

        if(InpBlockPowellSpeaks && (StringFind(eventName, "Fed Chair Powell") >= 0 ||
                                      StringFind(eventName, "Powell Speaks") >= 0 ||
                                      StringFind(eventName, "Powell Testifies") >= 0))
        {
            reason = "Powell: " + eventName;
            return true;
        }

        if(InpBlockISM && StringFind(eventName, "ISM Manufacturing PMI") >= 0)
        {
            reason = "ISM: " + eventName;
            return true;
        }

        if(InpBlockRetailSales && (StringFind(eventName, "Retail Sales m/m") >= 0 ||
                                    StringFind(eventName, "Core Retail Sales") >= 0))
        {
            reason = "Retail Sales: " + eventName;
            return true;
        }

        if(InpBlockEmpireState && StringFind(eventName, "Empire State") >= 0)
        {
            reason = "Empire State: " + eventName;
            return true;
        }
    }

    return false;
}

//+------------------------------------------------------------------+
//| Load manual blocked dates from file                               |
//+------------------------------------------------------------------+
void LoadBlockedDates()
{
    g_blockedDateCount = 0;

    if(!InpUseBlockFile) return;

    if(!FileIsExist(InpBlockFilePath))
    {
        Print("[DayBlocker] No blocked dates file found: ", InpBlockFilePath);
        Print("[DayBlocker] Create MQL5/Files/", InpBlockFilePath, " with one date per line (YYYY-MM-DD)");
        return;
    }

    int handle = FileOpen(InpBlockFilePath, FILE_READ | FILE_TXT | FILE_ANSI);
    if(handle == INVALID_HANDLE)
    {
        Print("[DayBlocker] Failed to open: ", InpBlockFilePath);
        return;
    }

    ArrayResize(g_blockedDates, 0);

    while(!FileIsEnding(handle))
    {
        string line = FileReadString(handle);
        StringTrimLeft(line);
        StringTrimRight(line);

        // Skip empty lines and comments
        if(StringLen(line) == 0) continue;
        if(StringGetCharacter(line, 0) == '#') continue;

        // Extract just the date part (first 10 chars: YYYY-MM-DD)
        if(StringLen(line) >= 10)
        {
            string dateStr = StringSubstr(line, 0, 10);
            int sz = ArraySize(g_blockedDates);
            ArrayResize(g_blockedDates, sz + 1);
            g_blockedDates[sz] = dateStr;
            g_blockedDateCount++;
        }
    }

    FileClose(handle);
    Print("[DayBlocker] Loaded ", g_blockedDateCount, " blocked dates from ", InpBlockFilePath);
}

//+------------------------------------------------------------------+
//| Check if date is in the manual blocked dates file                 |
//+------------------------------------------------------------------+
bool IsInBlockedDatesFile(datetime checkTime)
{
    if(g_blockedDateCount == 0) return false;

    string checkDate = TimeToString(checkTime, TIME_DATE);
    // Convert from "YYYY.MM.DD" to "YYYY-MM-DD" for comparison
    StringReplace(checkDate, ".", "-");

    for(int i = 0; i < g_blockedDateCount; i++)
    {
        if(g_blockedDates[i] == checkDate)
            return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Disable AutoTrading globally                                      |
//+------------------------------------------------------------------+
void DisableAutoTrading()
{
    if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
    {
        g_wasAutoTradingOn = true;

        if(InpDryRun)
        {
            Print("[DayBlocker] DRY RUN: Would disable AutoTrading (not actually toggling)");
            return;
        }

        int hwnd = (int)ChartGetInteger(0, CHART_WINDOW_HANDLE);
        int root = GetAncestor(hwnd, GA_ROOT);
        PostMessageA(root, WM_COMMAND, MT5_AUTOTRADING_CMD, 0);
        Print("[DayBlocker] AutoTrading DISABLED");
    }
}

//+------------------------------------------------------------------+
//| Enable AutoTrading globally                                       |
//+------------------------------------------------------------------+
void EnableAutoTrading()
{
    if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
    {
        if(InpDryRun)
        {
            Print("[DayBlocker] DRY RUN: Would re-enable AutoTrading (not actually toggling)");
            return;
        }

        int hwnd = (int)ChartGetInteger(0, CHART_WINDOW_HANDLE);
        int root = GetAncestor(hwnd, GA_ROOT);
        PostMessageA(root, WM_COMMAND, MT5_AUTOTRADING_CMD, 0);
        Print("[DayBlocker] AutoTrading RE-ENABLED");
    }
}

//+------------------------------------------------------------------+
//| PANEL GLOBALS                                                     |
//+------------------------------------------------------------------+
bool g_newsExpanded = false;
string g_upcomingNews[];
int g_upcomingNewsCount = 0;

//+------------------------------------------------------------------+
//| Fetch today's upcoming HIGH/MEDIUM news for panel display         |
//+------------------------------------------------------------------+
void FetchUpcomingNews()
{
    g_upcomingNewsCount = 0;
    ArrayResize(g_upcomingNews, 0);

    MqlDateTime now;
    TimeToStruct(GetUTC(), now);
    now.hour = 0; now.min = 0; now.sec = 0;
    datetime dayStart = StructToTime(now);
    datetime dayEnd = dayStart + 86400;

    MqlCalendarValue values[];
    int total = CalendarValueHistory(values, dayStart, dayEnd);
    if(total <= 0) return;

    for(int i = 0; i < total; i++)
    {
        MqlCalendarEvent event;
        if(!CalendarEventById(values[i].event_id, event)) continue;
        if(event.importance < CALENDAR_IMPORTANCE_MODERATE) continue;

        MqlCalendarCountry country;
        if(!CalendarCountryById(event.country_id, country)) continue;

        // Check currency filter
        bool match = false;
        for(int c = 0; c < ArraySize(g_currencies); c++)
            if(StringFind(country.currency, g_currencies[c]) >= 0) { match = true; break; }
        if(!match) continue;

        // Format: "14:30 USD Non-Farm Payrolls [HIGH]"
        string timeStr = TimeToString(values[i].time, TIME_MINUTES);
        string impStr = event.importance == CALENDAR_IMPORTANCE_HIGH ? "HIGH" : "MED";
        string line = timeStr + " " + country.currency + " " + event.name + " [" + impStr + "]";

        int sz = ArraySize(g_upcomingNews);
        if(sz >= 12) break;  // max 12 events in panel
        ArrayResize(g_upcomingNews, sz + 1);
        g_upcomingNews[sz] = line;
        g_upcomingNewsCount++;
    }
}

//+------------------------------------------------------------------+
//| Update panel display                                              |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    if(!InpShowPanel) return;

    string prefix = "DB_";
    int x = 10, y = 30;
    int panelWidth = 340;

    // Calculate panel height
    int baseHeight = g_isBlocked ? 80 : 50;
    int newsHeaderHeight = 22;
    int newsItemHeight = (g_newsExpanded && g_upcomingNewsCount > 0) ? g_upcomingNewsCount * 14 + 4 : 0;
    int totalHeight = baseHeight + newsHeaderHeight + newsItemHeight;

    // Background
    string bgName = prefix + "BG";
    ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, bgName, OBJPROP_XSIZE, panelWidth);
    ObjectSetInteger(0, bgName, OBJPROP_YSIZE, totalHeight);
    ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, g_isBlocked ? C'60,10,10' : C'10,40,10');
    ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, g_isBlocked ? InpBlockedColor : InpActiveColor);
    ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, bgName, OBJPROP_BACK, false);

    // Status text
    string statusName = prefix + "STATUS";
    ObjectCreate(0, statusName, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, statusName, OBJPROP_XDISTANCE, x + 10);
    ObjectSetInteger(0, statusName, OBJPROP_YDISTANCE, y + 8);
    ObjectSetInteger(0, statusName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetString(0, statusName, OBJPROP_FONT, "Arial Bold");
    ObjectSetInteger(0, statusName, OBJPROP_FONTSIZE, 11);

    int nextY = y + 30;

    if(g_isBlocked)
    {
        ObjectSetString(0, statusName, OBJPROP_TEXT, "⛔ DAY-BLOCKER: TRADING DISABLED");
        ObjectSetInteger(0, statusName, OBJPROP_COLOR, InpBlockedColor);

        // Reason text
        string reasonName = prefix + "REASON";
        ObjectCreate(0, reasonName, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, reasonName, OBJPROP_XDISTANCE, x + 10);
        ObjectSetInteger(0, reasonName, OBJPROP_YDISTANCE, nextY + 5);
        ObjectSetInteger(0, reasonName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetString(0, reasonName, OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, reasonName, OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, reasonName, OBJPROP_TEXT, g_blockReason);
        ObjectSetInteger(0, reasonName, OBJPROP_COLOR, clrWhite);

        // Re-enable time — show in broker time (since that's what we check)
        string reEnName = prefix + "REENABLE";
        ObjectCreate(0, reEnName, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, reEnName, OBJPROP_XDISTANCE, x + 10);
        ObjectSetInteger(0, reEnName, OBJPROP_YDISTANCE, nextY + 22);
        ObjectSetInteger(0, reEnName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetString(0, reEnName, OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, reEnName, OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, reEnName, OBJPROP_TEXT, "Re-enable tomorrow after " + IntegerToString(InpReEnableHour) + ":00 broker time");
        ObjectSetInteger(0, reEnName, OBJPROP_COLOR, clrGray);

        nextY += 48;
    }
    else
    {
        ObjectSetString(0, statusName, OBJPROP_TEXT, "✅ DAY-BLOCKER: ACTIVE (trading allowed)");
        ObjectSetInteger(0, statusName, OBJPROP_COLOR, InpActiveColor);
        ObjectDelete(0, prefix + "REASON");
        ObjectDelete(0, prefix + "REENABLE");
        nextY += 18;
    }

    // News expand/collapse button
    string btnNews = prefix + "BTN_NEWS";
    ObjectCreate(0, btnNews, OBJ_BUTTON, 0, 0, 0);
    ObjectSetInteger(0, btnNews, OBJPROP_XDISTANCE, x + 5);
    ObjectSetInteger(0, btnNews, OBJPROP_YDISTANCE, nextY);
    ObjectSetInteger(0, btnNews, OBJPROP_XSIZE, panelWidth - 10);
    ObjectSetInteger(0, btnNews, OBJPROP_YSIZE, 18);
    ObjectSetInteger(0, btnNews, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetString(0, btnNews, OBJPROP_FONT, "Arial");
    ObjectSetInteger(0, btnNews, OBJPROP_FONTSIZE, 8);
    ObjectSetInteger(0, btnNews, OBJPROP_COLOR, clrWhite);
    ObjectSetInteger(0, btnNews, OBJPROP_BGCOLOR, C'40,40,40');
    ObjectSetInteger(0, btnNews, OBJPROP_BORDER_COLOR, C'80,80,80');

    string expandChar = g_newsExpanded ? "▼" : "►";
    ObjectSetString(0, btnNews, OBJPROP_TEXT, expandChar + " Today's News: " + IntegerToString(g_upcomingNewsCount) + " USD/EUR events");
    ObjectSetInteger(0, btnNews, OBJPROP_STATE, false);

    nextY += 20;

    // News items (if expanded)
    if(g_newsExpanded)
    {
        for(int i = 0; i < 12; i++)
        {
            string newsLabel = prefix + "NEWS_" + IntegerToString(i);
            if(i < g_upcomingNewsCount)
            {
                ObjectCreate(0, newsLabel, OBJ_LABEL, 0, 0, 0);
                ObjectSetInteger(0, newsLabel, OBJPROP_XDISTANCE, x + 12);
                ObjectSetInteger(0, newsLabel, OBJPROP_YDISTANCE, nextY + i * 14);
                ObjectSetInteger(0, newsLabel, OBJPROP_CORNER, CORNER_LEFT_UPPER);
                ObjectSetString(0, newsLabel, OBJPROP_FONT, "Consolas");
                ObjectSetInteger(0, newsLabel, OBJPROP_FONTSIZE, 8);

                // Color by impact
                color clr = clrGray;
                if(StringFind(g_upcomingNews[i], "[HIGH]") >= 0) clr = clrOrangeRed;
                else if(StringFind(g_upcomingNews[i], "[MED]") >= 0) clr = clrDarkOrange;

                ObjectSetString(0, newsLabel, OBJPROP_TEXT, g_upcomingNews[i]);
                ObjectSetInteger(0, newsLabel, OBJPROP_COLOR, clr);
            }
            else
            {
                ObjectDelete(0, newsLabel);
            }
        }
    }
    else
    {
        for(int i = 0; i < 12; i++)
            ObjectDelete(0, prefix + "NEWS_" + IntegerToString(i));
    }

    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Chart event handler — for button clicks                          |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
    if(id == CHARTEVENT_OBJECT_CLICK && sparam == "DB_BTN_NEWS")
    {
        ObjectSetInteger(0, "DB_BTN_NEWS", OBJPROP_STATE, false);
        g_newsExpanded = !g_newsExpanded;
        if(g_newsExpanded) FetchUpcomingNews();
        UpdatePanel();
    }
}

//+------------------------------------------------------------------+
//| OnTick — not used, timer-based                                    |
//+------------------------------------------------------------------+
void OnTick() {}
//+------------------------------------------------------------------+
