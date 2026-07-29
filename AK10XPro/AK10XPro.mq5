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
input double          BaseLotSize       = 1.0;              // Lot size per position (Total = 2 * BaseLotSize)
input double          RiskPercent       = 0.0;              // Dynamic risk % (if > 0, overrides BaseLotSize)
input double          MinRiskReward     = 3.0;              // Minimum Risk to Reward Ratio
input int             StopLossBuffer    = 2;                // SL buffer in pips (outside breakout candle)
input int             Slippage          = 3;                // Allowed slippage in points
input ulong           MagicNumber       = 101010;           // Expert Advisor Magic Number

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
datetime       lastBarTime          = 0;
string         hudObjects[];

void UpdateCountdown();

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
   // Manage existing active positions and check for break-even trail on Lot 2
   ManageActivePositions();
   
   // Check if a new bar has opened on the Trading Timeframe
   datetime currentBarTime = iTime(_Symbol, TradingPeriod, 0);
   if(currentBarTime != lastBarTime)
     {
      lastBarTime = currentBarTime;
      ProcessTradingLogic();
     }
     
   if(ShowHUD) UpdateCountdown();
  }

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
  {
   // Update HUD elements and manage pending orders
   ManagePendingOrders();
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
     }
  }

//+------------------------------------------------------------------+
//| Core trading logic: Updates levels, trends, and processes setups |
//+------------------------------------------------------------------+
void ProcessTradingLogic()
  {
   // 1. Update Swing Points & VRZs
   UpdateVRZones();
   
   // 2. Update Trend States
   UpdateTrends();
   
   // 3. Draw Zigzag & Swing Labels
   DrawZigzagAndLabels();
   
   // 4. Process Setup Detection (Automatic limit orders)
   if(AutoTradingEnabled)
     {
      DetectSetupsAndExecute();
     }
   
   // 5. Update UI
   if(ShowHUD) UpdateHUD();
  }

//+------------------------------------------------------------------+
//| Pip Size Helper                                                  |
//+------------------------------------------------------------------+
double GetPipSize()
  {
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5) return point * 10.0;
   return point;
  }

//+------------------------------------------------------------------+
//| Get Pip/Point Divisor for HUD metrics                           |
//+------------------------------------------------------------------+
double GetPipDivisor()
  {
   string sym = _Symbol;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   
   if(StringFind(sym, "BTC") >= 0 || StringFind(sym, "ETH") >= 0 || (StringFind(sym, "USD") == -1 && digits <= 2))
     {
      return 1.0;
     }
   if(digits == 0) return 1.0;
   if(digits == 1) return pt;
   if(digits == 2) 
     {
      if(StringFind(sym, "BTC") >= 0 || StringFind(sym, "ETH") >= 0 || StringFind(sym, "XBT") >= 0)
         return 1.0;
      return pt * 10.0;
     }
   if(digits == 3 || digits == 5) return pt * 10.0;
   return pt;
  }

