//+------------------------------------------------------------------+
//|                                   Pepperstone_DOM_Sniper_V5.1.mq5|
//|                         Copyright 2025, Specialized for XAUUSD M1|
//|                          "Dynamic S/R Rolling Box & Weighted DOM"|
//|                                      Updated: Anti-Spam Hardened |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Gemini AI"
#property link      "https://www.pepperstone.com"
#property version   "5.10"
#property strict

#include <Trade\Trade.mqh>

//--- INPUT PARAMETERS ---
input group "=== XAUUSD MONEY MANAGEMENT ==="
input bool    InpUseAutoLot    = true;      // Auto Lot by Risk
input double  InpRiskPercent   = 1.0;       // Risk % per Trade
input double  InpFixedLot      = 0.01;      // Fallback Lot
input int     InpMaxSpread     = 35;        // Max Spread (Points) - Strict!

input group "=== DYNAMIC BATTLEGROUND (M1) ==="
input int     InpRollingPeriod = 60;        // Acuan H1 (60 Candle M1 terakhir)
input int     InpProximityZone = 30;        // Radius Aktif (Points) dari S/R

input group "=== DOM WEIGHTED LOGIC ==="
input double  InpDomRatio      = 2.0;       // Power Ratio (Buy vs Sell)
input double  InpDomThreshold  = 1.0;       // Min Power Value (Anti Data Kosong)

input group "=== SNIPER EXIT STRATEGY ==="
input int     InpBreakoutTP    = 400;       // TP Fixed untuk Breakout (Points)
input bool    InpUseAutoBE     = true;      // Aktifkan Auto Break Even
input int     InpBE_Trigger    = 100;       // Geser BE setelah profit X points
input int     InpBE_Offset     = 10;        // Jarak BE dari Entry (Points)
input int     InpAtrPeriod     = 14;        // ATR Period untuk SL Dinamis
input double  InpSlMultiplier  = 2.0;       // Buffer SL (x ATR)

input group "=== SYSTEM ==="
input int     InpMagicNumber   = 999051;    // Magic V5.1
input string  InpComment       = "Sniper_V5.1";

//--- GLOBAL VARIABLES ---
CTrade          trade;
bool            isDomSubscribed = false;
MqlBookInfo     bookInfo[];
int             handleATR;
datetime        lastCandleTime = 0;
ulong           lastTickTime = 0;
ulong           executionCooldown = 0;

//--- DYNAMIC DATA (RESET PER CANDLE) ---
double          dynHigh = 0;
double          dynLow = 0;
double          dynPivot = 0;
double          currATR = 0;

//--- DASHBOARD VARS ---
string          dStatus = "Init...";
string          dZone = "NEUTRAL";
double          dBuyPower = 0;
double          dSellPower = 0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpMaxSpread);
   trade.SetMarginMode();
   trade.SetTypeFilling(ORDER_FILLING_FOK); 
   
   if(!MarketBookAdd(_Symbol)) { Print("Error: DOM Data Missing!"); return(INIT_FAILED); }
   isDomSubscribed = true;
   
   handleATR = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   if(handleATR == INVALID_HANDLE) return(INIT_FAILED);
   
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(isDomSubscribed) MarketBookRelease(_Symbol);
   IndicatorRelease(handleATR);
   Comment(""); 
  }

