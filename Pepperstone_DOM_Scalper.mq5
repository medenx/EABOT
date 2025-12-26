//+------------------------------------------------------------------+
//|                                   Pepperstone_DOM_Scalper_V4.1.mq5 |
//|                        Copyright 2025, Specialized for M1 Scalping|
//|                                     "The Golden Master Version"  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Gemini AI"
#property link      "https://www.pepperstone.com"
#property version   "4.10"
#property strict

#include <Trade\Trade.mqh>

//--- INPUT PARAMETERS ---
input group "=== Money Management ==="
input bool   InpUseAutoLot = true;
input double InpRiskPercent = 1.0;
input double InpFixedLot   = 0.01;
input int    InpStopLoss   = 200;       // Stop Loss (Points)
input int    InpTakeProfit = 400;       // Take Profit (Points)

input group "=== M1 STRATEGY (MTF LOGIC) ==="
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_M5; // Acuan Tren (Master)
input int    InpEmaPeriod  = 50;        // Periode EMA Master
input bool   InpUseEmaSlope= true;      // Filter Kemiringan EMA

input group "=== DOM Execution (M1) ==="
input double InpDomRatio   = 2.5;       // Rasio Eksekusi
input int    InpMaxSpread  = 20;        // Maksimal Spread
input int    InpSlippage   = 50;        // Toleransi Slippage

input group "=== Volume Filter (RVOL) ==="
input bool   InpUseVolFilter = true;
input int    InpVolBaseline  = 50;      // Rata-rata 50 Candle
input int    InpVolThreshold = 80;      // Minimal aktivitas 80%

input group "=== System Info ==="
input int    InpMagicNumber = 999011;
input string InpComment     = "DOM_V4.1_Final";

//--- GLOBAL VARIABLES ---
CTrade         trade;
bool           isDomSubscribed = false;
MqlBookInfo    bookInfo[];
int            handleEMA;
datetime       lastBarTime = 0;
datetime       lastDashUpdate = 0;
ulong          executionCooldown = 0;   // VARIABEL ANTI-SPAM

