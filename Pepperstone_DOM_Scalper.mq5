//+------------------------------------------------------------------+
//|                                   Pepperstone_DOM_Scalper_V3.2.mq5 |
//|                        Copyright 2025, Specialized for Pepperstone|
//|                                          MetaTrader 5 MQL5       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Gemini AI"
#property link      "https://www.pepperstone.com"
#property version   "3.20"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== Money Management ==="
input double InpLotSize    = 0.01;      // Lot Size (Konservatif)
input int    InpStopLoss   = 250;       // Stop Loss (Points)
input int    InpTakeProfit = 500;       // Take Profit (Points)

input group "=== Strategy Filters ==="
input double InpDomRatio   = 3.0;       // Rasio Kekuatan DOM (Buy:Sell)
input int    InpEmaPeriod  = 100;       // Filter Tren EMA (Konservatif)
input long   InpMinTickVol = 50;        // Minimal Tick Volume
input int    InpMaxSpread  = 15;        // Maksimal Spread (Points)

input group "=== System ==="
input bool   InpUseRandomMagic = true;  // True = Magic Number Acak setiap restart

//--- Global Variables
CTrade         trade;
long           magicNumber;
string         eaComment = "DOM_V3.2_GoldMaster";
bool           isDomSubscribed = false;
MqlBookInfo    bookInfo[];
int            handleEMA;
datetime       lastBarTime = 0;

//--- Variabel Dashboard
string         statusMsg = "System Ready";
double         dashBuyVol = 0;
double         dashSellVol = 0;
string         dashTrend = "Computing...";
int            orphanTrades = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 1. Logic Magic Number
   if(InpUseRandomMagic) {
      MathSrand(GetTickCount());
      magicNumber = MathRand();
   } else {
      magicNumber = 123456; 
   }
   
   // 2. Setup Trade Class
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetDeviationInPoints(10);
   
   // FIX: Auto-Detect Filling Mode
   if(!SetFillingMode()) {
      Print("CRITICAL: Gagal setting Filling Mode.");
      return(INIT_FAILED);
   }
   
   // 3. Subscribe DOM
   if(!MarketBookAdd(_Symbol)) {
      Print("FATAL: Gagal subscribe DOM Level 2");
      return(INIT_FAILED);
   }
   isDomSubscribed = true;
   
   // 4. Init EMA
   handleEMA = iMA(_Symbol, PERIOD_M1, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(handleEMA == INVALID_HANDLE) return(INIT_FAILED);
   
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(isDomSubscribed) MarketBookRelease(_Symbol);
   IndicatorRelease(handleEMA);
   Comment(""); 
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // --- 1. SYSTEM CHECK ---
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) { 
      statusMsg = "AutoTrading Disabled!"; DisplayDashboard(); return; 
   }
   
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long tickVol = iVolume(_Symbol, PERIOD_M1, 0);
   
   orphanTrades = CountOrphanPositions();

   // --- 2. EMA DATA ---
   double emaVal[];
   ArraySetAsSeries(emaVal, true);
   if(CopyBuffer(handleEMA, 0, 0, 1, emaVal) != 1) {
      statusMsg = "Waiting for EMA Data...";
      DisplayDashboard();
      return;
   }
   
   bool isUptrend = bid > emaVal[0];
   bool isDowntrend = bid < emaVal[0];
   dashTrend = isUptrend ? "BULLISH (Buy Zone)" : "BEARISH (Sell Zone)";

   // --- 3. DOM ANALYSIS ---
   double totalBuyVol = 0;
   double totalSellVol = 0;
   
   if(MarketBookGet(_Symbol, bookInfo)) {
      int bookSize = ArraySize(bookInfo);
      for(int i=0; i<bookSize; i++) {
         if(bookInfo[i].type == BOOK_TYPE_SELL || bookInfo[i].type == BOOK_TYPE_SELL_MARKET)
            totalSellVol += (double)bookInfo[i].volume;
         if(bookInfo[i].type == BOOK_TYPE_BUY || bookInfo[i].type == BOOK_TYPE_BUY_MARKET)
            totalBuyVol += (double)bookInfo[i].volume;
      }
   }
   dashBuyVol = totalBuyVol;
   dashSellVol = totalSellVol;

   // --- 4. FILTERS (PERBAIKAN LOGIKA) ---
   datetime timeCurrentBar = iTime(_Symbol, PERIOD_M1, 0);
   
   // [FIX V3.2] HARD LOCK: Jika sudah pernah entry di bar ini (sukses/gagal), stop.
   if(timeCurrentBar == lastBarTime) {
      statusMsg = "Candle Locked (Trade Done)";
      DisplayDashboard();
      return;
   }
   
   // Filter: Posisi Max
   if(CountOpenPositions() > 0) {
      statusMsg = "Managing Position...";
      DisplayDashboard();
      return;
   }

   // Filter: Spread & Volume
   if(spread > InpMaxSpread) { statusMsg = "High Spread: " + IntegerToString(spread); DisplayDashboard(); return; }
   if(tickVol < InpMinTickVol) { statusMsg = "Low Volume (Sideways)"; DisplayDashboard(); return; }

   // FIX: StopLevel Check
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(InpStopLoss < stopLevel || InpTakeProfit < stopLevel) {
      statusMsg = "Error: SL/TP < Broker Limit (" + IntegerToString(stopLevel) + ")";
      DisplayDashboard();
      return;
   }

   // --- 5. EXECUTION ---
   if(totalSellVol <= 0 || totalBuyVol <= 0) return; 

   // ENTRY BUY
   if(isUptrend && totalBuyVol > (totalSellVol * InpDomRatio))
     {
      statusMsg = ">>> EXECUTING BUY <<<";
      DisplayDashboard();
      if(OpenTrade(ORDER_TYPE_BUY)) lastBarTime = timeCurrentBar; // Kunci Bar
     }
   // ENTRY SELL
   else if(isDowntrend && totalSellVol > (totalBuyVol * InpDomRatio))
     {
      statusMsg = ">>> EXECUTING SELL <<<";
      DisplayDashboard();
      if(OpenTrade(ORDER_TYPE_SELL)) lastBarTime = timeCurrentBar; // Kunci Bar
     }
   else
     {
      double ratio = (totalBuyVol > totalSellVol) ? totalBuyVol/totalSellVol : totalSellVol/totalBuyVol;
      statusMsg = "Scanning... (Ratio: " + DoubleToString(ratio, 1) + "x)";
      DisplayDashboard();
     }
  }