//+------------------------------------------------------------------+
//| MAIN TICK ENGINE                                                 |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. CPU THROTTLER (Hemat VPS)
   if(GetTickCount() - lastTickTime < 100) return;
   lastTickTime = GetTickCount();

   // 2. SMART REFRESH (Layer 1: Reset Context per Candle)
   datetime currTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currTime != lastCandleTime)
   {
      UpdateDynamicSR(); // Hitung ulang High/Low 60
      lastCandleTime = currTime;
      dStatus = "New Candle: S/R Updated";
   }
   
   // 3. EXIT MANAGEMENT (Always Active)
   if(InpUseAutoBE) ManageAutoBE();

   // 4. DATA VALIDATION (Spread & Cooldown)
   if(!TerminalInfoInteger(TERMINAL_CONNECTED)) return;
   
   // Logic Cooldown yang ketat
   if(GetTickCount() < executionCooldown) { 
      // Update dashboard walau cooldown agar user tau status
      UpdateDashboard(); 
      return; 
   }
   
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread) { dStatus="Spread High: " + IntegerToString(spread); UpdateDashboard(); return; }
   
   // Cek posisi aktif, jika ada posisi, EA hanya memantau (tidak buka baru)
   if(CountOpenPositions() > 0) { dStatus="Trade Active..."; UpdateDashboard(); return; }

   // 5. PROXIMITY SENSOR (Layer 3: Sleep Mode)
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = _Point;
   
   double distHigh = MathAbs(dynHigh - bid) / point;
   double distLow  = MathAbs(ask - dynLow) / point;
   
   bool nearResistance = (distHigh <= InpProximityZone);
   bool nearSupport    = (distLow <= InpProximityZone);
   
   if(!nearResistance && !nearSupport) {
      dZone = "NEUTRAL (Idle)";
      dStatus = "Waiting for Zone...";
      dBuyPower = 0; dSellPower = 0;
      UpdateDashboard();
      return; 
   }

   // 6. DOM ANALYSIS (Layer 4: Weighted V4.7)
   CalculateWeightedDOM(dBuyPower, dSellPower);

   // 7. EXECUTION LOGIC (Dual-Core)
   
   // --- ZONA ATAS (RESISTANCE) ---
   if(nearResistance) {
      dZone = "RESISTANCE ZONE";
      
      // Skenario A: REVERSAL (Pantul ke Bawah)
      if(dSellPower > dBuyPower * InpDomRatio && dSellPower > InpDomThreshold) {
         if(bid < dynHigh + 50*point) { 
             ExecuteTrade(ORDER_TYPE_SELL, "REVERSAL_SELL");
             return;
         }
      }
      
      // Skenario B: BREAKOUT (Jebol ke Atas)
      if(dBuyPower > dSellPower * InpDomRatio && dBuyPower > InpDomThreshold) {
         ExecuteTrade(ORDER_TYPE_BUY, "BREAKOUT_BUY");
         return;
      }
   }
   
   // --- ZONA BAWAH (SUPPORT) ---
   if(nearSupport) {
      dZone = "SUPPORT ZONE";
      
      // Skenario A: REVERSAL (Pantul ke Atas)
      if(dBuyPower > dSellPower * InpDomRatio && dBuyPower > InpDomThreshold) {
         if(ask > dynLow - 50*point) {
            ExecuteTrade(ORDER_TYPE_BUY, "REVERSAL_BUY");
            return;
         }
      }
      
      // Skenario B: BREAKOUT (Jebol ke Bawah)
      if(dSellPower > dBuyPower * InpDomRatio && dSellPower > InpDomThreshold) {
         ExecuteTrade(ORDER_TYPE_SELL, "BREAKOUT_SELL");
         return;
      }
   }
   
   dStatus = "Scanning DOM...";
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                 |
//+------------------------------------------------------------------+

void UpdateDynamicSR()
{
   int highestIdx = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, InpRollingPeriod, 1);
   int lowestIdx  = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, InpRollingPeriod, 1);
   
   dynHigh = iHigh(_Symbol, PERIOD_CURRENT, highestIdx);
   dynLow  = iLow(_Symbol, PERIOD_CURRENT, lowestIdx);
   dynPivot = (dynHigh + dynLow) / 2.0;
   
   double atrArr[];
   ArraySetAsSeries(atrArr, true);
   CopyBuffer(handleATR, 0, 1, 1, atrArr);
   currATR = atrArr[0];
}

void CalculateWeightedDOM(double &bPower, double &sPower)
{
   bPower = 0; sPower = 0;
   if(!MarketBookGet(_Symbol, bookInfo)) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(pt == 0) pt = 0.00001;

   int size = ArraySize(bookInfo);
   for(int i=0; i<size; i++) {
      long t = bookInfo[i].type;
      double vol = (double)bookInfo[i].volume;
      double price = bookInfo[i].price;
      double weight = 1.0;
      
      if(t==BOOK_TYPE_SELL || t==BOOK_TYPE_SELL_MARKET) {
         double dist = MathAbs(price - ask) / pt;
         weight = 1.0 / (dist + 1.0);
         sPower += (vol * weight);
      }
      else if(t==BOOK_TYPE_BUY || t==BOOK_TYPE_BUY_MARKET) {
         double dist = MathAbs(bid - price) / pt;
         weight = 1.0 / (dist + 1.0);
         bPower += (vol * weight);
      }
   }
}

