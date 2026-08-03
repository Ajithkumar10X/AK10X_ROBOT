//+------------------------------------------------------------------+
//|                                                     AK10XPro.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.20"

// Include MQL5 Trade Library
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Enums
enum ENUM_TREND {
   TREND_UP,
   TREND_DOWN,
   TREND_SIDEWAYS,
   TREND_TRAPPING
};

enum ENUM_SETUP_TYPE {
   SETUP_NONE,
   SETUP_BOFL,
   SETUP_BOFS,
   SETUP_BOL,
   SETUP_BOS
};

enum ENUM_GRADE {
   GRADE_NONE,
   GRADE_APLUS,
   GRADE_APLUSPLUS
};

//--- Structures
struct SwingPoint {
   double price;
   datetime time;
   int index;
   bool isHigh;
};

struct ZZPoint {
   double price;
   datetime time;
   bool isHigh;
   string label; // "HH", "LH", "HL", "LL"
};

struct BreakoutState {
   bool isValid;
   string levelType;      // "VRZ High" or "VRZ Low"
   double levelPrice;     // VRZ price
   datetime time;         // Breakout candle time
   double sl;             // Stop Loss price
   double tp;             // Take Profit price
   ENUM_SETUP_TYPE setup; // BOL, BOS, BOFS, BOFL
   string reaction;       // "Continuation", "Immediate Reversal", "Direct Breakout"
   string status;         // "N/A", "Pending Order", "Running Order", "Closed"
   string grade;          // "A++" or "A+++"
   bool riskFreeDone;
   double currentLot;
   datetime fillTime;
   ulong positionTicket;
};

//--- Inputs
input group "=== Major Swing Structure (HUD Only) ==="
input int             Major_SwingLeft   = 5;                // Left candles for Major Swing
input int             Major_SwingRight  = 5;                // Right candles for Major Swing

input group "=== Minor Swing Structure & Zigzag ==="
input ENUM_TIMEFRAMES TradingPeriod     = PERIOD_M3;        // Trading Timeframe (3 Min)
input int             Minor_SwingLength = 10;               // Swing High/Low Length (Zigzag)

input group "=== Higher Timeframe (HTF) ==="
input ENUM_TIMEFRAMES HigherPeriod      = PERIOD_M15;       // Higher Timeframe (15 Min)
input ENUM_TIMEFRAMES HigherHighPeriod  = PERIOD_H1;        // Higher High Timeframe (1 Hour)
input int             HTF_SwingLeft     = 2;                // Left candles for HTF Swing
input int             HTF_SwingRight    = 2;                // Right candles for HTF Swing
input double          HighProbVRZPips   = 10.0;             // Max distance in pips for overlapping VRZs

input group "=== Risk & Trade Management ==="
input double          BaseLotSize       = 0.02;             // Lot size per position
input double          RiskPercent       = 0.0;              // Dynamic risk % (if > 0, overrides BaseLotSize)
input double          MinRiskReward     = 3.0;              // Minimum Risk to Reward Ratio
input int             StopLossBuffer    = 30;               // SL buffer in pips (outside breakout candle)
input int             Slippage          = 3;                // Allowed slippage in points
input ulong           MagicNumber       = 101010;           // Expert Advisor Magic Number
input bool            EnableRiskFree    = true;             // Enable Risk-Free Management (50% partial close)

input group "=== News Filter ==="
input bool            UseNewsFilter     = true;             // Enable Economic Calendar filter
input int             NewsMinsBefore    = 15;               // Minutes to block trading before news
input int             NewsMinsAfter     = 15;               // Minutes to block trading after news

input group "=== Journal & Logging ==="
input bool            EnableJournal     = true;             // Log trades to CSV file

input group "=== Interface & Visuals ==="
input bool            ShowHUD           = true;             // Show status HUD
input color           ColorVRZ_Active   = clrSteelBlue;     // Active VRZ High line color
input color           ColorVRZ_ActiveL  = clrCrimson;       // Active VRZ Low line color
input color           ColorEagleHigh    = clrDarkGreen;     // Eagle VRZ High line color (Dark Green)
input color           ColorEagleLow     = clrDarkRed;       // Eagle VRZ Low line color (Dark Red)
input color           ColorZigzag       = clrLightSeaGreen; // Zigzag line color
input color           ColorHUD_Bg       = C'20,20,20';      // HUD Background color
input color           ColorHUD_Text     = clrWhite;         // HUD Text color
input int             MaxMitigatedDraw  = 10;               // Max mitigated VRZ lines to draw


//--- Global Variables
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     ordInfo;

double         vrzHigh_15m = 0.0;
double         vrzLow_15m  = 0.0;
double         vrzHigh_1h  = 0.0;
double         vrzLow_1h   = 0.0;
bool           isHP_High   = false;
bool           isHP_Low    = false;

ENUM_TREND     major_Trend = TREND_SIDEWAYS;
ENUM_TREND     ttf_Trend   = TREND_SIDEWAYS;

double         major_SwingHighPrice = 0.0;
double         major_SwingLowPrice  = 0.0;
double         minor_SwingHighPrice = 0.0;
double         minor_SwingLowPrice  = 0.0;

bool           AutoTradingEnabled   = false;
bool           HUD_Minimized        = false;
datetime       lastBarTime          = 0;
string         hudObjects[];

//--- Breakout tracking variables
BreakoutState  currentBreakout;
double         lastTickPrice        = 0.0;

void UpdateCountdown();
void ProcessBreakoutStateMachine();
void DetectBreakoutFromHistory();
ENUM_TREND GetHTFTrend();

//--- Forward declarations for virgin helper functions
int GetHistoricalSwings(ENUM_TIMEFRAMES tf, int leftBars, int rightBars, SwingPoint &highs[], SwingPoint &lows[], int maxCount);
datetime GetExactSwingTimeTTF(datetime htfTime, double price, bool isHigh);
datetime GetBreakoutTimeTTF(double price, datetime swingTime, bool isHigh);
void SortSwingPoints(SwingPoint &arr[], bool ascending);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   
   // Switch chart timeframe to Trading Period on EA load
   ChartSetSymbolPeriod(0, _Symbol, TradingPeriod);
   
   // Set chart color scheme to "Color on White"
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, clrWhite);
   ChartSetInteger(0, CHART_COLOR_FOREGROUND, clrBlack);
   ChartSetInteger(0, CHART_COLOR_GRID, C'241,236,242');
   ChartSetInteger(0, CHART_COLOR_CHART_UP, C'38,166,154');
   ChartSetInteger(0, CHART_COLOR_CHART_DOWN, C'239,83,80');
   ChartSetInteger(0, CHART_COLOR_CANDLE_BULL, C'38,166,154');
   ChartSetInteger(0, CHART_COLOR_CANDLE_BEAR, C'239,83,80');
   ChartSetInteger(0, CHART_COLOR_CHART_LINE, C'86,186,132');
   ChartSetInteger(0, CHART_COLOR_VOLUME, C'38,166,154');
   ChartSetInteger(0, CHART_COLOR_BID, C'38,166,154');
   ChartSetInteger(0, CHART_COLOR_ASK, C'239,83,80');
   ChartSetInteger(0, CHART_COLOR_LAST, C'156,186,240');
   ChartSetInteger(0, CHART_COLOR_STOP_LEVEL, C'239,83,80');
   
   // Set chart mode to candlesticks, show grid, and maximize chart window
   ChartSetInteger(0, CHART_MODE, CHART_CANDLES);
   ChartSetInteger(0, CHART_SHOW_GRID, true);
   ChartSetInteger(0, CHART_IS_MAXIMIZED, true);
   
   // Set timer for periodic events (like news checking and HUD updates)
   EventSetTimer(1); 
   
   // Initial processing
   UpdateVRZones();
   UpdateTrends();
   DetectBreakoutFromHistory();
   ProcessTradingLogic();
   
   ChartRedraw(0);
   
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   
   // Delete all graphical objects created by EA
   ObjectsDeleteAll(0, "AK10X_");
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Run logical thinker state machine on every tick
   ProcessBreakoutStateMachine();
   
   // Check if a new bar has opened on the Trading Timeframe
   datetime currentBarTime = iTime(_Symbol, TradingPeriod, 0);
   if(currentBarTime != lastBarTime)
     {
      lastBarTime = currentBarTime;
      ProcessTradingLogic();
     }
     
   if(ShowHUD) 
     {
      UpdateHUD();
      UpdateCountdown();
     }
  }

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
   ProcessBreakoutStateMachine();
   ScanClosedPositions();
   if(ShowHUD) 
     {
      UpdateHUD();
      UpdateCountdown();
     }
  }

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == "AK10X_HUD_Btn_Auto")
        {
         AutoTradingEnabled = !AutoTradingEnabled;
         UpdateHUD();
        }
      else if(sparam == "AK10X_HUD_Btn_MinMax")
        {
         HUD_Minimized = !HUD_Minimized;
         UpdateHUD();
        }
     }
  }

//+------------------------------------------------------------------+
//| Core trading logic: Updates levels, trends, and processes setups |
//+------------------------------------------------------------------+
void ProcessTradingLogic()
  {
   // 1. Process breakout state machine
   ProcessBreakoutStateMachine();
   
   // 2. Update Swing Points & VRZs (updates levels for the next candle)
   UpdateVRZones();
   
   // 3. Update Trend States
   UpdateTrends();
   
   // 4. Draw Zigzag & Swing Labels
   DrawZigzagAndLabels();
   
   // 5. Update UI
   if(ShowHUD) UpdateHUD();
  }

//+------------------------------------------------------------------+
//| Get Latest Bid Price (Force Tick Update)                         |
//+------------------------------------------------------------------+
double GetLatestBid()
  {
   double bid = iClose(_Symbol, TradingPeriod, 0);
   if(bid > 0) return bid;
   
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick))
     {
      if(tick.bid > 0) return tick.bid;
     }
   return SymbolInfoDouble(_Symbol, SYMBOL_BID);
  }

//+------------------------------------------------------------------+
//| Get Latest Ask Price (Force Tick Update)                         |
//+------------------------------------------------------------------+
double GetLatestAsk()
  {
   double bid = GetLatestBid();
   double ask = 0.0;
   MqlTick tick;
   if(SymbolInfoTick(_Symbol, tick) && tick.ask > 0) 
     {
      if(MathAbs(tick.bid - bid) < SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10)
         return tick.ask;
     }
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   ask = bid + (spread * point);
   return ask;
  }

//+------------------------------------------------------------------+
//| Pip Size Helper                                                  |
//+------------------------------------------------------------------+
double GetPipSize()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   string sym = _Symbol;
   StringToUpper(sym);
   
   // Cryptocurrencies (BTC, ETH, LTC, SOL, etc.)
   if(StringFind(sym, "BTC") >= 0 || StringFind(sym, "ETH") >= 0 || StringFind(sym, "LTC") >= 0 || StringFind(sym, "XBT") >= 0 || StringFind(sym, "SOL") >= 0)
     {
      return 1.0;
     }
     
   // Gold (XAUUSD, GOLD, etc.)
   if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0)
     {
      return 0.1;
     }
     
   // Silver (XAGUSD, SILVER, etc.)
   if(StringFind(sym, "XAG") >= 0 || StringFind(sym, "SILVER") >= 0)
     {
      return 0.01;
     }
     
   // Forex currency pairs
   if(digits == 3 || digits == 5) return point * 10.0;
   return point;
  }

//+------------------------------------------------------------------+
//| Get Pip/Point Divisor for HUD metrics                           |
//+------------------------------------------------------------------+
double GetPipDivisor()
  {
   return GetPipSize();
  }

//+------------------------------------------------------------------+
//| Find the most recent Virgin High on a given timeframe            |
//+------------------------------------------------------------------+
double GetRecentVirginHigh(ENUM_TIMEFRAMES tf, int leftBars, int rightBars)
  {
   SwingPoint highs[], lows[];
   GetHistoricalSwings(tf, leftBars, rightBars, highs, lows, 250);
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   double lastClose = GetLatestBid();
   if(CopyRates(_Symbol, TradingPeriod, 1, 1, rates) > 0)
     {
      lastClose = rates[0].close;
     }
   
   SwingPoint virginHighs[];
   int vHCount = 0;
   
   for(int i = 0; i < ArraySize(highs); i++)
     {
      double price = highs[i].price;
      datetime swingTime = GetExactSwingTimeTTF(highs[i].time, price, true);
      datetime breakoutTime = GetBreakoutTimeTTF(price, swingTime, true);
      bool isVirgin = (breakoutTime == 0);
      
      if(isVirgin && lastClose <= price)
        {
         ArrayResize(virginHighs, vHCount + 1);
         virginHighs[vHCount] = highs[i];
         virginHighs[vHCount].time = swingTime;
         vHCount++;
        }
     }
     
   if(vHCount == 0) return 0.0;
   
   SortSwingPoints(virginHighs, true); // Ascending order (closest first)
   return virginHighs[0].price;
  }

//+------------------------------------------------------------------+
//| Find the closest Virgin Low below current price                  |
//+------------------------------------------------------------------+
double GetRecentVirginLow(ENUM_TIMEFRAMES tf, int leftBars, int rightBars)
  {
   SwingPoint highs[], lows[];
   GetHistoricalSwings(tf, leftBars, rightBars, highs, lows, 250);
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   double lastClose = GetLatestBid();
   if(CopyRates(_Symbol, TradingPeriod, 1, 1, rates) > 0)
     {
      lastClose = rates[0].close;
     }
   
   SwingPoint virginLows[];
   int vLCount = 0;
   
   for(int i = 0; i < ArraySize(lows); i++)
     {
      double price = lows[i].price;
      datetime swingTime = GetExactSwingTimeTTF(lows[i].time, price, false);
      datetime breakoutTime = GetBreakoutTimeTTF(price, swingTime, false);
      bool isVirgin = (breakoutTime == 0);
      
      if(isVirgin && lastClose >= price)
        {
         ArrayResize(virginLows, vLCount + 1);
         virginLows[vLCount] = lows[i];
         virginLows[vLCount].time = swingTime;
         vLCount++;
        }
     }
     
   if(vLCount == 0) return 0.0;
   
   SortSwingPoints(virginLows, false); // Descending order (closest first)
   return virginLows[0].price;
  }

//+------------------------------------------------------------------+
//| Fetch historical confirmed swings (highs and lows)               |
//+------------------------------------------------------------------+
int GetHistoricalSwings(ENUM_TIMEFRAMES tf, int leftBars, int rightBars, SwingPoint &highs[], SwingPoint &lows[], int maxCount)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, tf, 1, 3000, rates);
   if(copied <= 0) return 0;
   
   int hCount = 0;
   int lCount = 0;
   ArrayResize(highs, maxCount);
   ArrayResize(lows, maxCount);
   
   for(int i = rightBars; i < copied - leftBars; i++)
     {
      // High Check
      double h = rates[i].high;
      bool isHigh = true;
      for(int l = 1; l <= leftBars; l++) {
         if(rates[i+l].high >= h) { isHigh = false; break; }
      }
      if(isHigh) {
         for(int r = 1; r <= rightBars; r++) {
            if(rates[i-r].high >= h) { isHigh = false; break; }
         }
      }
      if(isHigh && hCount < maxCount)
        {
         highs[hCount].price = h;
         highs[hCount].time = rates[i].time;
         highs[hCount].index = i;
         highs[hCount].isHigh = true;
         hCount++;
        }
        
      // Low Check
      double l = rates[i].low;
      bool isLow = true;
      for(int l_bar = 1; l_bar <= leftBars; l_bar++) {
         if(rates[i+l_bar].low <= l) { isLow = false; break; }
      }
      if(isLow) {
         for(int r = 1; r <= rightBars; r++) {
            if(rates[i-r].low <= l) { isLow = false; break; }
         }
      }
      if(isLow && lCount < maxCount)
        {
         lows[lCount].price = l;
         lows[lCount].time = rates[i].time;
         lows[lCount].index = i;
         lows[lCount].isHigh = false;
         lCount++;
        }
     }
     
   ArrayResize(highs, hCount);
   ArrayResize(lows, lCount);
   return MathMax(hCount, lCount);
  }