//+------------------------------------------------------------------+
//| DASHBOARD                                                        |
//+------------------------------------------------------------------+
void DisplayDashboard()
  {
   string text = "=== PEPPERSTONE DOM V3.2 (GOLD MASTER) ===\n";
   text += "Status: " + statusMsg + "\n";
   text += "Trend : " + dashTrend + "\n";
   text += "Spread: " + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + " pts\n";
   text += "----------------------------------------\n";
   
   string domStatus = "Balanced";
   if(dashBuyVol > 0 && dashSellVol > 0) {
      if(dashBuyVol > dashSellVol) domStatus = "BUYERS (" + DoubleToString(dashBuyVol/dashSellVol, 1) + "x)";
      else domStatus = "SELLERS (" + DoubleToString(dashSellVol/dashBuyVol, 1) + "x)";
   }
   text += "DOM   : " + domStatus + "\n";
   text += "Target: > " + DoubleToString(InpDomRatio, 1) + "x\n";
   
   text += "----------------------------------------\n";
   if(orphanTrades > 0) {
      text += "[!] WARNING: " + IntegerToString(orphanTrades) + " TRADE MANUAL/LIAR TERDETEKSI!\n";
   } else {
      text += "System Healthy. ID: " + IntegerToString(magicNumber) + "\n";
   }
   
   Comment(text);
  }

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                 |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == magicNumber)
         count++;
   }
   return count;
  }

int CountOrphanPositions()
  {
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) != magicNumber)
         count++;
   }
   return count;
  }

bool OpenTrade(ENUM_ORDER_TYPE type)
  {
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl    = (type == ORDER_TYPE_BUY) ? price - InpStopLoss * _Point : price + InpStopLoss * _Point;
   double tp    = (type == ORDER_TYPE_BUY) ? price + InpTakeProfit * _Point : price - InpTakeProfit * _Point;
   
   return trade.PositionOpen(_Symbol, type, InpLotSize, NormalizeDouble(price, _Digits), NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), eaComment);
  }

// FIX: SetFillingMode Logic
bool SetFillingMode()
  {
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) {
      trade.SetTypeFilling(ORDER_FILLING_FOK);
      return true;
   }
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) {
      trade.SetTypeFilling(ORDER_FILLING_IOC);
      return true;
   }
   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   return true;
  }