//--- DASHBOARD VARS ---
string         statusMsg = "System Booting...";
string         dashTrendStatus = "Waiting...";
string         dashSlopeStatus = "Flat";
double         dashBuyVol = 0;
double         dashSellVol = 0;
double         dashVolPercent = 0;
int            orphanTrades = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetMarginMode();
   
   // Safety: Validasi Input
   if(InpVolBaseline < 10) { Print("INIT ERROR: Baseline Volume min 10"); return(INIT_FAILED); }
   if(InpStopLoss < 10 || InpTakeProfit < 10) { Print("INIT ERROR: SL/TP Terlalu Kecil"); return(INIT_FAILED); }
   
   // Filling Mode Detection
   if(!SetFillingMode()) { Print("INIT ERROR: Filling Mode Failed"); return(INIT_FAILED); }
   
   // Subscribe DOM
   if(!MarketBookAdd(_Symbol)) { Print("FATAL: Broker tidak support DOM Level 2"); return(INIT_FAILED); }
   isDomSubscribed = true;
   
   // Init EMA (MTF)
   handleEMA = iMA(_Symbol, InpTrendTF, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
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
   // --- 1. SAFETY & ANTI-SPAM CHECK ---
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !SymbolInfoInteger(_Symbol, SYMBOL_TIME)) return;
   
   // [ANTI-SPAM] Jika sedang cooldown, skip tick ini
   if(GetTickCount() < executionCooldown) return;

   // --- 2. DATA PREPARATION ---
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   
   // --- 3. VOLUME ANALYSIS (M1) ---
   if(Bars(_Symbol, PERIOD_CURRENT) < InpVolBaseline + 5) {
       statusMsg = "Waiting History Data..."; UpdateDashboard(); return;
   }
   
   long sumLong = 0;
   for(int i=1; i<=InpVolBaseline; i++) sumLong += iVolume(_Symbol, PERIOD_CURRENT, i);
   long baselineVol = sumLong / InpVolBaseline;
   
   long sumShort = 0;
   for(int i=1; i<=3; i++) sumShort += iVolume(_Symbol, PERIOD_CURRENT, i);
   long currentVol = sumShort / 3;
   
   dashVolPercent = (baselineVol > 0) ? ((double)currentVol / baselineVol * 100.0) : 0;

   // --- 4. TREND ANALYSIS (MTF - M5) ---
   double emaVal[];
   ArraySetAsSeries(emaVal, true);
   
   // Sinkronisasi Data M5
   if(CopyBuffer(handleEMA, 0, 0, 3, emaVal) != 3) {
       statusMsg = "Syncing M5 Trend..."; UpdateDashboard(); return;
   }
   
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool isPriceAbove = currentBid > emaVal[0];
   bool isSlopeUp = emaVal[0] > emaVal[1];
   bool isSlopeDown = emaVal[0] < emaVal[1];
   
   // Update String Dashboard
   dashTrendStatus = isPriceAbove ? "BULLISH (M5)" : "BEARISH (M5)";
   if(isSlopeUp) dashSlopeStatus = "UP (Strong)";
   else if(isSlopeDown) dashSlopeStatus = "DOWN (Strong)";
   else dashSlopeStatus = "FLAT (Risky)";

   // --- 5. DOM ANALYSIS ---
   double totalBuyVol = 0;
   double totalSellVol = 0;
   
   if(MarketBookGet(_Symbol, bookInfo)) {
      int size = ArraySize(bookInfo);
      if(size > 0) {
         for(int i=0; i<size; i++) {
            if(bookInfo[i].type == BOOK_TYPE_SELL || bookInfo[i].type == BOOK_TYPE_SELL_MARKET) totalSellVol += (double)bookInfo[i].volume;
            if(bookInfo[i].type == BOOK_TYPE_BUY || bookInfo[i].type == BOOK_TYPE_BUY_MARKET) totalBuyVol += (double)bookInfo[i].volume;
         }
      }
   }
   dashBuyVol = totalBuyVol;
   dashSellVol = totalSellVol;

   // Update Dashboard (Hemat CPU: 1x per detik)
   if(GetTickCount() - lastDashUpdate > 1000) {
       UpdateDashboard();
       lastDashUpdate = GetTickCount();
   }

   // --- 6. LOGIC & FILTERS ---
   datetime timeCurrentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   
   if(timeCurrentBar == lastBarTime) { statusMsg = "Trade Done (Wait Next)"; return; }
   if(CountOpenPositions() > 0) { statusMsg = "Managing Position"; return; }
   if(spread > InpMaxSpread) { statusMsg = "Spread High (" + IntegerToString(spread) + ")"; return; }
   
   // Filter Volume & DOM
   if(InpUseVolFilter && (baselineVol > 0 && dashVolPercent < InpVolThreshold)) {
       statusMsg = "Vol Low (" + DoubleToString(dashVolPercent,1) + "%)"; return;
   }
   if(totalSellVol < 1 || totalBuyVol < 1) { statusMsg = "DOM Empty"; return; }

   // --- 7. EXECUTION ENGINE (WITH ANTI-SPAM) ---
   
   // ENTRY BUY
   bool signalBuy = isPriceAbove && (InpUseEmaSlope ? isSlopeUp : true);
   
   if(signalBuy && totalBuyVol > (totalSellVol * InpDomRatio))
     {
      // Final Spread Check (Microsecond check)
      if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;
      
      double lot = CalculateLotSize();
      if(lot <= 0) return;
      
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      
      if(trade.Buy(lot, _Symbol, ask, ask-(InpStopLoss*_Point), ask+(InpTakeProfit*_Point), InpComment)) 
      {
          lastBarTime = timeCurrentBar; // Success: Lock Candle
          statusMsg = "BUY SUCCESS";
          UpdateDashboard();
      } 
      else 
      {
          // [ANTI-SPAM LOGIC]
          int err = GetLastError();
          Print("BUY FAILED. Error: ", err);
          
          // Jika Error Fatal, kunci candle ini agar tidak mencoba lagi
          if(err == 4756 || err == 10014 || err == 10019) { // Invalid volume, money, etc
              lastBarTime = timeCurrentBar; 
              statusMsg = "BUY ERROR (Fatal)";
          } else {
              // Jika Error Ringan (Requote/Connection), Cooldown 5 detik
              executionCooldown = GetTickCount() + 5000;
              statusMsg = "BUY RETRY in 5s...";
          }
      }
     }
     
   // ENTRY SELL
   bool signalSell = !isPriceAbove && (InpUseEmaSlope ? isSlopeDown : true);
   
   if(signalSell && totalSellVol > (totalBuyVol * InpDomRatio))
     {
      // Final Spread Check
      if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;

      double lot = CalculateLotSize();
      if(lot <= 0) return;

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      if(trade.Sell(lot, _Symbol, bid, bid+(InpStopLoss*_Point), bid-(InpTakeProfit*_Point), InpComment)) 
      {
          lastBarTime = timeCurrentBar; // Success: Lock Candle
          statusMsg = "SELL SUCCESS";
          UpdateDashboard();
      } 
      else 
      {
          // [ANTI-SPAM LOGIC]
          int err = GetLastError();
          Print("SELL FAILED. Error: ", err);
          
          if(err == 4756 || err == 10014 || err == 10019) {
              lastBarTime = timeCurrentBar;
              statusMsg = "SELL ERROR (Fatal)";
          } else {
              executionCooldown = GetTickCount() + 5000; // Cooldown 5s
              statusMsg = "SELL RETRY in 5s...";
          }
      }
     }
  }