//+------------------------------------------------------------------+
//| Get breakout time on the current chart's timeframe (TTF)         |
//+------------------------------------------------------------------+
datetime GetBreakoutTimeTTF(double price, datetime swingTime, bool isHigh)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   // Copy starting from index 1 to ignore the active forming candle
   int copied = CopyRates(_Symbol, TradingPeriod, 1, 1000, rates);
   if(copied <= 0) return TimeCurrent();
   
   int swingIdx = -1;
   for(int i = 0; i < copied; i++)
     {
      if(rates[i].time <= swingTime)
        {
         swingIdx = i;
         break;
        }
     }
   if(swingIdx == -1) return TimeCurrent();
   
   for(int j = swingIdx - 1; j >= 0; j--)
     {
      if(isHigh)
        {
         if(rates[j].high > price) return rates[j].time;
        }
      else
        {
         if(rates[j].low < price) return rates[j].time;
        }
     }
   return 0; // Unbroken (Virgin)
  }

//+------------------------------------------------------------------+
//| Calculate dynamic vertical padding offset based on ATR          |
//+------------------------------------------------------------------+
double GetLabelPadding()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, TradingPeriod, 0, 20, rates);
   if(copied <= 0) return 10 * _Point;
   double totalSize = 0;
   for(int i = 0; i < copied; i++)
     {
      totalSize += (rates[i].high - rates[i].low);
     }
   double avgBarSize = totalSize / copied;
   return avgBarSize * 0.25; // 25% of average candle size as padding
  }

//+------------------------------------------------------------------+
//| Get exact swing peak/valley time on the Trading Timeframe       |
//+------------------------------------------------------------------+
datetime GetExactSwingTimeTTF(datetime htfTime, double price, bool isHigh)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, TradingPeriod, 0, 1000, rates);
   if(copied <= 0) return htfTime;
   
   int htfIdx = -1;
   for(int i = 0; i < copied; i++)
     {
      if(rates[i].time <= htfTime)
        {
         htfIdx = i;
         break;
        }
     }
   if(htfIdx == -1) return htfTime;
   
   int scanWindow = 10;
   double bestPrice = isHigh ? 0.0 : 9999999.0;
   datetime bestTime = htfTime;
   
   int startScan = htfIdx;
   int endScan = MathMax(0, htfIdx - scanWindow);
   
   for(int j = startScan; j >= endScan; j--)
     {
      if(isHigh)
        {
         if(rates[j].high > bestPrice)
           {
            bestPrice = rates[j].high;
            bestTime = rates[j].time;
           }
        }
      else
        {
         if(rates[j].low < bestPrice)
           {
            bestPrice = rates[j].low;
            bestTime = rates[j].time;
           }
        }
     }
   return bestTime;
  }

//+------------------------------------------------------------------+
//| Create VRZ horizontal trendline and label helper                |
//+------------------------------------------------------------------+
void CreateVRZLine(string name, double price, datetime startTime, datetime endTime, color clr, ENUM_LINE_STYLE style, int width, string labelText, bool isMitigated, bool isHigh, bool skipLabel = false)
  {
   if(ObjectCreate(0, name, OBJ_TREND, 0, startTime, price, endTime, price))
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, labelText);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, startTime);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, price);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, endTime);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
     }
      
   string labelObjName = name + "_Label";
   if(skipLabel)
     {
      ObjectDelete(0, labelObjName);
      return;
     }
     
   datetime labelTime;
   ENUM_ANCHOR_POINT anchorPoint;
   double labelPrice = price;
   double offset = GetLabelPadding();
   
   if(isMitigated)
     {
      labelTime = (startTime + endTime) / 2;
      anchorPoint = (ENUM_ANCHOR_POINT)(isHigh ? ANCHOR_BOTTOM : ANCHOR_TOP);
      labelPrice = isHigh ? (price + offset) : (price - offset);
     }
   else
     {
      datetime latestBarTime = iTime(_Symbol, _Period, 0);
      if(latestBarTime == 0) latestBarTime = TimeCurrent();
      labelTime = latestBarTime + 2 * PeriodSeconds(_Period);
      anchorPoint = ANCHOR_LEFT;
      labelPrice = isHigh ? (price + offset) : (price - offset);
     }
   
    if(ObjectCreate(0, labelObjName, OBJ_TEXT, 0, labelTime, labelPrice))
      {
       ObjectSetString(0, labelObjName, OBJPROP_TEXT, labelText);
       ObjectSetString(0, labelObjName, OBJPROP_FONT, "Arial");
       ObjectSetInteger(0, labelObjName, OBJPROP_FONTSIZE, 7);
       ObjectSetInteger(0, labelObjName, OBJPROP_COLOR, clr);
       ObjectSetInteger(0, labelObjName, OBJPROP_ANCHOR, anchorPoint);
       ObjectSetInteger(0, labelObjName, OBJPROP_SELECTABLE, false);
       ObjectSetInteger(0, labelObjName, OBJPROP_BACK, true);
      }
    else
      {
       ObjectSetInteger(0, labelObjName, OBJPROP_TIME, 0, labelTime);
       ObjectSetDouble(0, labelObjName, OBJPROP_PRICE, 0, labelPrice);
       ObjectSetString(0, labelObjName, OBJPROP_TEXT, labelText);
       ObjectSetInteger(0, labelObjName, OBJPROP_COLOR, clr);
       ObjectSetInteger(0, labelObjName, OBJPROP_ANCHOR, anchorPoint);
       ObjectSetInteger(0, labelObjName, OBJPROP_BACK, true);
      }
  }

// Price labels disabled