//+------------------------------------------------------------------+
//| Find the most recent Virgin High on a given timeframe            |
//+------------------------------------------------------------------+
double GetRecentVirginHigh(ENUM_TIMEFRAMES tf, int leftBars, int rightBars)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, tf, 1, 3000, rates);
   if(copied <= 0) return 0.0;
   
   for(int i = rightBars; i < copied - leftBars; i++)
     {
      double h = rates[i].high;
      bool isHigh = true;
      for(int l = 1; l <= leftBars; l++) {
         if(rates[i+l].high >= h) { isHigh = false; break; }
      }
      if(!isHigh) continue;
      for(int r = 1; r <= rightBars; r++) {
         if(rates[i-r].high >= h) { isHigh = false; break; }
      }
      if(!isHigh) continue;
      
      // Check if Virgin (no subsequent bar went higher)
      bool isVirgin = true;
      for(int j = i - 1; j >= 0; j--) {
         if(rates[j].high > h) { isVirgin = false; break; }
      }
      if(isVirgin) return h;
     }
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Find the most recent Virgin Low on a given timeframe             |
//+------------------------------------------------------------------+
double GetRecentVirginLow(ENUM_TIMEFRAMES tf, int leftBars, int rightBars)
  {
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, tf, 1, 3000, rates);
   if(copied <= 0) return 0.0;
   
   for(int i = rightBars; i < copied - leftBars; i++)
     {
      double l = rates[i].low;
      bool isLow = true;
      for(int l_bar = 1; l_bar <= leftBars; l_bar++) {
         if(rates[i+l_bar].low <= l) { isLow = false; break; }
      }
      if(!isLow) continue;
      for(int r = 1; r <= rightBars; r++) {
         if(rates[i-r].low <= l) { isLow = false; break; }
      }
      if(!isLow) continue;
      
      // Check if Virgin (no subsequent bar went lower)
      bool isVirgin = true;
      for(int j = i - 1; j >= 0; j--) {
         if(rates[j].low < l) { isVirgin = false; break; }
      }
      if(isVirgin) return l;
     }
   return 0.0;
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
   int copied = CopyRates(_Symbol, TradingPeriod, 0, 1000, rates);
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
     }
   else
     {
      ObjectSetInteger(0, labelObjName, OBJPROP_TIME, 0, labelTime);
      ObjectSetDouble(0, labelObjName, OBJPROP_PRICE, 0, labelPrice);
      ObjectSetString(0, labelObjName, OBJPROP_TEXT, labelText);
      ObjectSetInteger(0, labelObjName, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, labelObjName, OBJPROP_ANCHOR, anchorPoint);
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
     
   // Draw most recent 3 mitigated highs (filter duplicate labels near same price)
   int mHighsToDraw = MathMin(3, mHCount);
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
      
      color clr = clrRoyalBlue;
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
     
   // Draw most recent 3 mitigated lows (filter duplicate labels near same price)
   int mLowsToDraw = MathMin(3, mLCount);
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
      
      color clr = clrCrimson;
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
   // Major structure swings (e.g. 5, 5 parameters)
   SwingPoint major_Highs[], major_Lows[];
   GetHistoricalSwings(TradingPeriod, Major_SwingLeft, Major_SwingRight, major_Highs, major_Lows, 5);
   major_Trend = CalculateTrendFromSwings(major_Highs, major_Lows);
   
   if(ArraySize(major_Highs) > 0) major_SwingHighPrice = major_Highs[0].price;
   if(ArraySize(major_Lows) > 0)  major_SwingLowPrice  = major_Lows[0].price;
   
   // Minor/Internal structure swings (e.g. 2, 2 parameters)
   SwingPoint ttf_Highs[], ttf_Lows[];
   GetHistoricalSwings(TradingPeriod, Minor_SwingLength, Minor_SwingLength, ttf_Highs, ttf_Lows, 5);
   ttf_Trend = CalculateTrendFromSwings(ttf_Highs, ttf_Lows);
   
   if(ArraySize(ttf_Highs) > 0) minor_SwingHighPrice = ttf_Highs[0].price;
   if(ArraySize(ttf_Lows) > 0)  minor_SwingLowPrice  = ttf_Lows[0].price;
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
void DetectSetupsAndExecute()
  {
   // Skip if news filter is active
   if(IsNewsTime())
     {
      Print("AK10XPro: Trading suspended due to news filter.");
      return;
     }
     
   // We will execute on VRZ levels. Let's build candidates list.
   double levelHighs[] = {vrzHigh_15m, vrzHigh_1h};
   double levelLows[]  = {vrzLow_15m, vrzLow_1h};
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, TradingPeriod, 0, 5, rates) < 5) return;
   
   double buffer = StopLossBuffer * _Point;
   
   // Loop through lows for BOF-L & BOS
   for(int i = 0; i < ArraySize(levelLows); i++)
     {
      double vrzLow = levelLows[i];
      if(vrzLow <= 0.0) continue;
      
      //--- Setup 1: BOF-L (Breakout Failure Long) - Grade A+
      bool cond1 = (rates[1].low < vrzLow && rates[1].close > vrzLow);
      bool cond2 = (rates[2].close < vrzLow && rates[1].close > vrzLow);
      
      if(cond1 || cond2)
        {
         double breakoutLow = cond2 ? rates[2].low : rates[1].low;
         double entry = vrzLow;
         double sl = breakoutLow - buffer;
         double tp = GetNearestSwingHighAbove(entry);
         
         double risk = entry - sl;
         double reward = tp - entry;
         
         if(risk > 0 && (reward / risk) >= MinRiskReward)
           {
            if(!OrderExistsAtPrice(entry, ORDER_TYPE_BUY_LIMIT))
              {
               ExecuteOrderPair(ORDER_TYPE_BUY_LIMIT, entry, sl, tp, "BOF-L", GRADE_APLUS);
              }
           }
        }
        
      //--- Setup 4: BOS (Breakout Short) - Grade A++
      bool condBOS = (rates[1].close < vrzLow && rates[2].close >= vrzLow);
      if(condBOS && ttf_Trend == TREND_DOWN)
        {
         double breakoutHigh = rates[1].high;
         double entry = vrzLow;
         double sl = breakoutHigh + buffer;
         double tp = (vrzLow_1h > 0 && vrzLow_1h < entry) ? vrzLow_1h : GetNearestSwingLowBelow(entry);
         
         double risk = sl - entry;
         double reward = entry - tp;
         
         if(risk > 0 && (reward / risk) >= MinRiskReward)
           {
            if(!OrderExistsAtPrice(entry, ORDER_TYPE_SELL_LIMIT))
              {
               ExecuteOrderPair(ORDER_TYPE_SELL_LIMIT, entry, sl, tp, "BOS", GRADE_APLUSPLUS);
              }
           }
        }
     }
     
   // Loop through highs for BOF-S & BOL
   for(int i = 0; i < ArraySize(levelHighs); i++)
     {
      double vrzHigh = levelHighs[i];
      if(vrzHigh <= 0.0) continue;
      
      //--- Setup 2: BOF-S (Breakout Failure Short) - Grade A+
      bool cond1 = (rates[1].high > vrzHigh && rates[1].close < vrzHigh);
      bool cond2 = (rates[2].close > vrzHigh && rates[1].close < vrzHigh);
      
      if(cond1 || cond2)
        {
         double breakoutHigh = cond2 ? rates[2].high : rates[1].high;
         double entry = vrzHigh;
         double sl = breakoutHigh + buffer;
         double tp = GetNearestSwingLowBelow(entry);
         
         double risk = sl - entry;
         double reward = entry - tp;
         
         if(risk > 0 && (reward / risk) >= MinRiskReward)
           {
            if(!OrderExistsAtPrice(entry, ORDER_TYPE_SELL_LIMIT))
              {
               ExecuteOrderPair(ORDER_TYPE_SELL_LIMIT, entry, sl, tp, "BOF-S", GRADE_APLUS);
              }
           }
        }
        
      //--- Setup 3: BOL (Breakout Long) - Grade A++
      bool condBOL = (rates[1].close > vrzHigh && rates[2].close <= vrzHigh);
      if(condBOL && ttf_Trend == TREND_UP)
        {
         double breakoutLow = rates[1].low;
         double entry = vrzHigh;
         double sl = breakoutLow - buffer;
         double tp = (vrzHigh_1h > 0 && vrzHigh_1h > entry) ? vrzHigh_1h : GetNearestSwingHighAbove(entry);
         
         double risk = entry - sl;
         double reward = tp - entry;
         
         if(risk > 0 && (reward / risk) >= MinRiskReward)
           {
            if(!OrderExistsAtPrice(entry, ORDER_TYPE_BUY_LIMIT))
              {
               ExecuteOrderPair(ORDER_TYPE_BUY_LIMIT, entry, sl, tp, "BOL", GRADE_APLUSPLUS);
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Check if a pending order already exists near a specific price   |
//+------------------------------------------------------------------+
bool OrderExistsAtPrice(double price, ENUM_ORDER_TYPE orderType)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
        {
         if(OrderGetInteger(ORDER_TYPE) == orderType && MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - price) < 2 * _Point)
            return true;
        }
     }
   return false;
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

//+------------------------------------------------------------------+
//| Execute a dual order pair (Lot 1 and Lot 2)                      |
//+------------------------------------------------------------------+
void ExecuteOrderPair(ENUM_ORDER_TYPE orderType, double entry, double sl, double tp, string setupName, ENUM_GRADE grade)
  {
   double lot = CalculateLotSize(entry, sl);
   double risk = MathAbs(entry - sl);
   
   double tp_lot1 = (orderType == ORDER_TYPE_BUY_LIMIT) ? (entry + risk) : (entry - risk);
   
   string gradeStr = (grade == GRADE_APLUSPLUS) ? "A++" : "A+";
   
   string comment1 = "AK10X_L1_" + setupName + "_" + gradeStr;
   string comment2 = "AK10X_L2_" + setupName + "_" + gradeStr;
   
   bool res1 = false;
   bool res2 = false;
   
   if(orderType == ORDER_TYPE_BUY_LIMIT)
     {
      res1 = trade.BuyLimit(lot, entry, _Symbol, sl, tp_lot1, ORDER_TIME_GTC, 0, comment1);
      res2 = trade.BuyLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment2);
     }
   else
     {
      res1 = trade.SellLimit(lot, entry, _Symbol, sl, tp_lot1, ORDER_TIME_GTC, 0, comment1);
      res2 = trade.SellLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment2);
     }
     
   if(res1 && res2)
     {
      PrintFormat("AK10XPro: Placed %s dual orders (Grade %s) at %f, SL: %f, TP1: %f, TP2: %f", 
                  EnumToString(orderType), gradeStr, entry, sl, tp_lot1, tp);
      WriteJournal("PENDING", 0, setupName, gradeStr, entry, sl, tp);
     }
  }