//+------------------------------------------------------------------+
//| DASHBOARD & HELPERS                                              |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   orphanTrades = CountOrphanPositions();
   string text = "=== M1 DOM SCALPER V4.1 (GOLDEN MASTER) ===\n";
   text += "Status     : " + statusMsg + "\n";
   text += "---------------------------------\n";
   
   // Trend
   text += "[MTF TREND - M5]\n";
   text += "Direction  : " + dashTrendStatus + "\n";
   text += "Structure  : " + dashSlopeStatus + "\n";
   
   // Volume
   text += "---------------------------------\n";
   if(InpUseVolFilter) {
      text += "[MARKET ACTIVITY]\n";
      text += "Intensity  : " + DoubleToString(dashVolPercent, 1) + "%";
      text += (dashVolPercent < InpVolThreshold) ? " (WEAK)" : " (HEALTHY)";
      text += "\n";
   }
   
   // DOM
   text += "---------------------------------\n";
   double ratio = 0;
   string domState = "Neutral";
   if(dashBuyVol > 0 && dashSellVol > 0) {
      if(dashBuyVol > dashSellVol) {
         ratio = dashBuyVol / dashSellVol;
         domState = "BUYERS (" + DoubleToString(ratio, 1) + "x)";
      } else {
         ratio = dashSellVol / dashBuyVol;
         domState = "SELLERS (" + DoubleToString(ratio, 1) + "x)";
      }
   }
   text += "[ORDER FLOW]\n";
   text += "Sentiment  : " + domState + "\n";
   text += "Target     : > " + DoubleToString(InpDomRatio, 1) + "x\n";
   
   if(orphanTrades > 0) text += "\n[!] WARNING: " + IntegerToString(orphanTrades) + " Unknown Trades Found!";
   
   Comment(text);
  }

double CalculateLotSize() {
   if(!InpUseAutoLot) return InpFixedLot;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = bal * (InpRiskPercent / 100.0);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts==0 || tv==0) return InpFixedLot;
   
   // Rumus Akurat Loss
   double loss = (InpStopLoss*_Point/ts)*tv;
   if(loss==0) return InpFixedLot;
   
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lot = MathFloor((risk/loss)/step) * step;
   
   double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot<min) lot=min; if(lot>max) lot=max;
   return lot;
}

int CountOpenPositions() {
   int c=0;
   for(int i=PositionsTotal()-1; i>=0; i--) 
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) c++;
   return c;
}

int CountOrphanPositions() {
   int c=0;
   for(int i=PositionsTotal()-1; i>=0; i--) 
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) c++;
   return c;
}

bool SetFillingMode() {
   uint f = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) { trade.SetTypeFilling(ORDER_FILLING_FOK); return true; }
   if((f & SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) { trade.SetTypeFilling(ORDER_FILLING_IOC); return true; }
   trade.SetTypeFilling(ORDER_FILLING_RETURN);
   return true;
}