//+------------------------------------------------------------------+
//| Draw Reversal Zone Lines on Chart (Mitigated/Active colors)      |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Sort SwingPoint array by price                                   |
//+------------------------------------------------------------------+
void SortSwingPoints(SwingPoint &arr[], bool ascending)
  {
   int n = ArraySize(arr);
   for(int i = 0; i < n - 1; i++)
     {
      for(int j = i + 1; j < n; j++)
        {
         bool swap = false;
         if(ascending)
           {
            if(arr[j].price < arr[i].price) swap = true;
           }
         else
           {
            if(arr[j].price > arr[i].price) swap = true;
           }
         if(swap)
           {
            SwingPoint temp = arr[i];
            arr[i] = arr[j];
            arr[j] = temp;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Draw Reversal Zone Lines on Chart (Mitigated/Active colors)      |
//+------------------------------------------------------------------+
void DrawVRZLines()
  {
   // Delete all VRZ lines, labels, and price scale markers first
   ObjectsDeleteAll(0, "AK10X_VRZ_");
   
   // Draw HTF 1 (HigherPeriod) historical swings (bright if virgin, dim if crossed)
   SwingPoint highsHTF[], lowsHTF[];
   GetHistoricalSwings(HigherPeriod, HTF_SwingLeft, HTF_SwingRight, highsHTF, lowsHTF, 250);
   
   // Draw HTF 2 (HigherHighPeriod) swings for Eagle overlap verification
   SwingPoint highsHHTF[], lowsHHTF[];
   GetHistoricalSwings(HigherHighPeriod, HTF_SwingLeft, HTF_SwingRight, highsHHTF, lowsHHTF, 250);
   
   double pip = GetPipSize();
   
   // Process Highs
   SwingPoint virginHighs[];
   SwingPoint mitigatedHighs[];
   int vHCount = 0;
   int mHCount = 0;
   
   for(int i = 0; i < ArraySize(highsHTF); i++)
     {
      double price = highsHTF[i].price;
      datetime swingTime = GetExactSwingTimeTTF(highsHTF[i].time, price, true);
      datetime breakoutTime = GetBreakoutTimeTTF(price, swingTime, true);
      bool isVirgin = (breakoutTime == 0);
      
      if(isVirgin)
        {
         ArrayResize(virginHighs, vHCount + 1);
         virginHighs[vHCount] = highsHTF[i];
         virginHighs[vHCount].time = swingTime;
         vHCount++;
        }
      else
        {
         ArrayResize(mitigatedHighs, mHCount + 1);
         mitigatedHighs[mHCount] = highsHTF[i];
         mitigatedHighs[mHCount].time = swingTime;
         mHCount++;
        }
     }
     
   // Sort virgin highs in ascending order (closest price to current price first)
   SortSwingPoints(virginHighs, true);
   
   // Draw closest 5 virgin highs
   int highsToDraw = MathMin(5, vHCount);
   for(int i = 0; i < highsToDraw; i++)
     {
      double price = virginHighs[i].price;
      datetime swingTime = virginHighs[i].time;
      datetime endTime = TimeCurrent() + 10 * PeriodSeconds(_Period);
      
      // Verify Eagle overlap
      bool isEagle = false;
      for(int k = 0; k < ArraySize(highsHHTF); k++)
        {
         if(MathAbs(highsHHTF[k].price - price) / pip <= HighProbVRZPips)
           {
            isEagle = true;
            break;
           }
        }
      
      color clr = isEagle ? ColorEagleHigh : ColorVRZ_Active;
      string label = isEagle ? ("Eagle VRZ High - " + DoubleToString(price, _Digits)) : ("VRZ High - " + DoubleToString(price, _Digits));
      
      CreateVRZLine("AK10X_VRZ_HTF_H_V_" + (string)i, price, swingTime, endTime, clr, STYLE_SOLID, 1, label, false, true);
     }
     
    // Draw most recent mitigated highs (filter duplicate labels near same price)
    int mHighsToDraw = MathMin(MaxMitigatedDraw, mHCount);
    double drawnHighPrices[];
    int drawnHighCount = 0;
    
    for(int i = 0; i < mHighsToDraw; i++)
      {
       double price = mitigatedHighs[i].price;
       datetime swingTime = mitigatedHighs[i].time;
       datetime endTime = GetBreakoutTimeTTF(price, swingTime, true);
       
       // Verify Eagle overlap
       bool isEagle = false;
       for(int k = 0; k < ArraySize(highsHHTF); k++)
         {
          if(MathAbs(highsHHTF[k].price - price) / pip <= HighProbVRZPips)
            {
             isEagle = true;
             break;
            }
         }
       
       color clr = isEagle ? ColorEagleHigh : ColorVRZ_Active;
       string label = isEagle ? "Eagle VRZ High" : "VRZ High";
       
       // Filter duplicate labels near same price (within 3 pips)
       bool skipLabel = false;
       for(int j = 0; j < drawnHighCount; j++)
         {
          if(MathAbs(drawnHighPrices[j] - price) / pip <= 3.0)
            {
             skipLabel = true;
             break;
            }
         }
       
       if(!skipLabel)
         {
          ArrayResize(drawnHighPrices, drawnHighCount + 1);
          drawnHighPrices[drawnHighCount] = price;
          drawnHighCount++;
         }
       
       CreateVRZLine("AK10X_VRZ_HTF_H_M_" + (string)i, price, swingTime, endTime, clr, STYLE_DOT, 1, label, true, true, skipLabel);
      }
     
   // Process Lows
   SwingPoint virginLows[];
   SwingPoint mitigatedLows[];
   int vLCount = 0;
   int mLCount = 0;
   
   for(int i = 0; i < ArraySize(lowsHTF); i++)
     {
      double price = lowsHTF[i].price;
      datetime swingTime = GetExactSwingTimeTTF(lowsHTF[i].time, price, false);
      datetime breakoutTime = GetBreakoutTimeTTF(price, swingTime, false);
      bool isVirgin = (breakoutTime == 0);
      
      if(isVirgin)
        {
         ArrayResize(virginLows, vLCount + 1);
         virginLows[vLCount] = lowsHTF[i];
         virginLows[vLCount].time = swingTime;
         vLCount++;
        }
      else
        {
         ArrayResize(mitigatedLows, mLCount + 1);
         mitigatedLows[mLCount] = lowsHTF[i];
         mitigatedLows[mLCount].time = swingTime;
         mLCount++;
        }
     }
     
   // Sort virgin lows in descending order (closest price to current price first)
   SortSwingPoints(virginLows, false);
   
   // Draw closest 5 virgin lows
   int lowsToDraw = MathMin(5, vLCount);
   for(int i = 0; i < lowsToDraw; i++)
     {
      double price = virginLows[i].price;
      datetime swingTime = virginLows[i].time;
      datetime endTime = TimeCurrent() + 10 * PeriodSeconds(_Period);
      
      // Verify Eagle overlap
      bool isEagle = false;
      for(int k = 0; k < ArraySize(lowsHHTF); k++)
        {
         if(MathAbs(lowsHHTF[k].price - price) / pip <= HighProbVRZPips)
           {
            isEagle = true;
            break;
           }
        }
      
      color clr = isEagle ? ColorEagleLow : ColorVRZ_ActiveL;
      string label = isEagle ? ("Eagle VRZ Low - " + DoubleToString(price, _Digits)) : ("VRZ Low - " + DoubleToString(price, _Digits));
      
      CreateVRZLine("AK10X_VRZ_HTF_L_V_" + (string)i, price, swingTime, endTime, clr, STYLE_SOLID, 1, label, false, false);
     }
     
    // Draw most recent mitigated lows (filter duplicate labels near same price)
    int mLowsToDraw = MathMin(MaxMitigatedDraw, mLCount);
    double drawnLowPrices[];
    int drawnLowCount = 0;
    
    for(int i = 0; i < mLowsToDraw; i++)
      {
       double price = mitigatedLows[i].price;
       datetime swingTime = mitigatedLows[i].time;
       datetime endTime = GetBreakoutTimeTTF(price, swingTime, false);
       
       // Verify Eagle overlap
       bool isEagle = false;
       for(int k = 0; k < ArraySize(lowsHHTF); k++)
         {
          if(MathAbs(lowsHHTF[k].price - price) / pip <= HighProbVRZPips)
            {
             isEagle = true;
             break;
            }
         }
       
       color clr = isEagle ? ColorEagleLow : ColorVRZ_ActiveL;
       string label = isEagle ? "Eagle VRZ Low" : "VRZ Low";
       
       // Filter duplicate labels near same price (within 3 pips)
       bool skipLabel = false;
       for(int j = 0; j < drawnLowCount; j++)
         {
          if(MathAbs(drawnLowPrices[j] - price) / pip <= 3.0)
            {
             skipLabel = true;
             break;
            }
         }
       
       if(!skipLabel)
         {
          ArrayResize(drawnLowPrices, drawnLowCount + 1);
          drawnLowPrices[drawnLowCount] = price;
          drawnLowCount++;
         }
       
       CreateVRZLine("AK10X_VRZ_HTF_L_M_" + (string)i, price, swingTime, endTime, clr, STYLE_DOT, 1, label, true, false, skipLabel);
      }
  }

//+------------------------------------------------------------------+
//| Update Reversal Zones (VRZs) and check for overlaps              |
//+------------------------------------------------------------------+
void UpdateVRZones()
  {
   vrzHigh_15m = GetRecentVirginHigh(HigherPeriod, HTF_SwingLeft, HTF_SwingRight);
   vrzLow_15m  = GetRecentVirginLow(HigherPeriod, HTF_SwingLeft, HTF_SwingRight);
   
   vrzHigh_1h  = GetRecentVirginHigh(HigherHighPeriod, HTF_SwingLeft, HTF_SwingRight);
   vrzLow_1h   = GetRecentVirginLow(HigherHighPeriod, HTF_SwingLeft, HTF_SwingRight);
   
   double pip = GetPipSize();
   
   // Check overlap (High Probable VRZs)
   if(vrzHigh_15m > 0 && vrzHigh_1h > 0 && MathAbs(vrzHigh_15m - vrzHigh_1h) / pip <= HighProbVRZPips)
      isHP_High = true;
   else
      isHP_High = false;
      
   if(vrzLow_15m > 0 && vrzLow_1h > 0 && MathAbs(vrzLow_15m - vrzLow_1h) / pip <= HighProbVRZPips)
      isHP_Low = true;
   else
      isHP_Low = false;
      
   // Draw Lines
   DrawVRZLines();
  }

//+------------------------------------------------------------------+
//| Update dynamic trend states for HUD classification               |
//+------------------------------------------------------------------+
void UpdateTrends()
  {
   // Current chart price
   double currentPrice = GetLatestBid();

   // Major structure swings (e.g. 5, 5 parameters)
   SwingPoint major_Highs[], major_Lows[];
   GetHistoricalSwings(TradingPeriod, Major_SwingLeft, Major_SwingRight, major_Highs, major_Lows, 20);
   major_Trend = CalculateTrendFromSwings(major_Highs, major_Lows);
   
   major_SwingHighPrice = 0.0;
   for(int i = 0; i < ArraySize(major_Highs); i++)
     {
      if(major_Highs[i].price > currentPrice)
        {
         major_SwingHighPrice = major_Highs[i].price;
         break;
        }
     }
   if(major_SwingHighPrice <= 0.0 && ArraySize(major_Highs) > 0)
      major_SwingHighPrice = major_Highs[0].price;
      
   major_SwingLowPrice = 0.0;
   for(int i = 0; i < ArraySize(major_Lows); i++)
     {
      if(major_Lows[i].price < currentPrice)
        {
         major_SwingLowPrice = major_Lows[i].price;
         break;
        }
     }
   if(major_SwingLowPrice <= 0.0 && ArraySize(major_Lows) > 0)
      major_SwingLowPrice = major_Lows[0].price;
   
   // Minor/Internal structure swings (e.g. 2, 2 parameters)
   SwingPoint ttf_Highs[], ttf_Lows[];
   GetHistoricalSwings(TradingPeriod, Minor_SwingLength, Minor_SwingLength, ttf_Highs, ttf_Lows, 20);
   ttf_Trend = CalculateTrendFromSwings(ttf_Highs, ttf_Lows);
   
   minor_SwingHighPrice = 0.0;
   for(int i = 0; i < ArraySize(ttf_Highs); i++)
     {
      if(ttf_Highs[i].price > currentPrice)
        {
         minor_SwingHighPrice = ttf_Highs[i].price;
         break;
        }
     }
   if(minor_SwingHighPrice <= 0.0 && ArraySize(ttf_Highs) > 0)
      minor_SwingHighPrice = ttf_Highs[0].price;
      
   minor_SwingLowPrice = 0.0;
   for(int i = 0; i < ArraySize(ttf_Lows); i++)
     {
      if(ttf_Lows[i].price < currentPrice)
        {
         minor_SwingLowPrice = ttf_Lows[i].price;
         break;
        }
     }
   if(minor_SwingLowPrice <= 0.0 && ArraySize(ttf_Lows) > 0)
      minor_SwingLowPrice = ttf_Lows[0].price;
  }

//+------------------------------------------------------------------+
//| Trend classification algorithm based on LTS rules                |
//+------------------------------------------------------------------+
ENUM_TREND CalculateTrendFromSwings(const SwingPoint &highs[], const SwingPoint &lows[])
  {
   if(ArraySize(highs) < 3 || ArraySize(lows) < 3) return TREND_SIDEWAYS;
   
   // Uptrend check (Higher High and Higher Low)
   if(highs[0].price > highs[1].price && lows[0].price > lows[1].price)
      return TREND_UP;
      
   // Downtrend check (Lower High and Lower Low)
   if(highs[0].price < highs[1].price && lows[0].price < lows[1].price)
      return TREND_DOWN;
      
   // Trapping Trend check
   if(highs[0].price <= highs[2].price && highs[1].price <= highs[2].price &&
      lows[0].price >= lows[2].price && lows[1].price >= lows[2].price)
     {
      return TREND_TRAPPING;
     }
     
   return TREND_SIDEWAYS;
  }

//+------------------------------------------------------------------+
//| Pivot High Calculator helper                                     |
//+------------------------------------------------------------------+
bool IsPivotHigh(const MqlRates &rates[], int i, int len, int total)
  {
   if(i + len >= total || i - len < 0) return false;
   double h = rates[i].high;
   for(int k = 1; k <= len; k++)
     {
      if(rates[i+k].high > h || rates[i-k].high > h) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Pivot Low Calculator helper                                      |
//+------------------------------------------------------------------+
bool IsPivotLow(const MqlRates &rates[], int i, int len, int total)
  {
   if(i + len >= total || i - len < 0) return false;
   double l = rates[i].low;
   for(int k = 1; k <= len; k++)
     {
      if(rates[i+k].low < l || rates[i-k].low < l) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Draw Zigzag Line and labels (HH, LH, HL, LL) on Chart            |
//| (Translated Pivot Zigzag State Machine from Pine Script)          |
//+------------------------------------------------------------------+
void DrawZigzagAndLabels()
  {
   // Delete previous visual elements
   ObjectsDeleteAll(0, "AK10X_ZZ_");
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, TradingPeriod, 1, 500, rates);
   if(copied <= 0) return;
   
   int len = Minor_SwingLength;
   
   // State variables
   bool dirUp = false;
   double lastLow = 9999999.0;
   double lastHigh = 0.0;
   double prevLow = 9999999.0;
   double prevHigh = 0.0;
   datetime timeLow = 0;
   datetime timeHigh = 0;
   
   int lineCount = 0;
   
   // Find initial pivot point to initialize variables
   int startIdx = copied - 1 - len;
   bool initialized = false;
   
   for(int i = startIdx; i >= len; i--)
     {
      bool isPH = IsPivotHigh(rates, i, len, copied);
      bool isPL = IsPivotLow(rates, i, len, copied);
      if(isPH || isPL)
        {
         if(isPH)
           {
            lastHigh = rates[i].high;
            timeHigh = rates[i].time;
            dirUp = false;
           }
         else
           {
            lastLow = rates[i].low;
            timeLow = rates[i].time;
            dirUp = true;
           }
         startIdx = i - 1;
         initialized = true;
         break;
        }
     }
     
   if(!initialized) return;
   
   // Process historical pivot state machine
   for(int i = startIdx; i >= len; i--)
     {
      bool isPH = IsPivotHigh(rates, i, len, copied);
      bool isPL = IsPivotLow(rates, i, len, copied);
      
      if(dirUp)
        {
         if(isPL && rates[i].low < lastLow)
           {
            lastLow = rates[i].low;
            timeLow = rates[i].time;
            if(lineCount > 0)
              {
               UpdateZigzagLine(lineCount - 1, timeHigh, lastHigh, timeLow, lastLow);
               UpdateZigzagLabel(lineCount - 1, timeLow, lastLow, (lastLow >= prevLow) ? "HL" : "LL", false);
              }
           }
         if(isPH && rates[i].high > lastLow)
           {
            prevHigh = lastHigh;
            lastHigh = rates[i].high;
            timeHigh = rates[i].time;
            dirUp = false;
            
            AddZigzagLine(lineCount, timeLow, lastLow, timeHigh, lastHigh);
            AddZigzagLabel(lineCount, timeHigh, lastHigh, (lastHigh >= prevHigh) ? "HH" : "LH", true);
            lineCount++;
           }
        }
      else // not dirUp
        {
         if(isPH && rates[i].high > lastHigh)
           {
            lastHigh = rates[i].high;
            timeHigh = rates[i].time;
            if(lineCount > 0)
              {
               UpdateZigzagLine(lineCount - 1, timeLow, lastLow, timeHigh, lastHigh);
               UpdateZigzagLabel(lineCount - 1, timeHigh, lastHigh, (lastHigh >= prevHigh) ? "HH" : "LH", true);
              }
           }
         if(isPL && rates[i].low < lastHigh)
           {
            prevLow = lastLow;
            lastLow = rates[i].low;
            timeLow = rates[i].time;
            dirUp = true;
            
            AddZigzagLine(lineCount, timeHigh, lastHigh, timeLow, lastLow);
            AddZigzagLabel(lineCount, timeLow, lastLow, (lastLow >= prevLow) ? "HL" : "LL", false);
            lineCount++;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Add Zigzag trendline                                             |
//+------------------------------------------------------------------+
void AddZigzagLine(int id, datetime t1, double p1, datetime t2, double p2)
  {
   string name = "AK10X_ZZ_Line_" + (string)id;
   if(ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2))
     {
      ObjectSetInteger(0, name, OBJPROP_COLOR, ColorZigzag);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }
  }

//+------------------------------------------------------------------+
//| Update Zigzag trendline                                          |
//+------------------------------------------------------------------+
void UpdateZigzagLine(int id, datetime t1, double p1, datetime t2, double p2)
  {
   string name = "AK10X_ZZ_Line_" + (string)id;
   if(ObjectFind(0, name) >= 0)
     {
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t1);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p1);
      ObjectSetInteger(0, name, OBJPROP_TIME, 1, t2);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 1, p2);
     }
   else
     {
      AddZigzagLine(id, t1, p1, t2, p2);
     }
  }

//+------------------------------------------------------------------+
//| Add Zigzag label                                                 |
//+------------------------------------------------------------------+
void AddZigzagLabel(int id, datetime t, double p, string txt, bool isHigh)
  {
   string name = "AK10X_ZZ_Label_" + (string)id;
   double offset = (isHigh ? 1 : -1) * GetLabelPadding() * 1.5;
   
   if(ObjectCreate(0, name, OBJ_TEXT, 0, t, p + offset))
     {
      ObjectSetString(0, name, OBJPROP_TEXT, txt);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, isHigh ? ANCHOR_LOWER : ANCHOR_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }
  }

//+------------------------------------------------------------------+
//| Update Zigzag label                                              |
//+------------------------------------------------------------------+
void UpdateZigzagLabel(int id, datetime t, double p, string txt, bool isHigh)
  {
   string name = "AK10X_ZZ_Label_" + (string)id;
   double offset = (isHigh ? 1 : -1) * GetLabelPadding() * 1.5;
   
   if(ObjectFind(0, name) >= 0)
     {
      ObjectSetInteger(0, name, OBJPROP_TIME, 0, t);
      ObjectSetDouble(0, name, OBJPROP_PRICE, 0, p + offset);
      ObjectSetString(0, name, OBJPROP_TEXT, txt);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, isHigh ? ANCHOR_LOWER : ANCHOR_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }
   else
     {
      AddZigzagLabel(id, t, p, txt, isHigh);
     }
  }

//+------------------------------------------------------------------+
//| Find nearest swing high above                                    |
//+------------------------------------------------------------------+
double GetNearestSwingHighAbove(double price)
  {
   SwingPoint highs[], lows[];
   GetHistoricalSwings(TradingPeriod, Minor_SwingLength, Minor_SwingLength, highs, lows, 10);
   double nearest = 0.0;
   double minDiff = 999999.0;
   for(int i = 0; i < ArraySize(highs); i++)
     {
      if(highs[i].price > price)
        {
         double diff = highs[i].price - price;
         if(diff < minDiff)
           {
            minDiff = diff;
            nearest = highs[i].price;
           }
        }
     }
   if(nearest <= 0.0) nearest = price + 100.0 * GetPipSize(); // default fallback
   return nearest;
  }

//+------------------------------------------------------------------+
//| Find nearest swing low below                                     |
//+------------------------------------------------------------------+
double GetNearestSwingLowBelow(double price)
  {
   SwingPoint highs[], lows[];
   GetHistoricalSwings(TradingPeriod, Minor_SwingLength, Minor_SwingLength, highs, lows, 10);
   double nearest = 0.0;
   double minDiff = 999999.0;
   for(int i = 0; i < ArraySize(lows); i++)
     {
      if(lows[i].price < price)
        {
         double diff = price - lows[i].price;
         if(diff < minDiff)
           {
            minDiff = diff;
            nearest = lows[i].price;
           }
        }
     }
   if(nearest <= 0.0) nearest = price - 100.0 * GetPipSize(); // default fallback
   return nearest;
  }

//+------------------------------------------------------------------+
//| Detect Setups (BOF-L, BOF-S, BOL, BOS) and Execute Limit Orders  |
//+------------------------------------------------------------------+
int GetRecentZigZagPoints(ZZPoint &points[], int maxCount)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, TradingPeriod, 1, 500, rates);
   if(copied <= 0) return 0;
   
   int len = Minor_SwingLength;
   
   ZZPoint tempPoints[];
   
   bool dirUp = false;
   double lastLow = 9999999.0;
   double lastHigh = 0.0;
   double prevLow = 9999999.0;
   double prevHigh = 0.0;
   datetime timeLow = 0;
   datetime timeHigh = 0;
   
   int startIdx = copied - 1 - len;
   bool initialized = false;
   
   for(int i = startIdx; i >= len; i--)
     {
      bool isPH = IsPivotHigh(rates, i, len, copied);
      bool isPL = IsPivotLow(rates, i, len, copied);
      if(isPH || isPL)
        {
         if(isPH)
           {
            lastHigh = rates[i].high;
            timeHigh = rates[i].time;
            dirUp = false;
           }
         else
           {
            lastLow = rates[i].low;
            timeLow = rates[i].time;
            dirUp = true;
           }
         startIdx = i - 1;
         initialized = true;
         break;
        }
     }
     
   if(!initialized) return 0;
   
   for(int i = startIdx; i >= len; i--)
     {
      bool isPH = IsPivotHigh(rates, i, len, copied);
      bool isPL = IsPivotLow(rates, i, len, copied);
      
      if(dirUp)
        {
         if(isPL && rates[i].low < lastLow)
           {
            lastLow = rates[i].low;
            timeLow = rates[i].time;
            int size = ArraySize(tempPoints);
            if(size > 0 && !tempPoints[size-1].isHigh)
              {
               tempPoints[size-1].price = lastLow;
               tempPoints[size-1].time = timeLow;
               tempPoints[size-1].label = (lastLow >= prevLow) ? "HL" : "LL";
              }
           }
         if(isPH && rates[i].high > lastLow)
           {
            prevHigh = lastHigh;
            lastHigh = rates[i].high;
            timeHigh = rates[i].time;
            dirUp = false;
            
            int size = ArraySize(tempPoints);
            ArrayResize(tempPoints, size + 1);
            tempPoints[size].price = lastHigh;
            tempPoints[size].time = timeHigh;
            tempPoints[size].isHigh = true;
            tempPoints[size].label = (lastHigh >= prevHigh) ? "HH" : "LH";
           }
        }
      else
        {
         if(isPH && rates[i].high > lastHigh)
           {
            lastHigh = rates[i].high;
            timeHigh = rates[i].time;
            int size = ArraySize(tempPoints);
            if(size > 0 && tempPoints[size-1].isHigh)
              {
               tempPoints[size-1].price = lastHigh;
               tempPoints[size-1].time = timeHigh;
               tempPoints[size-1].label = (lastHigh >= prevHigh) ? "HH" : "LH";
              }
           }
         if(isPL && rates[i].low < lastHigh)
           {
            prevLow = lastLow;
            lastLow = rates[i].low;
            timeLow = rates[i].time;
            dirUp = true;
            
            int size = ArraySize(tempPoints);
            ArrayResize(tempPoints, size + 1);
            tempPoints[size].price = lastLow;
            tempPoints[size].time = timeLow;
            tempPoints[size].isHigh = false;
            tempPoints[size].label = (lastLow >= prevLow) ? "HL" : "LL";
           }
        }
     }
     
   int totalPoints = ArraySize(tempPoints);
   int returnCount = MathMin(maxCount, totalPoints);
   ArrayResize(points, returnCount);
   for(int i = 0; i < returnCount; i++)
     {
      points[i] = tempPoints[totalPoints - 1 - i];
     }
   return returnCount;
  }

//+------------------------------------------------------------------+
//| Verify Touch Base Patterns                                       |
//+------------------------------------------------------------------+
bool IsWPattern(const ZZPoint &zz[], int size)
  {
   if(size < 4) return false;
   if(!zz[0].isHigh || zz[1].isHigh || !zz[2].isHigh || zz[3].isHigh) return false;
   bool doubleBottomOrHL = (zz[1].price >= zz[3].price);
   bool breakout = (zz[0].price > zz[2].price);
   return (doubleBottomOrHL && breakout);
  }

bool IsInverseHS(const ZZPoint &zz[], int size)
  {
   if(size < 6) return false;
   if(!zz[0].isHigh || zz[1].isHigh || !zz[2].isHigh || zz[3].isHigh || !zz[4].isHigh || zz[5].isHigh) return false;
   bool headLowerLeft = (zz[3].price < zz[5].price);
   bool headLowerRight = (zz[3].price < zz[1].price);
   bool rightHigherHead = (zz[1].price > zz[3].price);
   bool breakout = (zz[0].price > zz[2].price);
   return (headLowerLeft && headLowerRight && rightHigherHead && breakout);
  }

bool IsMPattern(const ZZPoint &zz[], int size)
  {
   if(size < 4) return false;
   if(zz[0].isHigh || !zz[1].isHigh || zz[2].isHigh || !zz[3].isHigh) return false;
   bool doubleTopOrLH = (zz[1].price <= zz[3].price);
   bool breakout = (zz[0].price < zz[2].price);
   return (doubleTopOrLH && breakout);
  }

bool IsHeadAndShoulders(const ZZPoint &zz[], int size)
  {
   if(size < 6) return false;
   if(zz[0].isHigh || !zz[1].isHigh || zz[2].isHigh || !zz[3].isHigh || zz[4].isHigh || !zz[5].isHigh) return false;
   bool headHigherLeft = (zz[3].price > zz[5].price);
   bool headHigherRight = (zz[3].price > zz[1].price);
   bool rightLowerHead = (zz[1].price < zz[3].price);
   bool breakout = (zz[0].price < zz[2].price);
   return (headHigherLeft && headHigherRight && rightLowerHead && breakout);
  }

//+------------------------------------------------------------------+
//| Get Higher Timeframe Trend                                       |
//+------------------------------------------------------------------+
ENUM_TREND GetHTFTrend()
  {
   SwingPoint htf_Highs[], htf_Lows[];
   GetHistoricalSwings(HigherPeriod, HTF_SwingLeft, HTF_SwingRight, htf_Highs, htf_Lows, 5);
   return CalculateTrendFromSwings(htf_Highs, htf_Lows);
  }

//+------------------------------------------------------------------+
//| Get Next Virgin VRZ High above entry price                       |
//+------------------------------------------------------------------+
double GetNextVRZHigh(double entryPrice)
  {
   SwingPoint highs[], lows[];
   GetHistoricalSwings(HigherPeriod, HTF_SwingLeft, HTF_SwingRight, highs, lows, 20);
   double nearest = 0.0;
   double minDiff = 999999.0;
   for(int i = 0; i < ArraySize(highs); i++)
     {
      if(highs[i].price > entryPrice)
        {
         datetime swingTime = GetExactSwingTimeTTF(highs[i].time, highs[i].price, true);
         datetime breakoutTime = GetBreakoutTimeTTF(highs[i].price, swingTime, true);
         if(breakoutTime == 0)
           {
            double diff = highs[i].price - entryPrice;
            if(diff < minDiff)
              {
               minDiff = diff;
               nearest = highs[i].price;
              }
           }
        }
     }
   if(nearest <= 0.0)
     {
      if(vrzHigh_1h > entryPrice) nearest = vrzHigh_1h;
      else if(vrzHigh_15m > entryPrice) nearest = vrzHigh_15m;
      else nearest = entryPrice + 150.0 * GetPipSize();
     }
   return nearest;
  }

//+------------------------------------------------------------------+
//| Get Next Virgin VRZ Low below entry price                        |
//+------------------------------------------------------------------+
double GetNextVRZLow(double entryPrice)
  {
   SwingPoint highs[], lows[];
   GetHistoricalSwings(HigherPeriod, HTF_SwingLeft, HTF_SwingRight, highs, lows, 20);
   double nearest = 0.0;
   double minDiff = 999999.0;
   for(int i = 0; i < ArraySize(lows); i++)
     {
      if(lows[i].price < entryPrice)
        {
         datetime swingTime = GetExactSwingTimeTTF(lows[i].time, lows[i].price, false);
         datetime breakoutTime = GetBreakoutTimeTTF(lows[i].price, swingTime, false);
         if(breakoutTime == 0)
           {
            double diff = entryPrice - lows[i].price;
            if(diff < minDiff)
              {
               minDiff = diff;
               nearest = lows[i].price;
              }
           }
        }
     }
   if(nearest <= 0.0)
     {
      if(vrzLow_1h > 0 && vrzLow_1h < entryPrice) nearest = vrzLow_1h;
      else if(vrzLow_15m > 0 && vrzLow_15m < entryPrice) nearest = vrzLow_15m;
      else nearest = entryPrice - 150.0 * GetPipSize();
     }
   return nearest;
  }

//+------------------------------------------------------------------+
//| Rule 1 - Market Context Validation                               |
//+------------------------------------------------------------------+
bool ValidateRule1(ENUM_SETUP_TYPE setup, string &failedReason)
  {
   ENUM_TREND htfTrend = GetHTFTrend();
   ENUM_TREND ttfTrend = ttf_Trend;
   
   if(htfTrend != TREND_UP && htfTrend != TREND_DOWN)
     {
      failedReason = "HTF Trend is Sideways/Trapping";
      return false;
     }
     
   bool isBuySetup = (setup == SETUP_BOL || setup == SETUP_BOFL);
   bool isSellSetup = (setup == SETUP_BOS || setup == SETUP_BOFS);
   
   if(isBuySetup && ttfTrend != TREND_UP)
     {
      failedReason = "TTF Trend is not UP for Buy Setup";
      return false;
     }
   if(isSellSetup && ttfTrend != TREND_DOWN)
     {
      failedReason = "TTF Trend is not DOWN for Sell Setup";
      return false;
     }
     
   SwingPoint highs[], lows[];
   GetHistoricalSwings(TradingPeriod, Minor_SwingLength, Minor_SwingLength, highs, lows, 5);
   if(ArraySize(highs) < 2 || ArraySize(lows) < 2)
     {
      failedReason = "Insufficient swing points for Market Structure";
      return false;
     }
     
   ZZPoint zz[];
   int zzCount = GetRecentZigZagPoints(zz, 10);
   if(isBuySetup)
     {
      if(!IsWPattern(zz, zzCount) && !IsInverseHS(zz, zzCount))
        {
         failedReason = "No bullish Touch Base Pattern (W or iH&S)";
         return false;
        }
     }
   else if(isSellSetup)
     {
      if(!IsMPattern(zz, zzCount) && !IsHeadAndShoulders(zz, zzCount))
        {
         failedReason = "No bearish Touch Base Pattern (M or H&S)";
         return false;
        }
     }
     
   return true;
  }

//+------------------------------------------------------------------+
//| Initialize Breakout state variables                              |
//+------------------------------------------------------------------+
void InitBreakout(string type, double price, datetime time)
  {
   currentBreakout.isValid = true;
   currentBreakout.levelType = type;
   currentBreakout.levelPrice = price;
   currentBreakout.time = time;
   currentBreakout.setup = SETUP_NONE;
   currentBreakout.reaction = "None";
   currentBreakout.status = "N/A";
   currentBreakout.grade = "N/A";
   currentBreakout.riskFreeDone = false;
   currentBreakout.currentLot = BaseLotSize;
   currentBreakout.fillTime = 0;
   currentBreakout.positionTicket = 0;
   
   PrintFormat("LTS MENTOR: Detected breakout on %s at %f, Time: %s", type, price, TimeToString(time));
  }

//+------------------------------------------------------------------+
//| Detect fresh breakout from last closed candle                    |
//+------------------------------------------------------------------+
void DetectNewBreakout()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, TradingPeriod, 1, 2, rates) < 2) return;
   
   double levelHighs[] = {vrzHigh_15m, vrzHigh_1h};
   double levelLows[]  = {vrzLow_15m, vrzLow_1h};
   
   for(int i = 0; i < ArraySize(levelHighs); i++)
     {
      double vrzHigh = levelHighs[i];
      if(vrzHigh > 0 && rates[0].close > vrzHigh && rates[1].close <= vrzHigh)
        {
         if(currentBreakout.isValid && currentBreakout.levelType == "VRZ High" && currentBreakout.levelPrice == vrzHigh && currentBreakout.time == rates[0].time)
            return;
            
         InitBreakout("VRZ High", vrzHigh, rates[0].time);
         return;
        }
     }
     
   for(int i = 0; i < ArraySize(levelLows); i++)
     {
      double vrzLow = levelLows[i];
      if(vrzLow > 0 && rates[0].close < vrzLow && rates[1].close >= vrzLow)
        {
         if(currentBreakout.isValid && currentBreakout.levelType == "VRZ Low" && currentBreakout.levelPrice == vrzLow && currentBreakout.time == rates[0].time)
            return;
            
         InitBreakout("VRZ Low", vrzLow, rates[0].time);
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| Classify price reaction and generate logical thinker setup       |
//+------------------------------------------------------------------+
void ClassifyReactionAndGenerateSetup()
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, TradingPeriod, 0, 50, rates);
   if(copied <= 0) return;
   
   int breakoutIdx = -1;
   for(int i = 0; i < copied; i++)
     {
      if(rates[i].time == currentBreakout.time)
        {
         breakoutIdx = i;
         break;
        }
     }
     
   if(breakoutIdx == -1 || breakoutIdx <= 1) return;
   
   double postClose = rates[breakoutIdx - 1].close;
   double vrz = currentBreakout.levelPrice;
   
   string reaction = "Continuation";
   ENUM_SETUP_TYPE setup = SETUP_NONE;
   
   if(currentBreakout.levelType == "VRZ High")
     {
      if(postClose < vrz)
        {
         reaction = "Immediate Reversal";
         setup = SETUP_BOFS;
        }
      else
        {
         reaction = "Continuation";
         setup = SETUP_BOL;
        }
     }
   else if(currentBreakout.levelType == "VRZ Low")
     {
      if(postClose > vrz)
        {
         reaction = "Immediate Reversal";
         setup = SETUP_BOFL;
        }
      else
        {
         reaction = "Continuation";
         setup = SETUP_BOS;
        }
     }
     
   currentBreakout.reaction = reaction;
   currentBreakout.setup = setup;
   
   PrintFormat("LTS MENTOR: Classifying reaction: %s (Setup: %s)", reaction, EnumToString(setup));
   
   string failedReason = "";
   bool r1_pass = ValidateRule1(setup, failedReason);
   bool r2_pass = (reaction == "Continuation" || reaction == "Immediate Reversal");
   
   string mode = "N/A";
   string grade = "N/A";
   double target = 0.0;
   ENUM_TREND htf = GetHTFTrend();
   ENUM_TREND ttf = ttf_Trend;
   bool r3_pass = false;
   
   if(setup == SETUP_BOL || setup == SETUP_BOFL)
     {
      if(htf == TREND_UP && ttf == TREND_UP) { mode = "Investor"; target = GetNextVRZHigh(vrz); grade = "A+++"; r3_pass = true; }
      else if(htf == TREND_DOWN && ttf == TREND_UP) { mode = "Trader"; target = GetNearestSwingHighAbove(vrz); grade = "A++"; r3_pass = true; }
     }
   else if(setup == SETUP_BOS || setup == SETUP_BOFS)
     {
      if(htf == TREND_DOWN && ttf == TREND_DOWN) { mode = "Investor"; target = GetNextVRZLow(vrz); grade = "A+++"; r3_pass = true; }
      else if(htf == TREND_UP && ttf == TREND_DOWN) { mode = "Trader"; target = GetNearestSwingLowBelow(vrz); grade = "A++"; r3_pass = true; }
     }
     
   double sl = 0.0;
   double buffer = StopLossBuffer * GetPipSize();
   double breakoutHigh = rates[breakoutIdx].high;
   double breakoutLow = rates[breakoutIdx].low;
   
   if(setup == SETUP_BOL || setup == SETUP_BOFL) sl = breakoutLow - buffer;
   else sl = breakoutHigh + buffer;
   
   double risk = MathAbs(vrz - sl);
   
   // --- Fallback Target / TP calculation to prevent 0.00 Take Profit and invalid RR
   if(target <= 0.0)
     {
      if(setup == SETUP_BOL || setup == SETUP_BOFL)
        {
         target = GetNearestSwingHighAbove(vrz);
         if(target <= 0.0 || target <= vrz) target = GetNextVRZHigh(vrz);
         if(target <= 0.0 || target <= vrz) target = vrz + 3.0 * risk;
        }
      else
        {
         target = GetNearestSwingLowBelow(vrz);
         if(target <= 0.0 || target >= vrz) target = GetNextVRZLow(vrz);
         if(target <= 0.0 || target >= vrz) target = vrz - 3.0 * risk;
        }
     }
      
   double reward = MathAbs(target - vrz);
   double rr = (risk > 0) ? (reward / risk) : 0.0;
   
   bool r4_pass = (risk > 0 && rr >= MinRiskReward);
   
   if(r1_pass && r2_pass && r3_pass && r4_pass)
     {
      currentBreakout.sl = sl;
      currentBreakout.tp = target;
      currentBreakout.grade = grade;
      currentBreakout.status = "Pending Order";
      PrintFormat("LTS MENTOR: Validation Success! Setup: %s, Mode: %s, Grade: %s, RR: 1:%.1f", 
                  EnumToString(setup), mode, grade, rr);
     }
   else
     {
      currentBreakout.isValid = true;
      currentBreakout.status = "Failed Validation";
      currentBreakout.sl = sl;
      currentBreakout.tp = target;
      currentBreakout.setup = setup;
      currentBreakout.reaction = reaction;
      currentBreakout.grade = grade;
      PrintFormat("LTS MENTOR: Validation Fail! R1: %s, R2: %s, R3: %s, R4: %s (RR: 1:%.1f). Reason: %s. Keeping VRZ on HUD.", 
                  r1_pass?"PASS":"FAIL", r2_pass?"PASS":"FAIL", r3_pass?"PASS":"FAIL", r4_pass?"PASS":"FAIL", rr, failedReason);
     }
  }

//+------------------------------------------------------------------+
//| Get active position ticket for this EA                           |
//+------------------------------------------------------------------+
ulong GetRunningPositionTicket()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
         string comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(comment, "AK10X_") == 0) return ticket;
        }
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Apply Risk-Free trail logic (50% partial close + BE)             |
//+------------------------------------------------------------------+
void CheckAndApplyRiskFree(ulong ticket)
  {
   if(!PositionSelectByTicket(ticket)) return;
   
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double vol = PositionGetDouble(POSITION_VOLUME);
   long type = PositionGetInteger(POSITION_TYPE);
   
   double riskDist = MathAbs(entry - currentSL);
   if(riskDist <= 0.0) return;
   
   double bid = GetLatestBid();
   double ask = GetLatestAsk();
   double currentPrice = (type == POSITION_TYPE_BUY) ? bid : ask;
   
   bool isBuy = (type == POSITION_TYPE_BUY);
   bool conditionMet = false;
   
   if(isBuy)
     {
      if(currentPrice - entry >= riskDist) conditionMet = true;
     }
   else
     {
      if(entry - currentPrice >= riskDist) conditionMet = true;
     }
     
   if(conditionMet)
     {
      double closeVol = vol * 0.5;
      double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      closeVol = MathRound(closeVol / step) * step;
      if(closeVol < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
         closeVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         
      if(closeVol >= vol) closeVol = 0.0;
      
      bool closeOk = true;
      if(closeVol > 0.0)
        {
         closeOk = trade.PositionClosePartial(ticket, closeVol);
        }
        
      if(closeOk)
        {
         if(trade.PositionModify(ticket, entry, tp))
           {
            currentBreakout.riskFreeDone = true;
            currentBreakout.sl = entry;
            currentBreakout.currentLot = vol - closeVol;
            PrintFormat("LTS MENTOR: Risk-Free activated! Closed partial %f lot, moved remaining to Break-Even at %f", closeVol, entry);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Execute local market order on VRZ retest                         |
//+------------------------------------------------------------------+
void ExecuteMarketOrder()
  {
   if(!AutoTradingEnabled || IsNewsTime())
     {
      Print("LTS MENTOR: Order execution blocked (Algo Offline or news active).");
      return;
     }
     
   double entry = currentBreakout.levelPrice;
   double sl = currentBreakout.sl;
   double tp = currentBreakout.tp;
   ENUM_SETUP_TYPE setup = currentBreakout.setup;
   
   string setupName = EnumToString(setup);
   StringReplace(setupName, "SETUP_", "");
   
   string comment = "AK10X_" + setupName + "_" + currentBreakout.grade;
   double lot = CalculateLotSize(entry, sl);
   
   bool res = false;
   if(setup == SETUP_BOL || setup == SETUP_BOFL)
     {
      double ask = GetLatestAsk();
      res = trade.Buy(lot, _Symbol, ask, sl, tp, comment);
     }
   else if(setup == SETUP_BOS || setup == SETUP_BOFS)
     {
      double bid = GetLatestBid();
      res = trade.Sell(lot, _Symbol, bid, sl, tp, comment);
     }
     
   if(res)
     {
      currentBreakout.status = "Running Order";
      currentBreakout.fillTime = TimeCurrent();
      currentBreakout.positionTicket = GetRunningPositionTicket();
      WriteJournal("EXECUTE", currentBreakout.positionTicket, comment, currentBreakout.grade, entry, sl, tp);
      PrintFormat("LTS MENTOR: Retest filled! Executed Market Order for %s at %f", setupName, entry);
     }
  }

//+------------------------------------------------------------------+
//| Run core state machine logic                                     |
//+------------------------------------------------------------------+
void ProcessBreakoutStateMachine()
  {
   ulong runningTicket = GetRunningPositionTicket();
   if(runningTicket > 0)
     {
      currentBreakout.isValid = true;
      currentBreakout.status = "Running Order";
      currentBreakout.positionTicket = runningTicket;
      
      if(PositionSelectByTicket(runningTicket))
        {
         currentBreakout.currentLot = PositionGetDouble(POSITION_VOLUME);
         currentBreakout.sl = PositionGetDouble(POSITION_SL);
         currentBreakout.tp = PositionGetDouble(POSITION_TP);
         currentBreakout.fillTime = (datetime)PositionGetInteger(POSITION_TIME);
        }
        
      if(EnableRiskFree && !currentBreakout.riskFreeDone)
        {
         CheckAndApplyRiskFree(runningTicket);
        }
      return;
     }
     
   if(currentBreakout.status == "Running Order" && runningTicket == 0)
     {
      currentBreakout.status = "Closed";
      currentBreakout.isValid = false;
      currentBreakout.setup = SETUP_NONE;
      currentBreakout.reaction = "None";
      return;
     }
     
   // Check if a new breakout occurred (this will overwrite the current breakout if it is different)
   DetectNewBreakout();
   
   if(!currentBreakout.isValid)
     {
      return;
     }
     
   if(currentBreakout.status == "N/A" || currentBreakout.status == "")
     {
      datetime currentBarTime = iTime(_Symbol, TradingPeriod, 0);
      if(currentBarTime > currentBreakout.time)
        {
         ClassifyReactionAndGenerateSetup();
        }
      return;
     }
     
   if(currentBreakout.status == "Failed Validation")
     {
      double bid = GetLatestBid();
      bool isLong = (currentBreakout.setup == SETUP_BOL || currentBreakout.setup == SETUP_BOFL);
      
      bool hitTP = isLong ? (bid >= currentBreakout.tp) : (bid <= currentBreakout.tp);
      bool hitSL = isLong ? (bid <= currentBreakout.sl) : (bid >= currentBreakout.sl);
      
      if(hitTP || hitSL)
        {
         currentBreakout.isValid = false;
         currentBreakout.status = "N/A";
         currentBreakout.setup = SETUP_NONE;
         currentBreakout.reaction = "None";
         Print("LTS MENTOR: Failed validation breakout invalidated. Price hit TP/SL.");
        }
      return;
     }
     
   if(currentBreakout.status == "Pending Order")
     {
      double bid = GetLatestBid();
      double ask = GetLatestAsk();
      
      bool isLong = (currentBreakout.setup == SETUP_BOL || currentBreakout.setup == SETUP_BOFL);
      
      bool hitTP = isLong ? (bid >= currentBreakout.tp) : (bid <= currentBreakout.tp);
      bool hitSL = isLong ? (bid <= currentBreakout.sl) : (bid >= currentBreakout.sl);
      
      if(hitTP || hitSL)
        {
         currentBreakout.isValid = false;
         currentBreakout.status = "N/A";
         currentBreakout.setup = SETUP_NONE;
         currentBreakout.reaction = "None";
         Print("LTS MENTOR: Breakout invalidated. Price hit TP/SL before retest.");
         return;
        }
        
      if(currentBreakout.reaction == "Continuation")
        {
         double nextSwing = isLong ? GetNearestSwingHighAbove(currentBreakout.levelPrice) : GetNearestSwingLowBelow(currentBreakout.levelPrice);
         double nextVRZ = isLong ? GetRecentVirginHigh(HigherPeriod, HTF_SwingLeft, HTF_SwingRight) : GetRecentVirginLow(HigherPeriod, HTF_SwingLeft, HTF_SwingRight);
         
         if(isLong)
           {
            if(nextVRZ <= currentBreakout.levelPrice) nextVRZ = 9999999.0;
            if(bid >= nextSwing || bid >= nextVRZ)
              {
               currentBreakout.isValid = false;
               currentBreakout.status = "N/A";
               currentBreakout.setup = SETUP_NONE;
               currentBreakout.reaction = "Direct Breakout";
               Print("LTS MENTOR: Invalidated (Direct Breakout - price hit next Swing/VRZ before retest).");
               return;
              }
           }
         else
           {
            if(nextVRZ >= currentBreakout.levelPrice || nextVRZ <= 0.0) nextVRZ = 0.0;
            if(bid <= nextSwing || (nextVRZ > 0 && bid <= nextVRZ))
              {
               currentBreakout.isValid = false;
               currentBreakout.status = "N/A";
               currentBreakout.setup = SETUP_NONE;
               currentBreakout.reaction = "Direct Breakout";
               Print("LTS MENTOR: Invalidated (Direct Breakout - price hit next Swing/VRZ before retest).");
               return;
              }
           }
        }
        
      bool trigger = false;
      if(isLong)
        {
         if(ask <= currentBreakout.levelPrice) trigger = true;
        }
      else
        {
         if(bid >= currentBreakout.levelPrice) trigger = true;
        }
        
      if(trigger)
        {
         ExecuteMarketOrder();
        }
     }
  }

//+------------------------------------------------------------------+
//| Verify historical breakout validity and recover state on startup|
//+------------------------------------------------------------------+
bool CheckHistoricalBreakoutValidity(string type, double price, datetime time, int breakoutIdxInRates)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, TradingPeriod, 0, breakoutIdxInRates + 5, rates);
   if(copied <= 0) return false;
   
   int idx = -1;
   for(int i = 0; i < copied; i++)
     {
      if(rates[i].time == time) { idx = i; break; }
     }
   if(idx == -1 || idx == 0) return false;
   
   // Pre-calculate SL and Target TP in case we return early for idx == 1
   double sl = 0.0;
   double buffer = StopLossBuffer * GetPipSize();
   double breakoutHigh = rates[idx].high;
   double breakoutLow = rates[idx].low;
   
   if(type == "VRZ High") sl = breakoutLow - buffer;
   else sl = breakoutHigh + buffer;
   
   double target = 0.0;
   ENUM_TREND htf = GetHTFTrend();
   ENUM_TREND ttf = ttf_Trend;
   double risk = MathAbs(price - sl);
   
   if(type == "VRZ High")
     {
      if(htf == TREND_UP && ttf == TREND_UP) { target = GetNextVRZHigh(price); }
      else { target = GetNearestSwingHighAbove(price); }
      
      if(target <= 0.0 || target <= price) target = GetNextVRZHigh(price);
      if(target <= 0.0 || target <= price) target = price + 3.0 * risk;
     }
   else
     {
      if(htf == TREND_DOWN && ttf == TREND_DOWN) { target = GetNextVRZLow(price); }
      else { target = GetNearestSwingLowBelow(price); }
      
      if(target <= 0.0 || target >= price) target = GetNextVRZLow(price);
      if(target <= 0.0 || target >= price) target = price - 3.0 * risk;
     }
   
   // If the breakout candle is the last closed candle (index 1), rules validation is not yet complete.
   // We recover it as a fresh breakout (status = "") so that the state machine can check it.
   if(idx == 1)
     {
      currentBreakout.isValid = true;
      currentBreakout.levelType = type;
      currentBreakout.levelPrice = price;
      currentBreakout.time = time;
      currentBreakout.sl = sl;
      currentBreakout.tp = target;
      currentBreakout.setup = SETUP_NONE;
      currentBreakout.reaction = "None";
      currentBreakout.status = "";
      currentBreakout.grade = "N/A";
      currentBreakout.riskFreeDone = false;
      currentBreakout.currentLot = BaseLotSize;
      currentBreakout.fillTime = 0;
      currentBreakout.positionTicket = 0;
      
      PrintFormat("LTS MENTOR: Startup recovered fresh breakout on %s at %f", type, price);
      return true;
     }
     
   double postClose = rates[idx - 1].close;
   string reaction = "Continuation";
   ENUM_SETUP_TYPE setup = SETUP_NONE;
   
   if(type == "VRZ High")
     {
      if(postClose < price) { reaction = "Immediate Reversal"; setup = SETUP_BOFS; }
      else { reaction = "Continuation"; setup = SETUP_BOL; }
     }
   else
     {
      if(postClose > price) { reaction = "Immediate Reversal"; setup = SETUP_BOFL; }
      else { reaction = "Continuation"; setup = SETUP_BOS; }
     }
     
   string grade = "A++";
   
   if(setup == SETUP_BOL || setup == SETUP_BOFL)
     {
      if(htf == TREND_UP && ttf == TREND_UP) { grade = "A+++"; }
      else { grade = "A++"; }
     }
   else
     {
      if(htf == TREND_DOWN && ttf == TREND_DOWN) { grade = "A+++"; }
      else { grade = "A++"; }
     }
     
   double reward = MathAbs(target - price);
   double rr = (risk > 0) ? (reward / risk) : 0.0;
   
   if(risk <= 0.0) return false;
   
   string failedReason = "";
   bool r1_pass = ValidateRule1(setup, failedReason);
   bool r2_pass = (reaction == "Continuation" || reaction == "Immediate Reversal");
   bool r3_pass = false;
   if(setup == SETUP_BOL || setup == SETUP_BOFL)
     {
      if(htf == TREND_UP && ttf == TREND_UP) { r3_pass = true; }
      else if(htf == TREND_DOWN && ttf == TREND_UP) { r3_pass = true; }
     }
   else if(setup == SETUP_BOS || setup == SETUP_BOFS)
     {
      if(htf == TREND_DOWN && ttf == TREND_DOWN) { r3_pass = true; }
      else if(htf == TREND_UP && ttf == TREND_DOWN) { r3_pass = true; }
     }
   bool r4_pass = (rr >= MinRiskReward);
   
   bool passed = (r1_pass && r2_pass && r3_pass && r4_pass);
   
   bool isLong = (setup == SETUP_BOL || setup == SETUP_BOFL);
   
   for(int i = idx - 2; i >= 0; i--)
     {
      double highVal = rates[i].high;
      double lowVal = rates[i].low;
      
      bool hitTP = isLong ? (highVal >= target) : (lowVal <= target);
      bool hitSL = isLong ? (lowVal <= sl) : (highVal >= sl);
      if(hitTP || hitSL) return false;
      
      if(passed)
        {
         bool filled = false;
         if(isLong) { if(lowVal <= price) filled = true; }
         else { if(highVal >= price) filled = true; }
         if(filled) return false;
         
         if(reaction == "Continuation")
           {
            double nextSwing = isLong ? GetNearestSwingHighAbove(price) : GetNearestSwingLowBelow(price);
            if(isLong) { if(highVal >= nextSwing) return false; }
            else { if(lowVal <= nextSwing) return false; }
           }
        }
     }
     
   currentBreakout.isValid = true;
   currentBreakout.levelType = type;
   currentBreakout.levelPrice = price;
   currentBreakout.time = time;
   currentBreakout.sl = sl;
   currentBreakout.tp = target;
   currentBreakout.setup = setup;
   currentBreakout.reaction = reaction;
   currentBreakout.status = passed ? "Pending Order" : "Failed Validation";
   currentBreakout.grade = grade;
   currentBreakout.riskFreeDone = false;
   currentBreakout.currentLot = BaseLotSize;
   currentBreakout.fillTime = 0;
   currentBreakout.positionTicket = 0;
   
   PrintFormat("LTS MENTOR: Startup recovered valid breakout on %s at %f, Status: %s", type, price, currentBreakout.status);
   return true;
  }

//+------------------------------------------------------------------+
//| Startup scanning routine to recover active breakout states        |
//+------------------------------------------------------------------+
void DetectBreakoutFromHistory()
  {
   ulong runningTicket = GetRunningPositionTicket();
   if(runningTicket > 0)
     {
      if(PositionSelectByTicket(runningTicket))
        {
         string comment = PositionGetString(POSITION_COMMENT);
         string parts[];
         int splitCount = StringSplit(comment, '_', parts);
         
         currentBreakout.isValid = true;
         currentBreakout.status = "Running Order";
         currentBreakout.positionTicket = runningTicket;
         currentBreakout.levelPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         currentBreakout.sl = PositionGetDouble(POSITION_SL);
         currentBreakout.tp = PositionGetDouble(POSITION_TP);
         currentBreakout.currentLot = PositionGetDouble(POSITION_VOLUME);
         currentBreakout.fillTime = (datetime)PositionGetInteger(POSITION_TIME);
         
         if(splitCount >= 3)
           {
            string setupName = parts[2];
            if(setupName == "BOL") { currentBreakout.setup = SETUP_BOL; currentBreakout.reaction = "Continuation"; currentBreakout.levelType = "VRZ High"; }
            else if(setupName == "BOS") { currentBreakout.setup = SETUP_BOS; currentBreakout.reaction = "Continuation"; currentBreakout.levelType = "VRZ Low"; }
            else if(setupName == "BOFS") { currentBreakout.setup = SETUP_BOFS; currentBreakout.reaction = "Immediate Reversal"; currentBreakout.levelType = "VRZ High"; }
            else if(setupName == "BOFL") { currentBreakout.setup = SETUP_BOFL; currentBreakout.reaction = "Immediate Reversal"; currentBreakout.levelType = "VRZ Low"; }
           }
         if(splitCount >= 4) currentBreakout.grade = parts[3];
         
         bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         double entry = currentBreakout.levelPrice;
         if(isBuy && currentBreakout.sl >= entry - _Point) currentBreakout.riskFreeDone = true;
         if(!isBuy && currentBreakout.sl <= entry + _Point && currentBreakout.sl > 0) currentBreakout.riskFreeDone = true;
         
         Print("LTS MENTOR: Startup recovered running position.");
         return;
        }
     }
     
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, TradingPeriod, 1, 200, rates);
   if(copied <= 0) return;
   
   // Fetch all historical swings to scan for breakouts
   SwingPoint highsHTF[], lowsHTF[];
   GetHistoricalSwings(HigherPeriod, HTF_SwingLeft, HTF_SwingRight, highsHTF, lowsHTF, 150);
   
   SwingPoint highsHHTF[], lowsHHTF[];
   GetHistoricalSwings(HigherHighPeriod, HTF_SwingLeft, HTF_SwingRight, highsHHTF, lowsHHTF, 150);
   
   for(int idx = 0; idx < copied - 2; idx++)
     {
      datetime tVal = rates[idx].time;
      double cVal = rates[idx].close;
      double prevCVal = rates[idx+1].close;
      
      // Check Highs HTF
      for(int h = 0; h < ArraySize(highsHTF); h++)
        {
         double p = highsHTF[h].price;
         datetime t = highsHTF[h].time;
         if(tVal >= t && cVal > p && prevCVal <= p)
           {
            if(CheckHistoricalBreakoutValidity("VRZ High", p, tVal, idx + 1)) return; // idx + 1 because rates starts at chart index 1
           }
        }
      // Check Highs HHTF
      for(int h = 0; h < ArraySize(highsHHTF); h++)
        {
         double p = highsHHTF[h].price;
         datetime t = highsHHTF[h].time;
         if(tVal >= t && cVal > p && prevCVal <= p)
           {
            if(CheckHistoricalBreakoutValidity("VRZ High", p, tVal, idx + 1)) return;
           }
        }
      // Check Lows HTF
      for(int l = 0; l < ArraySize(lowsHTF); l++)
        {
         double p = lowsHTF[l].price;
         datetime t = lowsHTF[l].time;
         if(tVal >= t && cVal < p && prevCVal >= p)
           {
            if(CheckHistoricalBreakoutValidity("VRZ Low", p, tVal, idx + 1)) return;
           }
        }
      // Check Lows HHTF
      for(int l = 0; l < ArraySize(lowsHHTF); l++)
        {
         double p = lowsHHTF[l].price;
         datetime t = lowsHHTF[l].time;
         if(tVal >= t && cVal < p && prevCVal >= p)
           {
            if(CheckHistoricalBreakoutValidity("VRZ Low", p, tVal, idx + 1)) return;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Dynamic lot calculation helper                                   |
//+------------------------------------------------------------------+
double CalculateLotSize(double entry, double sl)
  {
   if(RiskPercent <= 0.0) return BaseLotSize;
   
   double slDist = MathAbs(entry - sl);
   if(slDist <= 0.0) return BaseLotSize;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (RiskPercent / 100.0);
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return BaseLotSize;
   
   double pointValue = tickValue / tickSize;
   double totalLot = riskMoney / (slDist * pointValue);
   
   double lot = totalLot / 2.0;
   
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   lot = MathRound(lot / step) * step;
   if(lot < minVol) lot = minVol;
   if(lot > maxVol) lot = maxVol;
   
   return lot;
  }

void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
         trade.PositionClose(ticket);
        }
     }
  }

//+------------------------------------------------------------------+
void ManageActivePositions()
  {
   ulong ticket = GetRunningPositionTicket();
   if(ticket > 0 && EnableRiskFree && !currentBreakout.riskFreeDone)
     {
      CheckAndApplyRiskFree(ticket);
     }
  }

void ManagePendingOrders()
  {
   // Monitored locally inside ProcessBreakoutStateMachine
  }

//--- News Event Info Structure
struct NewsEventInfo
  {
   datetime                       eventTime;
   string                         currency;
   string                         name;
   string                         status; // "Active", "Upcoming", "None"
   ENUM_CALENDAR_EVENT_IMPORTANCE importance;
   long                           actualValue;
   long                           forecastValue;
   long                           prevValue;
   ENUM_CALENDAR_EVENT_IMPACT     impact;
  };

//+------------------------------------------------------------------+
//| Format time difference to human readable format                 |
//+------------------------------------------------------------------+
string FormatTimeDifference(datetime eventTime)
  {
   datetime timeCurrent = TimeCurrent();
   int diffSeconds = (int)(eventTime - timeCurrent);
   
   if(diffSeconds < 0)
     {
      int absDiff = MathAbs(diffSeconds);
      int mins = absDiff / 60;
      if(mins < 60)
         return StringFormat("%dm ago", mins);
      int hours = mins / 60;
      mins = mins % 60;
      return StringFormat("%dh%dm ago", hours, mins);
     }
   else
     {
      int mins = diffSeconds / 60;
      if(mins < 60)
         return StringFormat("in %dm", mins);
      int hours = mins / 60;
      mins = mins % 60;
      return StringFormat("in %dh%dm", hours, mins);
     }
  }

//+------------------------------------------------------------------+
//| Format time to Indian Standard Time (IST, UTC+5:30) AM/PM       |
//+------------------------------------------------------------------+
string FormatTimeIST(datetime serverTimeValue)
  {
   datetime gmt = TimeGMT();
   datetime server = TimeTradeServer();
   int offset = (int)(server - gmt);
   
   // Convert server time to GMT, then GMT to IST (UTC + 5:30)
   datetime istTime = serverTimeValue - offset + 19800; // 5.5 * 3600 = 19800
   
   MqlDateTime dt;
   TimeToStruct(istTime, dt);
   
   int hour = dt.hour;
   int min = dt.min;
   string am_pm = "AM";
   
   if(hour >= 12)
     {
      am_pm = "PM";
      if(hour > 12) hour -= 12;
     }
   if(hour == 0) hour = 12;
   
   return StringFormat("%02d:%02d %s", hour, min, am_pm);
  }

//+------------------------------------------------------------------+
//| Get importance name and color mapped to folder colors            |
//+------------------------------------------------------------------+
string GetImportanceName(ENUM_CALENDAR_EVENT_IMPORTANCE imp, color &clr)
  {
   switch(imp)
     {
      case CALENDAR_IMPORTANCE_HIGH:
         clr = clrRed;
         return "Red Folder (High)";
      case CALENDAR_IMPORTANCE_MODERATE:
         clr = clrOrange;
         return "Orange Folder (Medium)";
      case CALENDAR_IMPORTANCE_LOW:
         clr = clrYellow;
         return "Yellow Folder (Low)";
      default:
         clr = clrGray;
         return "Grey Folder (None/Low)";
     }
  }

//+------------------------------------------------------------------+
//| Override importance to match external calendar standard          |
//+------------------------------------------------------------------+
ENUM_CALENDAR_EVENT_IMPORTANCE GetOverriddenImportance(string eventName, ENUM_CALENDAR_EVENT_IMPORTANCE currentImp)
  {
   string nameUpper = eventName;
   StringToUpper(nameUpper);
   
   if(StringFind(nameUpper, "CB CONSUMER CONFIDENCE") >= 0)
      return CALENDAR_IMPORTANCE_MODERATE; // Orange Folder (Medium)
      
   if(StringFind(nameUpper, "RICHMOND MANUFACTURING") >= 0)
      return CALENDAR_IMPORTANCE_LOW; // Yellow Folder (Low)
      
   if(StringFind(nameUpper, "CRUDE OIL STOCKS CHANGE") >= 0 || StringFind(nameUpper, "CRUDE OIL INVENTORIES") >= 0 || StringFind(nameUpper, "CRUDE OIL STOCKS") >= 0)
      return CALENDAR_IMPORTANCE_LOW; // Yellow Folder (Low)
      
   return currentImp;
  }

//+------------------------------------------------------------------+
//| Filter and rename economic events to match Forex Factory standard|
//+------------------------------------------------------------------+
bool ProcessEventForForexFactory(NewsEventInfo &info)
  {
   string nameUpper = info.name;
   StringToUpper(nameUpper);
   
   // 1. Filter out events that are typically not traded on Forex Factory
   if(StringFind(nameUpper, "AUCTION") >= 0) return false;
   if(StringFind(nameUpper, "T-BILL") >= 0) return false;
   if(StringFind(nameUpper, "BILL AUCTION") >= 0) return false;
   if(StringFind(nameUpper, "API WEEKLY") >= 0) return false;
   if(StringFind(nameUpper, "BALANCE SHEET") >= 0) return false;
   
   // 2. Identify and filter the only two EIA events that appear on Forex Factory
   bool isEIAEvent = (StringFind(nameUpper, "EIA ") >= 0);
   bool isCrudeOilStocks = (StringFind(nameUpper, "CRUDE OIL STOCKS CHANGE") >= 0 || StringFind(nameUpper, "CRUDE OIL INVENTORIES") >= 0 || StringFind(nameUpper, "CRUDE OIL STOCKS") >= 0);
   bool isNaturalGas = (StringFind(nameUpper, "NATURAL GAS STORAGE CHANGE") >= 0 || StringFind(nameUpper, "NATURAL GAS STORAGE") >= 0);
   
   if(isEIAEvent)
     {
      // If it starts with EIA but is neither Crude Oil Stocks nor Natural Gas, filter it out!
      if(!isCrudeOilStocks && !isNaturalGas)
         return false;
     }
   
   // 3. Rename events to match Forex Factory standard names
   if(StringFind(nameUpper, "CB CONSUMER CONFIDENCE") >= 0)
      info.name = "CB Consumer Confidence";
   else if(StringFind(nameUpper, "RICHMOND FED MANUFACTURING") >= 0 || StringFind(nameUpper, "RICHMOND MANUFACTURING") >= 0)
      info.name = "Richmond Manufacturing Index";
   else if(isCrudeOilStocks)
      info.name = "Crude Oil Inventories";
   else if(isNaturalGas)
      info.name = "Natural Gas Storage";
      
   return true;
  }

//+------------------------------------------------------------------+
//| Sort news events array by time ascending, then by importance desc|
//+------------------------------------------------------------------+
void SortNewsEvents(NewsEventInfo &arr[])
  {
   int n = ArraySize(arr);
   for(int i = 0; i < n - 1; i++)
     {
      for(int j = i + 1; j < n; j++)
        {
         bool swap = false;
         if(arr[j].eventTime < arr[i].eventTime)
           {
            swap = true;
           }
         else if(arr[j].eventTime == arr[i].eventTime)
           {
            if(arr[j].importance > arr[i].importance)
              {
               swap = true;
              }
           }
         if(swap)
           {
            NewsEventInfo temp = arr[i];
            arr[i] = arr[j];
            arr[j] = temp;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Get the next or currently active news events (any importance)    |
//+------------------------------------------------------------------+
int GetNextNewsEvents(NewsEventInfo &events[], int maxEvents)
  {
   ArrayResize(events, 0);
   if(!UseNewsFilter) return 0;
   
   datetime timeCurrent = TimeCurrent();
   
   // Query starting from start of today to force MT5 to sync today's released actual values
   MqlDateTime dtCurrent;
   TimeToStruct(timeCurrent, dtCurrent);
   dtCurrent.hour = 0;
   dtCurrent.min = 0;
   dtCurrent.sec = 0;
   datetime fromTime = StructToTime(dtCurrent);
   
   // Search for events up to 24 hours in the future
   datetime toTime = timeCurrent + 24 * 3600;
   
   MqlCalendarValue values[];
   string baseCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string quoteCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   
   // Query globally to trigger full background sync in terminal cache
   int countAll = CalendarValueHistory(values, fromTime, toTime);
   
   // Display window starts from NewsMinsAfter minutes ago
   datetime displayFromTime = timeCurrent - NewsMinsAfter * 60;
   NewsEventInfo allEvents[];
   
   for(int i = 0; i < countAll; i++)
     {
      if(values[i].time >= displayFromTime)
        {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event))
           {
            MqlCalendarCountry country;
            if(CalendarCountryById(event.country_id, country))
              {
               if(country.currency == baseCur || country.currency == quoteCur)
                 {
                  if(event.importance >= CALENDAR_IMPORTANCE_LOW)
                    {
                     NewsEventInfo info;
                     info.eventTime = values[i].time;
                     info.currency = country.currency;
                     info.name = event.name;
                     info.importance = GetOverriddenImportance(event.name, event.importance);
                     info.actualValue = values[i].actual_value;
                     info.forecastValue = values[i].forecast_value;
                     info.prevValue = values[i].prev_value;
                     info.impact = values[i].impact_type;
                     
                     datetime blockStart = values[i].time - NewsMinsBefore * 60;
                     datetime blockEnd = values[i].time + NewsMinsAfter * 60;
                     if(timeCurrent >= blockStart && timeCurrent <= blockEnd)
                        info.status = "Active";
                     else
                        info.status = "Upcoming";
                        
                     if(ProcessEventForForexFactory(info))
                       {
                        int size = ArraySize(allEvents);
                        ArrayResize(allEvents, size + 1);
                        allEvents[size] = info;
                       }
                    }
                 }
              }
           }
        }
     }
     
   int count = ArraySize(allEvents);
   if(count == 0) return 0;
   
   // Sort events by time and importance
   SortNewsEvents(allEvents);
   
   // Deduplicate (prioritize keeping the one that has the actual value released)
   NewsEventInfo uniqueEvents[];
   for(int i = 0; i < count; i++)
     {
      bool isDuplicate = false;
      int uCount = ArraySize(uniqueEvents);
      for(int j = 0; j < uCount; j++)
        {
         if(uniqueEvents[j].eventTime == allEvents[i].eventTime && 
            uniqueEvents[j].name == allEvents[i].name && 
            uniqueEvents[j].currency == allEvents[i].currency)
           {
            isDuplicate = true;
            // If existing duplicate has no actual value, but this one does, update it
            if(uniqueEvents[j].actualValue == LONG_MIN && allEvents[i].actualValue != LONG_MIN)
              {
               uniqueEvents[j] = allEvents[i];
              }
            break;
           }
        }
      if(!isDuplicate)
        {
         int idx = ArraySize(uniqueEvents);
         ArrayResize(uniqueEvents, idx + 1);
         uniqueEvents[idx] = allEvents[i];
        }
     }
     
   int uniqueCount = ArraySize(uniqueEvents);
   int finalCount = MathMin(maxEvents, uniqueCount);
   
   ArrayResize(events, finalCount);
   for(int i = 0; i < finalCount; i++)
     {
      events[i] = uniqueEvents[i];
     }
     
   return finalCount;
  }

//+------------------------------------------------------------------+
//| Economic Calendar News Filter Check                              |
//+------------------------------------------------------------------+
bool IsNewsTime()
  {
   if(!UseNewsFilter) return false;
   
   datetime timeCurrent = TimeCurrent();
   datetime fromTime = timeCurrent - NewsMinsBefore * 60;
   datetime toTime = timeCurrent + NewsMinsAfter * 60;
   
   MqlCalendarValue values[];
   
   // Check Base Currency
   string baseCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   int countBase = CalendarValueHistory(values, fromTime, toTime, NULL, baseCur);
   if(countBase > 0)
     {
      for(int i = 0; i < countBase; i++)
        {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event))
           {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
           }
        }
     }
     
   // Check Profit/Quote Currency
   string quoteCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   int countQuote = CalendarValueHistory(values, fromTime, toTime, NULL, quoteCur);
   if(countQuote > 0)
     {
      for(int i = 0; i < countQuote; i++)
        {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event))
           {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
           }
        }
     }
     
   return false;
  }

//+------------------------------------------------------------------+
//| Journal Log Writer (Saves logs to CSV file)                       |
//+------------------------------------------------------------------+
void WriteJournal(string action, ulong ticket, string setupName, string grade, double entry, double sl, double tp, double profit = 0.0)
  {
   if(!EnableJournal) return;
   
   string fileName = "AK10X_Journal_" + _Symbol + ".csv";
   int fileHandle = FileOpen(fileName, FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI, ',');
   
   bool isNew = (fileHandle != INVALID_HANDLE && FileSize(fileHandle) == 0);
   if(fileHandle == INVALID_HANDLE)
     {
      fileHandle = FileOpen(fileName, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      isNew = true;
     }
     
   if(fileHandle != INVALID_HANDLE)
     {
      FileSeek(fileHandle, 0, SEEK_END);
      
      if(isNew)
        {
         FileWrite(fileHandle, "Time", "Symbol", "Action", "Ticket", "Setup", "Grade", "Entry", "SL", "TP", "Profit_Loss");
        }
        
      string timeStr = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES|TIME_SECONDS);
      FileWrite(fileHandle, timeStr, _Symbol, action, (string)ticket, setupName, grade, 
                DoubleToString(entry, _Digits), DoubleToString(sl, _Digits), DoubleToString(tp, _Digits), 
                DoubleToString(profit, 2));
      FileClose(fileHandle);
     }
  }

//+------------------------------------------------------------------+
//| Scan and Log closed trades from Deal History                     |
//+------------------------------------------------------------------+
void ScanClosedPositions()
  {
   if(!EnableJournal) return;
   
   datetime from = TimeCurrent() - 24 * 60 * 60;
   HistorySelect(from, TimeCurrent());
   
   int totalDeals = HistoryDealsTotal();
   static ulong lastLoggedDeal = 0;
   
   for(int i = 0; i < totalDeals; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket <= lastLoggedDeal) continue;
      
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == MagicNumber)
        {
         long entryType = HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entryType == DEAL_ENTRY_OUT) // Close Deal
           {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
            ulong posId = HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
            string comment = HistoryDealGetString(ticket, DEAL_COMMENT);
            double price = HistoryDealGetDouble(ticket, DEAL_PRICE);
            
            WriteJournal("CLOSE", posId, comment, "", price, 0, 0, profit);
            lastLoggedDeal = ticket;
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Clean Trend string for UI display                                |
//+------------------------------------------------------------------+
string CleanTrendString(ENUM_TREND trend)
  {
   if(trend == TREND_UP) return "UP TREND";
   if(trend == TREND_DOWN) return "DOWN TREND";
   if(trend == TREND_SIDEWAYS) return "SIDEWAYS";
   if(trend == TREND_TRAPPING) return "TRAPPING TREND";
   return "UNKNOWN";
  }

//+------------------------------------------------------------------+
//| Get Trend color for UI display                                   |
//+------------------------------------------------------------------+
color GetTrendColor(ENUM_TREND trend)
  {
   if(trend == TREND_UP) return clrMediumSpringGreen;
   if(trend == TREND_DOWN) return clrTomato;
   if(trend == TREND_SIDEWAYS) return clrYellow;
   return clrOrange; // TREND_TRAPPING
  }

//+------------------------------------------------------------------+
//| UI visual dashboard implementation (HUD matching attachment)    |
//+------------------------------------------------------------------+

//--- Anti-flicker HUD rendering variables and helpers
string g_drawnHUDObjects[];
int g_drawnHUDCount = 0;

void ClearDrawnHUDList()
  {
   g_drawnHUDCount = 0;
   ArrayResize(g_drawnHUDObjects, 0);
  }

void RegisterDrawnHUD(string name)
  {
   ArrayResize(g_drawnHUDObjects, g_drawnHUDCount + 1);
   g_drawnHUDObjects[g_drawnHUDCount] = name;
   g_drawnHUDCount++;
  }

void DeleteUnusedHUDObjects()
  {
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, "AK10X_HUD_") == 0) // starts with AK10X_HUD_
        {
         bool found = false;
         for(int j = 0; j < g_drawnHUDCount; j++)
           {
            if(g_drawnHUDObjects[j] == name)
              {
               found = true;
               break;
              }
           }
         if(!found)
           {
            ObjectDelete(0, name);
           }
        }
     }
  }