//+------------------------------------------------------------------+
//| Execute Manual Market Order (triggered by HUD buttons)           |
//+------------------------------------------------------------------+
void ExecuteManualOrder(ENUM_ORDER_TYPE orderType)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   double entry = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   
   // Set SL/TP from the current minor swing structure
   double sl = (orderType == ORDER_TYPE_BUY) ? minor_SwingLowPrice : minor_SwingHighPrice;
   double tp = (orderType == ORDER_TYPE_BUY) ? minor_SwingHighPrice : minor_SwingLowPrice;
   
   if(sl <= 0.0 || tp <= 0.0)
     {
      Print("AK10XPro: Cannot execute manual trade. Swing structure levels are missing.");
      return;
     }
     
   double risk = MathAbs(entry - sl);
   if(risk <= 0.0) return;
   
   double lot = CalculateLotSize(entry, sl);
   double tp_lot1 = (orderType == ORDER_TYPE_BUY) ? (entry + risk) : (entry - risk);
   
   string comment1 = "AK10X_L1_Manual";
   string comment2 = "AK10X_L2_Manual";
   
   bool r1 = false, r2 = false;
   if(orderType == ORDER_TYPE_BUY)
     {
      r1 = trade.Buy(lot, _Symbol, ask, sl, tp_lot1, comment1);
      r2 = trade.Buy(lot, _Symbol, ask, sl, tp, comment2);
     }
   else
     {
      r1 = trade.Sell(lot, _Symbol, bid, sl, tp_lot1, comment1);
      r2 = trade.Sell(lot, _Symbol, bid, sl, tp, comment2);
     }
     
   if(r1 && r2)
     {
      PrintFormat("AK10XPro: Manual Market order executed: %s, Lots: %f, SL: %f, TP1: %f, TP2: %f",
                  EnumToString(orderType), lot, sl, tp_lot1, tp);
      WriteJournal("MANUAL", 0, EnumToString(orderType), "Manual", entry, sl, tp);
     }
  }