void ExecuteTrade(ENUM_ORDER_TYPE type, string note)
{
   double price, sl, tp;
   double slDist = currATR * InpSlMultiplier; 
   
   if(slDist == 0) slDist = 200 * _Point; 
   
   if(type == ORDER_TYPE_BUY) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = dynLow - slDist; 
      
      if(StringFind(note, "REVERSAL") >= 0) tp = dynPivot; 
      else tp = price + InpBreakoutTP * _Point; 
   } 
   else {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = dynHigh + slDist; 
      
      if(StringFind(note, "REVERSAL") >= 0) tp = dynPivot;
      else tp = price - InpBreakoutTP * _Point;
   }

   // --- SECURITY FIX: NORMALIZE DOUBLE ---
   price = NormalizeDouble(price, _Digits);
   sl    = NormalizeDouble(sl, _Digits);
   tp    = NormalizeDouble(tp, _Digits);

   double lot = CalculateLot(MathAbs(price - sl));
   if(lot <= 0) return;

   trade.SetExpertMagicNumber(InpMagicNumber);
   ResetLastError();
   
   bool res;
   if(type == ORDER_TYPE_BUY) res = trade.Buy(lot, _Symbol, price, sl, tp, note);
   else res = trade.Sell(lot, _Symbol, price, sl, tp, note);
   
   // --- SECURITY FIX: ANTI-SPAM LOGIC ---
   if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
       dStatus = "Entry: " + note;
       PlaySound("Ok.wav");
       // Cooldown sukses: 2 detik
       executionCooldown = GetTickCount() + 2000; 
   } else {
       dStatus = "Fail: " + IntegerToString(trade.ResultRetcode());
       Print("CRITICAL: Trade Failed. Code: ", trade.ResultRetcode(), ". Activating 5s Penalty.");
       // Cooldown GAGAL: 5 detik (Mencegah looping request ke broker)
       executionCooldown = GetTickCount() + 5000; 
   }
}

double CalculateLot(double slDistancePrice)
{
   if(!InpUseAutoLot) return InpFixedLot;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = bal * (InpRiskPercent / 100.0);
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts==0 || tv==0 || slDistancePrice==0) return InpFixedLot;
   
   double lossPerLot = (slDistancePrice / ts) * tv;
   if(lossPerLot == 0) return InpFixedLot;
   
   double lot = risk / lossPerLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   
   double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < min) lot = min; if(lot > max) lot = max;
   return lot;
}

void ManageAutoBE()
{
   if(PositionsTotal()==0) return;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double currSL = PositionGetDouble(POSITION_SL);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double tp = PositionGetDouble(POSITION_TP);
      double pt = _Point;
      
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
         if(bid > open + InpBE_Trigger * pt) {
            double newSL = open + InpBE_Offset * pt;
            // Normalisasi SL baru agar tidak error invalid price
            newSL = NormalizeDouble(newSL, _Digits);
            if(currSL < newSL - pt) trade.PositionModify(ticket, newSL, tp);
         }
      }
      else {
         if(ask < open - InpBE_Trigger * pt) {
            double newSL = open - InpBE_Offset * pt;
            // Normalisasi SL baru
            newSL = NormalizeDouble(newSL, _Digits);
            if(currSL == 0 || currSL > newSL + pt) trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

int CountOpenPositions() {
   int c=0;
   for(int i=PositionsTotal()-1; i>=0; i--) 
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) c++;
   return c;
}

void UpdateDashboard() {
   string s = "=== SNIPER V5.1 (HARDENED) ===\n";
   s += "Status : " + dStatus + "\n";
   s += "Zone   : " + dZone + "\n";
   s += "Range  : H[" + DoubleToString(dynHigh,2) + "] L[" + DoubleToString(dynLow,2) + "]\n";
   
   if(dZone != "NEUTRAL (Idle)") {
       s += "Power  : B[" + DoubleToString(dBuyPower,1) + "] vs S[" + DoubleToString(dSellPower,1) + "]\n";
       double ratio = (dSellPower > 0.1) ? dBuyPower/dSellPower : 0;
       s += "Ratio  : " + DoubleToString(ratio,2) + "x\n";
   } else {
       s += "Power  : --- (Sleeping)\n";
   }
   Comment(s);
}