void UpdateHUD()
  {
   // Clear previous list of drawn objects
   ClearDrawnHUDList();
   
   int xStart = 20;
   int yStart = 40;
   int ySpacing = 16;
   int width = 310;
   
   if(HUD_Minimized)
     {
      int minHeight = 36;
      CreateHUDPanel("AK10X_HUD_Bg", xStart - 10, yStart - 10, width, minHeight, ColorHUD_Bg, 1);
      CreateHUDText("AK10X_HUD_Title", "AK10X Pro", xStart, yStart, 10, true, clrTurquoise);
      CreateHUDButton("AK10X_HUD_Btn_MinMax", "[+]", xStart + width - 35, yStart - 2, 20, 16, C'30,30,30', clrTurquoise);
      
      DeleteUnusedHUDObjects();
      ChartRedraw(0);
      return;
     }

   int linesCount = 48;
   int btnHeight = 22;
   int height = (yStart + linesCount * ySpacing + btnHeight + 12) - (yStart - 10);
   
   // Dashboard Box Panel
   CreateHUDPanel("AK10X_HUD_Bg", xStart - 10, yStart - 10, width, height, ColorHUD_Bg, 1);
   
   int line = 0;
   
   // Title
   CreateHUDText("AK10X_HUD_Title", "AK10X Pro", xStart, yStart + (line++ * ySpacing), 10, true, clrTurquoise);
   CreateHUDButton("AK10X_HUD_Btn_MinMax", "[-]", xStart + width - 35, yStart - 2, 20, 16, C'30,30,30', clrTurquoise);
   
   line++; // spacer
   
   // --- Section 1: HIGHER TIME FRAME ---
   string htfStr = EnumToString(HigherPeriod);
   CreateHUDText("AK10X_HUD_HtfHeader", "HIGHER TIME FRAME (" + htfStr + ")", xStart, yStart + (line++ * ySpacing), 8, true, clrSilver);
   
   SwingPoint htf_Highs[], htf_Lows[];
   GetHistoricalSwings(HigherPeriod, HTF_SwingLeft, HTF_SwingRight, htf_Highs, htf_Lows, 5);
   ENUM_TREND htfTrendState = CalculateTrendFromSwings(htf_Highs, htf_Lows);
   
   string trendStr = "  TREND: " + CleanTrendString(htfTrendState);
   color trendColor = GetTrendColor(htfTrendState);
   CreateHUDText("AK10X_HUD_HtfTrend", trendStr, xStart, yStart + (line++ * ySpacing), 8, true, trendColor);
   
   double bid = GetLatestBid();
   
   string htfVrzHighStr = "  VRZ High: N/A";
   if(vrzHigh_15m > 0)
     {
      double diff = (vrzHigh_15m - bid) / GetPipDivisor();
      string sign = (diff >= 0) ? "+" : "";
      htfVrzHighStr = "  VRZ High: " + DoubleToString(vrzHigh_15m, _Digits) + " (" + sign + DoubleToString(diff, 1) + ")";
     }
   CreateHUDText("AK10X_HUD_HtfVrzHigh", htfVrzHighStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
   
   string htfVrzLowStr = "  VRZ Low: N/A";
   if(vrzLow_15m > 0)
     {
      double diff = (vrzLow_15m - bid) / GetPipDivisor();
      string sign = (diff >= 0) ? "+" : "";
      htfVrzLowStr = "  VRZ Low: " + DoubleToString(vrzLow_15m, _Digits) + " (" + sign + DoubleToString(diff, 1) + ")";
     }
   CreateHUDText("AK10X_HUD_HtfVrzLow", htfVrzLowStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
   line++; // spacer
   
   // --- Section 2: TRADING TIME FRAME ---
   string ltfStr = EnumToString(TradingPeriod);
   CreateHUDText("AK10X_HUD_LtfHeader", "TRADING TIME FRAME (" + ltfStr + ")", xStart, yStart + (line++ * ySpacing), 8, true, clrSilver);
   
   string ltfTrendStr = "  TREND: " + CleanTrendString(ttf_Trend);
   color ltfTrendColor = GetTrendColor(ttf_Trend);
   CreateHUDText("AK10X_HUD_LtfTrend", ltfTrendStr, xStart, yStart + (line++ * ySpacing), 8, true, ltfTrendColor);
   
   string ltfSwingHighStr = "  Swing High: N/A";
   if(minor_SwingHighPrice > 0)
     {
      double diff = (minor_SwingHighPrice - bid) / GetPipDivisor();
      string sign = (diff >= 0) ? "+" : "";
      ltfSwingHighStr = "  Swing High: " + DoubleToString(minor_SwingHighPrice, _Digits) + " (" + sign + DoubleToString(diff, 1) + ")";
     }
   CreateHUDText("AK10X_HUD_LtfSwingHigh", ltfSwingHighStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
   
   string ltfSwingLowStr = "  Swing Low: N/A";
   if(minor_SwingLowPrice > 0)
     {
      double diff = (minor_SwingLowPrice - bid) / GetPipDivisor();
      string sign = (diff >= 0) ? "+" : "";
      ltfSwingLowStr = "  Swing Low: " + DoubleToString(minor_SwingLowPrice, _Digits) + " (" + sign + DoubleToString(diff, 1) + ")";
     }
   CreateHUDText("AK10X_HUD_LtfSwingLow", ltfSwingLowStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
   line++; // spacer
   
   // --- Section 3: LOGICAL THINKER SYSTEM (MENTOR) ---
   CreateHUDText("AK10X_HUD_MentorHeader", "LOGICAL THINKER SYSTEM (MENTOR)", xStart, yStart + (line++ * ySpacing), 8, true, clrSilver);
   
   string boStr = "N/A";
   color boColor = clrGray;
   if(currentBreakout.isValid)
     {
      string pStr = DoubleToString(currentBreakout.levelPrice, _Digits);
      if(currentBreakout.levelType == "VRZ High")
        {
         boStr = "VRZ High (" + pStr + ")";
         boColor = clrMediumSpringGreen;
        }
      else
        {
         boStr = "VRZ Low (" + pStr + ")";
         boColor = clrTomato;
        }
     }
   CreateHUDText("AK10X_HUD_BOVal", "  Breakout: " + boStr, xStart, yStart + (line++ * ySpacing), 8, true, boColor);
   
   bool hasActive = currentBreakout.isValid;
   string r1_text = (hasActive) ? "  ✔ Rule 1 - Context" : "  [ ] Rule 1 - Context";
   color r1_color = (hasActive) ? clrMediumSpringGreen : clrGray;
   CreateHUDText("AK10X_HUD_R1", r1_text, xStart, yStart + (line++ * ySpacing), 8, false, r1_color);
   
   string r2_text = "  [ ] Rule 2 - Reaction";
   color r2_color = clrGray;
   if(hasActive)
     {
      if(currentBreakout.reaction == "Continuation" || currentBreakout.reaction == "Immediate Reversal")
        {
         r2_text = "  ✔ Rule 2 - Reaction";
         r2_color = clrMediumSpringGreen;
        }
      else if(currentBreakout.reaction == "Direct Breakout")
        {
         r2_text = "  ✘ Rule 2 - Reaction (Direct)";
         r2_color = clrTomato;
        }
     }
   CreateHUDText("AK10X_HUD_R2", r2_text, xStart, yStart + (line++ * ySpacing), 8, false, r2_color);
   
   string r3_text = "  [ ] Rule 3 - Validation";
   color r3_color = clrGray;
   if(hasActive)
     {
      if(currentBreakout.status == "Pending Order" || currentBreakout.status == "Running Order")
        {
         r3_text = "  ✔ Rule 3 - Validation";
         r3_color = clrMediumSpringGreen;
        }
      else if(currentBreakout.status == "Failed Validation")
        {
         r3_text = "  ✘ Rule 3 - Validation";
         r3_color = clrTomato;
        }
     }
   CreateHUDText("AK10X_HUD_R3", r3_text, xStart, yStart + (line++ * ySpacing), 8, false, r3_color);
   
   string setupName = "N/A";
   string grade = "N/A";
   string rrStr = "N/A";
   
   bool isTradePassed = (hasActive && (currentBreakout.status == "Pending Order" || currentBreakout.status == "Running Order"));
   
   if(isTradePassed && currentBreakout.setup != SETUP_NONE)
     {
      setupName = EnumToString(currentBreakout.setup);
      StringReplace(setupName, "SETUP_", "");
      
      if(currentBreakout.setup == SETUP_BOL || currentBreakout.setup == SETUP_BOFL)
        {
         ENUM_TREND htf = GetHTFTrend();
         ENUM_TREND ttf = ttf_Trend;
         if(htf == TREND_UP && ttf == TREND_UP) { grade = "A+++"; }
         else { grade = "A++"; }
        }
      else
        {
         ENUM_TREND htf = GetHTFTrend();
         ENUM_TREND ttf = ttf_Trend;
         if(htf == TREND_DOWN && ttf == TREND_DOWN) { grade = "A+++"; }
         else { grade = "A++"; }
        }
        
      double entry = currentBreakout.levelPrice;
      double sl = currentBreakout.sl;
      double tp = currentBreakout.tp;
      double risk = MathAbs(entry - sl);
      double reward = MathAbs(tp - entry);
      if(risk > 0)
        {
         rrStr = "1 : " + DoubleToString(reward / risk, 1);
        }
     }
     
   line++; // spacer
   CreateHUDText("AK10X_HUD_SetupVal", "  Setup           : " + setupName, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text, "Consolas");
   CreateHUDText("AK10X_HUD_GradeVal", "  Grade           : " + grade, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text, "Consolas");
   CreateHUDText("AK10X_HUD_RRVal",    "  Risk Reward     : " + rrStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text, "Consolas");
   
   string statusStr = "N/A";
   string lotStr = "N/A";
   string entryPriceStr = "N/A";
   string slPriceStr = "N/A";
   string tpPriceStr = "N/A";
   string rfStr = "N/A";
   
   if(hasActive)
     {
      statusStr = currentBreakout.status;
      if(statusStr == "") statusStr = "N/A";
      
      if(isTradePassed)
        {
         lotStr = DoubleToString(currentBreakout.currentLot, 2);
         entryPriceStr = DoubleToString(currentBreakout.levelPrice, _Digits);
         slPriceStr = DoubleToString(currentBreakout.sl, _Digits);
         tpPriceStr = DoubleToString(currentBreakout.tp, _Digits);
         
         if(statusStr == "Running Order")
           {
            rfStr = currentBreakout.riskFreeDone ? "Done" : "Waiting";
           }
         else if(statusStr == "Pending Order")
           {
            rfStr = "Waiting";
           }
        }
     }
   CreateHUDText("AK10X_HUD_StatVal",  "  Status          : " + statusStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text, "Consolas");
   CreateHUDText("AK10X_HUD_EntryVal", "  Entry Price     : " + entryPriceStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text, "Consolas");
   CreateHUDText("AK10X_HUD_SLVal",    "  Stop Loss       : " + slPriceStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text, "Consolas");
   CreateHUDText("AK10X_HUD_TPVal",    "  Take Profit     : " + tpPriceStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text, "Consolas");
   
   color rfColor = ColorHUD_Text;
   if(rfStr == "Done") rfColor = clrMediumSpringGreen;
   else if(rfStr == "Waiting") rfColor = clrYellow;
   CreateHUDText("AK10X_HUD_RFVal",    "  Risk-Free       : " + rfStr, xStart, yStart + (line++ * ySpacing), 8, false, rfColor, "Consolas");
   line++; // spacer
   
   // --- Section 4: NEWS FILTER STATUS ---
   CreateHUDText("AK10X_HUD_NewsHeader", "NEWS FILTER STATUS", xStart, yStart + (line++ * ySpacing), 8, true, clrSilver);
   
   NewsEventInfo newsInfoList[];
   int eventsCount = GetNextNewsEvents(newsInfoList, 2); // Get up to 2 news events
   
   if(eventsCount > 0)
     {
      for(int idx = 0; idx < eventsCount; idx++)
        {
         NewsEventInfo newsInfo = newsInfoList[idx];
         string idxStr = (string)(idx + 1);
         
         // Divider if showing second news event
         if(idx > 0)
           {
            CreateHUDText("AK10X_HUD_NewsSep_" + idxStr, "  ------------------------------", xStart, yStart + (line++ * ySpacing), 8, false, clrDimGray);
           }
           
         // 1. Mapped Folder Color / Importance
         color folderColor = clrGray;
         string folderName = GetImportanceName(newsInfo.importance, folderColor);
         string folderStr = "  Folder: " + folderName;
         CreateHUDText("AK10X_HUD_NewsFolder_" + idxStr, folderStr, xStart, yStart + (line++ * ySpacing), 8, true, folderColor);
         
         // 2. Wrap event name if it's too long for the panel
         string nameDisplay = newsInfo.name;
         if(StringLen(nameDisplay) > 34)
           {
            int splitIdx = 34;
            for(int i = 34; i > 15; i--)
              {
               if(StringGetCharacter(nameDisplay, i) == ' ')
                 {
                  splitIdx = i;
                  break;
                 }
              }
            string line1 = StringSubstr(nameDisplay, 0, splitIdx);
            string line2 = "       " + StringSubstr(nameDisplay, splitIdx + 1);
            CreateHUDText("AK10X_HUD_NewsEvent1_" + idxStr, "  " + newsInfo.currency + ": " + line1, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
            CreateHUDText("AK10X_HUD_NewsEvent2_" + idxStr, line2, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
           }
         else
           {
            CreateHUDText("AK10X_HUD_NewsEvent_" + idxStr, "  " + newsInfo.currency + ": " + nameDisplay, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
           }
         
         // 3. Mapped time to 12-hour format with AM/PM
         // Check if this particular event is high importance AND currently active to mark as blocked
         bool isEventBlocked = (newsInfo.importance == CALENDAR_IMPORTANCE_HIGH && newsInfo.status == "Active");
         string timeStr = FormatTimeIST(newsInfo.eventTime);
         string timeLine = "  Time: " + timeStr + " (" + FormatTimeDifference(newsInfo.eventTime) + ")";
         color timeColor = isEventBlocked ? clrTomato : clrMediumSpringGreen;
         CreateHUDText("AK10X_HUD_NewsTime_" + idxStr, timeLine, xStart, yStart + (line++ * ySpacing), 8, true, timeColor);
         
         // 4. Show release details if event time has passed
         if(TimeCurrent() >= newsInfo.eventTime)
           {
            string impactLine = "  Impact: Pending Release";
            color impactColor = clrYellow;
            
            if(newsInfo.actualValue != LONG_MIN)
              {
               if(newsInfo.impact == CALENDAR_IMPACT_POSITIVE)
                 {
                  impactLine = "  Impact: Positive (";
                  string baseCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
                  string quoteCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
                  if(newsInfo.currency == baseCur)
                     impactLine += newsInfo.currency + " UP / " + _Symbol + " UP)";
                  else if(newsInfo.currency == quoteCur)
                     impactLine += newsInfo.currency + " UP / " + _Symbol + " DOWN)";
                  else
                     impactLine += newsInfo.currency + " UP)";
                  impactColor = clrMediumSpringGreen;
                 }
               else if(newsInfo.impact == CALENDAR_IMPACT_NEGATIVE)
                 {
                  impactLine = "  Impact: Negative (";
                  string baseCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
                  string quoteCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
                  if(newsInfo.currency == baseCur)
                     impactLine += newsInfo.currency + " DOWN / " + _Symbol + " DOWN)";
                  else if(newsInfo.currency == quoteCur)
                     impactLine += newsInfo.currency + " DOWN / " + _Symbol + " UP)";
                  else
                     impactLine += newsInfo.currency + " DOWN)";
                  impactColor = clrTomato;
                 }
               else
                 {
                  impactLine = "  Impact: Neutral / NA";
                  impactColor = clrSilver;
                 }
              }
            CreateHUDText("AK10X_HUD_NewsImpact_" + idxStr, impactLine, xStart, yStart + (line++ * ySpacing), 8, true, impactColor);
           }
        }
     }
   else
     {
      CreateHUDText("AK10X_HUD_NewsEvent", "  No upcoming news (24h)", xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
      CreateHUDText("AK10X_HUD_NewsTime", "  Status: Clear", xStart, yStart + (line++ * ySpacing), 8, true, clrMediumSpringGreen);
     }
     
   line++; // spacer
   
   // Spread
   int spreadPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spreadPips = spreadPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT) / GetPipDivisor();
   string spreadStr = StringFormat("  Spread: %.1f pips (%d pts)", spreadPips, spreadPoints);
   CreateHUDText("AK10X_HUD_Spread", spreadStr, xStart, yStart + (line++ * ySpacing), 8, true, clrLightSkyBlue);
   
   line++; // spacer before button
   
   // Single Toggle button at the bottom
   int btnY = yStart + (line++ * ySpacing);
   int btnWidth = width - 20;
   
   string autoText = AutoTradingEnabled ? "Algo Online" : "Algo Offline";
   color autoBg = AutoTradingEnabled ? C'0,150,0' : C'180,0,0'; // Green for running, Red for stopped
   
   CreateHUDButton("AK10X_HUD_Btn_Auto", autoText, xStart, btnY, btnWidth, btnHeight, autoBg, clrWhite);
   
   // Update panel height dynamically based on the final elements drawn
   int finalHeight = (btnY + btnHeight + 12) - (yStart - 10);
   ObjectSetInteger(0, "AK10X_HUD_Bg", OBJPROP_YSIZE, finalHeight);
   
   DeleteUnusedHUDObjects();
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Create UI Text helper                                            |
//+------------------------------------------------------------------+
void CreateHUDText(string name, string text, int x, int y, int size, bool bold, color textClr, string fontName = "")
  {
   RegisterDrawnHUD(name);
   string actualFont = fontName;
   if(actualFont == "")
      actualFont = bold ? "Trebuchet MS" : "Arial";
      
   if(ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
     {
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetString(0, name, OBJPROP_FONT, actualFont);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
      ObjectSetInteger(0, name, OBJPROP_COLOR, textClr);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 101);
     }
   else
     {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_COLOR, textClr);
      ObjectSetString(0, name, OBJPROP_FONT, actualFont);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 101);
     }
  }

//+------------------------------------------------------------------+
//| Create UI Panel helper                                           |
//+------------------------------------------------------------------+
void CreateHUDPanel(string name, int x, int y, int w, int h, color bgClr, int border)
  {
   RegisterDrawnHUD(name);
   if(ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0))
     {
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgClr);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrDarkGray);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, border);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgClr);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
     }
  }

//+------------------------------------------------------------------+
//| Create Interactive Button helper                                 |
//+------------------------------------------------------------------+
void CreateHUDButton(string name, string text, int x, int y, int w, int h, color bgClr, color textClr)
  {
   RegisterDrawnHUD(name);
   if(ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0))
     {
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetString(0, name, OBJPROP_FONT, "Trebuchet MS");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, name, OBJPROP_COLOR, textClr);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgClr);
      ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrDarkGray);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 101);
     }
   else
     {
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, textClr);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgClr);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 101);
     }
  }