//+------------------------------------------------------------------+
//| Close all open positions from this EA                            |
//+------------------------------------------------------------------+
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
   Print("AK10XPro: Manual CLOSE ALL executed.");
  }

//+------------------------------------------------------------------+
//| Manage Active Positions (1R Break-Even modification)             |
//+------------------------------------------------------------------+
void ManageActivePositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
         string comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(comment, "AK10X_L2") == 0) // Lot 2 position
           {
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            double currentTP = PositionGetDouble(POSITION_TP);
            long posType = PositionGetInteger(POSITION_TYPE);
            
            bool isBuy = (posType == POSITION_TYPE_BUY);
            bool alreadyBE = false;
            
            if(isBuy && currentSL >= entryPrice - _Point) alreadyBE = true;
            if(!isBuy && currentSL <= entryPrice + _Point) alreadyBE = true;
            
            if(!alreadyBE)
              {
               // Check if corresponding Lot 1 is closed
               bool lot1Exists = false;
               for(int j = PositionsTotal() - 1; j >= 0; j--)
                 {
                  ulong t2 = PositionGetTicket(j);
                  if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
                    {
                     string comment2 = PositionGetString(POSITION_COMMENT);
                     if(StringFind(comment2, "AK10X_L1") == 0)
                       {
                        lot1Exists = true;
                        break;
                       }
                    }
                 }
                 
               if(!lot1Exists)
                 {
                  if(trade.PositionModify(ticket, entryPrice, currentTP))
                    {
                     PrintFormat("AK10XPro: Lot 1 closed. Moved Lot 2 position (Ticket: %d) to Break-Even at %f", ticket, entryPrice);
                     WriteJournal("BREAKEVEN", ticket, comment, "", entryPrice, entryPrice, currentTP);
                    }
                 }
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Manage Pending Orders (Cleanup of invalidated setups)            |
//+------------------------------------------------------------------+
void ManagePendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
        {
         double entry = OrderGetDouble(ORDER_PRICE_OPEN);
         double sl = OrderGetDouble(ORDER_SL);
         double tp = OrderGetDouble(ORDER_TP);
         long type = OrderGetInteger(ORDER_TYPE);
         string comment = OrderGetString(ORDER_COMMENT);
         
         MqlRates rates[];
         if(CopyRates(_Symbol, TradingPeriod, 0, 2, rates) < 2) continue;
         double lastClose = rates[1].close;
         
         bool cancel = false;
         string reason = "";
         
         // 1. Cancel if price closes past SL before getting filled
         if(type == ORDER_TYPE_BUY_LIMIT && lastClose < sl)
           {
            cancel = true;
            reason = "Price closed below SL";
           }
         else if(type == ORDER_TYPE_SELL_LIMIT && lastClose > sl)
           {
            cancel = true;
            reason = "Price closed above SL";
           }
           
         // 2. Cancel if price reaches TP before getting filled
         if(type == ORDER_TYPE_BUY_LIMIT && rates[0].high >= tp)
           {
            cancel = true;
            reason = "Target reached before fill";
           }
         else if(type == ORDER_TYPE_SELL_LIMIT && rates[0].low <= tp)
           {
            cancel = true;
            reason = "Target reached before fill";
           }
           
         if(cancel)
           {
            if(trade.OrderDelete(ticket))
              {
               PrintFormat("AK10XPro: Cancelled pending order (Ticket: %d, Setup: %s) because: %s", ticket, comment, reason);
               WriteJournal("CANCEL", ticket, comment, "", entry, sl, tp);
              }
           }
        }
     }
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
   string s = EnumToString(trend);
   StringReplace(s, "_", " ");
   return s;
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
void UpdateHUD()
  {
   // Delete previous HUD objects
   ObjectsDeleteAll(0, "AK10X_HUD_");
   
   int xStart = 20;
   int yStart = 40;
   int ySpacing = 16;
   int width = 290;
   
   int linesCount = 18;
   int btnHeight = 22;
   int height = (yStart + linesCount * ySpacing + btnHeight + 12) - (yStart - 10);
     
   // Dashboard Box Panel
   CreateHUDPanel("AK10X_HUD_Bg", xStart - 10, yStart - 10, width, height, ColorHUD_Bg, 1);
    
   int line = 0;
   string htfStr = EnumToString(HigherPeriod);
    
   // Title
   CreateHUDText("AK10X_HUD_Title", "AK10X PRO AUTO TRADER", xStart, yStart + (line++ * ySpacing), 10, true, clrTurquoise);
    
   line++; // spacer
   
   // Header
   CreateHUDText("AK10X_HUD_HtfHeader", "HIGHER TIME FRAME (" + htfStr + ")", xStart, yStart + (line++ * ySpacing), 8, true, clrSilver);
   
   // 1. HTF Trend state
   SwingPoint htf_Highs[], htf_Lows[];
   GetHistoricalSwings(HigherPeriod, HTF_SwingLeft, HTF_SwingRight, htf_Highs, htf_Lows, 5);
   ENUM_TREND htfTrendState = CalculateTrendFromSwings(htf_Highs, htf_Lows);
   
   string trendStr = "  Trend: " + CleanTrendString(htfTrendState);
   color trendColor = GetTrendColor(htfTrendState);
   CreateHUDText("AK10X_HUD_HtfTrend", trendStr, xStart, yStart + (line++ * ySpacing), 8, true, trendColor);
   
   // Running price
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // 2. VRZ High distance (VRZ High - Running Price)
   string vrzHighStr = "  VRZ High: N/A";
   if(vrzHigh_15m > 0)
     {
      double diff = (vrzHigh_15m - bid) / GetPipDivisor();
      int diffPts = (int)MathRound(diff);
      string sign = (diffPts >= 0) ? "+" : "";
      vrzHighStr = "  VRZ High: " + DoubleToString(vrzHigh_15m, _Digits) + " (" + sign + (string)diffPts + ")";
     }
   CreateHUDText("AK10X_HUD_HtfVrzHigh", vrzHighStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
   
   // 3. VRZ Low distance (VRZ Low - Running Price)
   string vrzLowStr = "  VRZ Low: N/A";
   if(vrzLow_15m > 0)
     {
      double diff = (vrzLow_15m - bid) / GetPipDivisor();
      int diffPts = (int)MathRound(diff);
      string sign = (diffPts >= 0) ? "+" : "";
      vrzLowStr = "  VRZ Low: " + DoubleToString(vrzLow_15m, _Digits) + " (" + sign + (string)diffPts + ")";
     }
   CreateHUDText("AK10X_HUD_HtfVrzLow", vrzLowStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
   
   line++; // spacer
   
   // Header for Lower Time Frame
   string ltfStr = EnumToString(TradingPeriod);
   CreateHUDText("AK10X_HUD_LtfHeader", "LOWER TIME FRAME (" + ltfStr + ")", xStart, yStart + (line++ * ySpacing), 8, true, clrSilver);
   
   // 1. LTF Trend state
   string ltfTrendStr = "  Trend: " + CleanTrendString(ttf_Trend);
   color ltfTrendColor = GetTrendColor(ttf_Trend);
   CreateHUDText("AK10X_HUD_LtfTrend", ltfTrendStr, xStart, yStart + (line++ * ySpacing), 8, true, ltfTrendColor);
   
   // 2. LTF Swing High
   string ltfSwingHighStr = "  Swing High: N/A";
   if(minor_SwingHighPrice > 0)
     {
      double diff = (minor_SwingHighPrice - bid) / GetPipDivisor();
      int diffPts = (int)MathRound(diff);
      string sign = (diffPts >= 0) ? "+" : "";
      ltfSwingHighStr = "  Swing High: " + DoubleToString(minor_SwingHighPrice, _Digits) + " (" + sign + (string)diffPts + ")";
     }
   CreateHUDText("AK10X_HUD_LtfSwingHigh", ltfSwingHighStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
   
   // 3. LTF Swing Low
   string ltfSwingLowStr = "  Swing Low: N/A";
   if(minor_SwingLowPrice > 0)
     {
      double diff = (minor_SwingLowPrice - bid) / GetPipDivisor();
      int diffPts = (int)MathRound(diff);
      string sign = (diffPts >= 0) ? "+" : "";
      ltfSwingLowStr = "  Swing Low: " + DoubleToString(minor_SwingLowPrice, _Digits) + " (" + sign + (string)diffPts + ")";
     }
   CreateHUDText("AK10X_HUD_LtfSwingLow", ltfSwingLowStr, xStart, yStart + (line++ * ySpacing), 8, false, ColorHUD_Text);
    
   line++; // spacer (some space after lower time frame)
   
   // Delete previous news labels to avoid ghosting
   ObjectsDeleteAll(0, "AK10X_HUD_News");
   
   // Header for News
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
            else
              {
               // Print debug info to experts journal at most once every 30 seconds
               static datetime lastPrint = 0;
               if(TimeCurrent() - lastPrint >= 30)
                 {
                  PrintFormat("AK10XPro Debug: Event '%s' (%s) time has passed by %d sec, but terminal calendar value is still LONG_MIN (Pending). ServerTime: %s, EventTime: %s", 
                              newsInfo.name, newsInfo.currency, (int)(TimeCurrent() - newsInfo.eventTime), TimeToString(TimeCurrent()), TimeToString(newsInfo.eventTime));
                  lastPrint = TimeCurrent();
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
   
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Create UI Text helper                                            |
//+------------------------------------------------------------------+
void CreateHUDText(string name, string text, int x, int y, int size, bool bold, color textClr)
  {
   if(ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
     {
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetString(0, name, OBJPROP_FONT, bold ? "Trebuchet MS" : "Arial");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
      ObjectSetInteger(0, name, OBJPROP_COLOR, textClr);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
     }
  }

//+------------------------------------------------------------------+
//| Create UI Panel helper                                           |
//+------------------------------------------------------------------+
void CreateHUDPanel(string name, int x, int y, int w, int h, color bgClr, int border)
  {
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
     }
  }

//+------------------------------------------------------------------+
//| Create Interactive Button helper                                 |
//+------------------------------------------------------------------+
void CreateHUDButton(string name, string text, int x, int y, int w, int h, color bgClr, color textClr)
  {
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
   
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
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