//+------------------------------------------------------------------+
//| Update current price countdown label near price scale            |
//+------------------------------------------------------------------+
void UpdateCountdown()
  {
   string objName = "AK10X_Countdown";
   if(!ShowHUD)
     {
      ObjectDelete(0, objName);
      return;
     }
     
   datetime nextBarTime = iTime(_Symbol, _Period, 0) + PeriodSeconds(_Period);
   datetime timeCurrent = TimeTradeServer();
   int remainingSeconds = (int)(nextBarTime - timeCurrent);
   if(remainingSeconds < 0) remainingSeconds = 0;
   
   int minutes = remainingSeconds / 60;
   int seconds = remainingSeconds % 60;
   string countdownStr = StringFormat("%02d:%02d", minutes, seconds);
   
   double bid = GetLatestBid();
   int x_pixel = 0;
   int y_pixel = 0;
   
   datetime barTime = iTime(_Symbol, _Period, 0);
   if(barTime == 0) barTime = timeCurrent;
   
   ResetLastError();
   bool ok = ChartTimePriceToXY(0, 0, barTime, bid, x_pixel, y_pixel);
   if(!ok)
     {
      ok = ChartTimePriceToXY(0, 0, timeCurrent, bid, x_pixel, y_pixel);
     }
     
   if(!ok)
     {
      PrintFormat("AK10X_Countdown Debug: ChartTimePriceToXY failed! Error: %d, barTime: %s, timeCurrent: %s, bid: %f", 
                  GetLastError(), TimeToString(barTime), TimeToString(timeCurrent), bid);
      return;
     }
     
   // Get Bid price color to match dynamically
   color bidColor = (color)ChartGetInteger(0, CHART_COLOR_BID);
   
   // Calculate dynamic price scale width based on symbol digits
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int priceScaleWidth = 65 + (digits * 3); // 65px base + 3px per digit
   
   int btnX = priceScaleWidth; // Flush against the left boundary of the price scale
   int btnY = y_pixel + 9; // Positioned exactly below the level of the native price tag
   
   // Print coordinates for debugging
   static datetime lastLogTime = 0;
   if(timeCurrent - lastLogTime >= 5)
     {
      PrintFormat("AK10X_Countdown Debug: x_pixel: %d, y_pixel: %d, btnX: %d, btnY: %d, bidColor: %d, priceScaleWidth: %d", 
                  x_pixel, y_pixel, btnX, btnY, bidColor, priceScaleWidth);
      lastLogTime = timeCurrent;
     }
   
   // If object exists but is not OBJ_EDIT, delete it
   if(ObjectFind(0, objName) >= 0)
     {
      if(ObjectGetInteger(0, objName, OBJPROP_TYPE) != OBJ_EDIT)
        {
         ObjectDelete(0, objName);
        }
     }
     
   if(ObjectFind(0, objName) < 0)
     {
      ResetLastError();
      if(!ObjectCreate(0, objName, OBJ_EDIT, 0, 0, 0))
        {
         PrintFormat("AK10X_Countdown Debug: ObjectCreate failed! Error: %d", GetLastError());
         return;
        }
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_YSIZE, 15); // Compact height for floating box
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, objName, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, objName, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_READONLY, true);
      ObjectSetInteger(0, objName, OBJPROP_ALIGN, ALIGN_CENTER);
      ObjectSetInteger(0, objName, OBJPROP_BACK, false);
      ObjectSetInteger(0, objName, OBJPROP_ZORDER, 10);
     }
   
   // Update properties dynamically
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, 45); // Compact width for 00:00 text
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, btnX);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, btnY);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, bidColor);
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, bidColor);
   ObjectSetString(0, objName, OBJPROP_TEXT, countdownStr);
  }

//+------------------------------------------------------------------+
//| Track breakouts in real-time on every tick                        |
//+------------------------------------------------------------------+


