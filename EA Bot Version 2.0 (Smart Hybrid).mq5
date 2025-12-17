//+------------------------------------------------------------------+
//|            EA Bot Version 2.0 (Smart Hybrid)                     |
//|      Features: Auto-Switch Strategy, MTF Filter, Dynamic MM      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Institutional Code"
#property link      "https://www.mql5.com"
#property version   "2.0"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

CTrade trade;
CPositionInfo positionInfo;

// =================================================================
// ENUMERATIONS
// =================================================================
enum ENUM_STRAT_MODE {
    MODE_MANUAL,        // User selects active indicators manually
    MODE_AUTO_ATR       // EA switches Trend/Reversal based on ATR
};

// =================================================================
// PARAMETER INPUT
// =================================================================
input group "=== INTELLIGENCE CORE (V2.0) ==="
input ENUM_STRAT_MODE InpStratMode  = MODE_AUTO_ATR; // Strategy Mode
input ENUM_TIMEFRAMES InpTrendTF    = PERIOD_H4;     // Multi-Timeframe Trend Filter
input int      InpATR_Switch_Period = 14;            // Period for Volatility Check
input double   InpATR_Switch_Level  = 0.0015;        // Threshold (Points normalized) to switch Trending

input group "=== MONEY MANAGEMENT ==="
input bool     InpUseDynamicLot     = true;      // Use Risk Based Lot
input double   InpRiskPercent       = 1.0;       // Risk % per trade
input double   InpFixedLots         = 0.02;      // Fallback Lot

input group "=== DYNAMIC SL/TP ==="
input bool     InpUseATR_SLTP       = true;
input int      InpATR_SLTP_Period   = 14;
input double   InpATR_SL_Ratio      = 1.5;
input double   InpATR_TP_Ratio      = 3.0;

input group "=== CORE SETTINGS ==="
input int      InpMagicNum          = 998822;
input int      InpMaxPositions      = 1;

input group "=== TIME FILTER ==="
input bool     InpUseTimeFilter     = true;
input int      InpStartHour         = 1;
input int      InpEndHour           = 23;
input bool     InpCloseFriday       = true;
input int      InpFridayHour        = 21;

input group "=== STRATEGY PARAMETERS ==="
// Trend Indicators (Used in Trending Mode)
input int      InpMAPeriod          = 50;    // MA on Higher Timeframe
input int      InpADXPeriod         = 14;
input double   InpADXThreshold      = 25.0;

// Reversal Indicators (Used in Sideways Mode)
input int      InpRSIPeriod         = 14;
input int      InpStochK            = 8;
input int      InpStochD            = 3;
input int      InpStochSlowing      = 3;
input int      InpStochUpper        = 80;
input int      InpStochLower        = 20;

input group "=== RISK FALLBACK ==="
input int      InpStopLossFixed     = 6500;  
input int      InpTakeProfitFixed   = 12000; 
input bool     InpUseTrailingStop   = true;
input int      InpTrailingStart     = 300;
input int      InpTrailingDist      = 300;
input int      InpTrailingStep      = 50;

input group "=== SYSTEM SAFETY ==="
input int      InpMaxSpread         = 500;
input int      InpSlippage          = 50;
input int      InpMaxRetryAttempts  = 5;
input bool     InpEnableDebug       = true;

// =================================================================
// DATA STRUCTURES
// =================================================================
struct OrderTask {
    ulong ticket; ENUM_ORDER_TYPE type;
    double qty, price, sl, tp;
    ulong timestamp; int retry_count; string hash; 
};

struct HealthMetrics {
    int exec_success; int exec_fail; int consecutive_fails;
};

class RingBufferOrderTask {
private: 
    OrderTask m_buffer[]; int m_head, m_tail, m_count, m_capacity;
public:
    void Init(int capacity) { 
        ArrayResize(m_buffer, capacity); m_capacity = capacity; 
        m_head = 0; m_tail = 0; m_count = 0;
    }
    bool Push(OrderTask &item) { 
        if(m_count >= m_capacity) { OrderTask t; Pop(t); } 
        m_buffer[m_tail] = item; m_tail = (m_tail + 1) % m_capacity; m_count++; 
        return true; 
    }
    bool Pop(OrderTask &item) { 
        if(m_count <= 0) return false;
        item = m_buffer[m_head]; m_head = (m_head + 1) % m_capacity; m_count--; 
        return true;
    }
    int Count() { return m_count; }
};

// =================================================================
// GLOBAL VARIABLES
// =================================================================
int      handleMA_MTF = INVALID_HANDLE;     // Multi-Timeframe MA
int      handleADX = INVALID_HANDLE;
int      handleRSI = INVALID_HANDLE;
int      handleStoch = INVALID_HANDLE;
int      handleATR_Switch = INVALID_HANDLE; // For Logic Switching
int      handleATR_SLTP = INVALID_HANDLE;   // For Dynamic SL/TP

bool     g_is_broken = false;
ulong    g_broken_time = 0;
HealthMetrics g_health = {0, 0, 0};

RingBufferOrderTask g_retry_queue;
RingBufferOrderTask g_verify_queue;

double   cache_point;

// =================================================================
// INITIALIZATION
// =================================================================
int OnInit()
{
   if(InpMagicNum <= 0) return(INIT_PARAMETERS_INCORRECT);

   g_retry_queue.Init(50); 
   g_verify_queue.Init(100);
   
   if(!RefreshCache()) return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   if(!InitIndicators()) return(INIT_FAILED);

   Print("=== EA Bot Version 2.0 STARTED (Smart Hybrid) ===");
   Print("Strategy Mode: ", EnumToString(InpStratMode));
   Print("Trend Timeframe: ", EnumToString(InpTrendTF));
   
   return(INIT_SUCCEEDED);
}

bool InitIndicators() {
    int attempts = 0;
    while(attempts < 3) {
        bool success = true;
        
        // 1. MTF MA (Trend Filter)
        handleMA_MTF = iMA(_Symbol, InpTrendTF, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
        if(handleMA_MTF == INVALID_HANDLE) success = false;
        
        // 2. ADX (Trend Strength)
        handleADX = iADX(_Symbol, _Period, InpADXPeriod);
        if(handleADX == INVALID_HANDLE) success = false;
        
        // 3. RSI (Momentum)
        handleRSI = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
        if(handleRSI == INVALID_HANDLE) success = false;
        
        // 4. Stochastic (Reversal)
        handleStoch = iStochastic(_Symbol, _Period, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);
        if(handleStoch == INVALID_HANDLE) success = false;
        
        // 5. ATR for Switching
        handleATR_Switch = iATR(_Symbol, _Period, InpATR_Switch_Period);
        if(handleATR_Switch == INVALID_HANDLE) success = false;

        // 6. ATR for SL/TP
        if(InpUseATR_SLTP) {
             handleATR_SLTP = iATR(_Symbol, _Period, InpATR_SLTP_Period);
             if(handleATR_SLTP == INVALID_HANDLE) success = false;
        }

        if(success) return true;
        attempts++; Sleep(500);
    }
    Print("Error: Indicators failed to initialize");
    return false;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(handleMA_MTF);
   IndicatorRelease(handleADX);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleStoch);
   IndicatorRelease(handleATR_Switch);
   if(handleATR_SLTP != INVALID_HANDLE) IndicatorRelease(handleATR_SLTP);
}

// =================================================================
// ON TICK
// =================================================================
void OnTick()
{
   ProcessVerifyQueue(); 
   ProcessRetryQueue();

   if(g_is_broken) {
      if(GetTickCount() - g_broken_time > 300000) { 
         g_is_broken = false; g_health.consecutive_fails = 0; 
         Print("Info: Circuit Breaker Reset");
      }
      return;
   }

   if(!RefreshCache()) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(CheckFridayClose()) return;
   
   ManageOpenPositions();
   
   if(!IsNewBar()) return;
   if(InpUseTimeFilter && !IsTradingTimeOptimized()) return;
   if(CountOpenPositions() >= InpMaxPositions) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;

   ProcessSignal();
}

// =================================================================
// INTELLIGENT SIGNAL LOGIC (V2.0 Core)
// =================================================================
int GetEntrySignal()
{
   // --- STEP 1: Determine Strategy Mode ---
   bool useTrendStrat = false;
   bool useReversalStrat = false;

   if (InpStratMode == MODE_MANUAL) {
       // Manual selection not implemented in inputs for brevity in V2, 
       // defaulting to AUTO logic or could imply all active. 
       // For V2 purity, we assume Auto is the main goal.
       // Let's fallback to "Hybrid" (All Active) if manual.
       useTrendStrat = true; 
       useReversalStrat = true;
   } 
   else if (InpStratMode == MODE_AUTO_ATR) {
       double atrVal = GetATRValue(handleATR_Switch);
       
       // Compare ATR to Threshold (InpATR_Switch_Level needs to be tuned for the symbol)
       // If ATR is high -> Market is volatile -> TREND FOLLOW
       // If ATR is low  -> Market is calm     -> REVERSAL / SCALP
       
       if (atrVal > InpATR_Switch_Level) {
           useTrendStrat = true;
           useReversalStrat = false;
           if(InpEnableDebug) Print("Auto-Mode: High Volatility (", DoubleToString(atrVal,5), "). Strategy: TREND");
       } else {
           useTrendStrat = false;
           useReversalStrat = true;
           if(InpEnableDebug) Print("Auto-Mode: Low Volatility (", DoubleToString(atrVal,5), "). Strategy: REVERSAL");
       }
   }

   // Initialize Veto System (Optimistic)
   bool doBuy = true;
   bool doSell = true;
   
   double close1 = iClose(_Symbol, _Period, 1);

   // --- STEP 2: TREND LOGIC (Multi-Timeframe) ---
   if (useTrendStrat) {
       // A. MA Filter (MTF)
       double ma[1];
       // Note: We copy from the MTF Handle
       if(CopyBuffer(handleMA_MTF, 0, 0, 1, ma) < 1) return 0; // Copy index 0 of HTF (Current HTF bar)
       
       // Filter: Price must be above MA for Buy
       if (close1 < ma[0]) doBuy = false;
       if (close1 > ma[0]) doSell = false;

       // B. ADX Filter (Trend Strength)
       double adx[1], plus[1], minus[1];
       if(CopyBuffer(handleADX, 0, 1, 1, adx) < 1 || CopyBuffer(handleADX, 1, 1, 1, plus) < 1 || CopyBuffer(handleADX, 2, 1, 1, minus) < 1) return 0;
       
       if(adx[0] < InpADXThreshold) { 
           doBuy = false; doSell = false; // Weak trend
       } else {
           if(plus[0] < minus[0]) doBuy = false;
           if(minus[0] < plus[0]) doSell = false;
       }
   }

   // --- STEP 3: REVERSAL LOGIC (Sideways) ---
   if (useReversalStrat) {
       // A. RSI (Momentum Reversion)
       double rsi[1];
       if(CopyBuffer(handleRSI, 0, 1, 1, rsi) < 1) return 0;
       
       // Buy only if Oversold (or crossing up), Sell if Overbought
       // Simplified Reversal: 
       // If RSI < 30 -> Potential BUY (Block Sell)
       // If RSI > 70 -> Potential SELL (Block Buy)
       // For strict filter:
       if (rsi[0] > 50) doBuy = false;  // In reversal mode, we sell at top
       if (rsi[0] < 50) doSell = false; // In reversal mode, we buy at bottom
       
       // B. Stochastic (Precision Entry)
       double stoch[1];
       if(CopyBuffer(handleStoch, 0, 1, 1, stoch) < 1) return 0;
       
       // Overbought zone (e.g., > 80) -> Look for Sell
       if (stoch[0] > InpStochUpper) {
            if(doBuy) doBuy = false; // Definitely don't buy at top
       } else if (stoch[0] < InpStochLower) {
            if(doSell) doSell = false; // Definitely don't sell at bottom
       } else {
            // Middle zone -> No trade in reversal mode usually
            doBuy = false; 
            doSell = false;
       }
   }

   // --- FINAL DECISION ---
   if(doBuy && !doSell) return 1;
   if(doSell && !doBuy) return -1;
   return 0; 
}

double GetATRValue(int handle) {
    double buff[1];
    if(CopyBuffer(handle, 0, 1, 1, buff) < 1) return 0.0;
    return buff[0];
}

void ProcessSignal()
{
   int signal = GetEntrySignal();
   if(signal == 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ENUM_ORDER_TYPE type = (signal == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = (signal == 1) ? ask : bid;
   
   double sl = 0, tp = 0;
   double sl_dist_points = 0;

   if(InpUseATR_SLTP) {
       double atr = GetATRValue(handleATR_SLTP);
       if(atr > 0) {
           double sl_val = atr * InpATR_SL_Ratio;
           double tp_val = atr * InpATR_TP_Ratio;
           sl_dist_points = sl_val / _Point;
           
           if(signal == 1) { sl = price - sl_val; tp = price + tp_val; } 
           else { sl = price + sl_val; tp = price - tp_val; }
       }
   } else {
       sl_dist_points = InpStopLossFixed;
       if(InpStopLossFixed > 0) sl = (signal == 1) ? price - (InpStopLossFixed * cache_point) : price + (InpStopLossFixed * cache_point);
       if(InpTakeProfitFixed > 0) tp = (signal == 1) ? price + (InpTakeProfitFixed * cache_point) : price - (InpTakeProfitFixed * cache_point);
   }

   double tradeLot = CalculateLotSize(sl_dist_points);
   string hash = StringFormat("%d_%.5f_%d", type, price, TimeCurrent());
   
   if(InpEnableDebug) Print("SIGNAL V2: ", EnumToString(type), " | Mode: ", EnumToString(InpStratMode), " | Lot: ", tradeLot);

   OpenOrderAsync(type, tradeLot, price, sl, tp, hash);
}

double CalculateLotSize(double slDistancePoints)
{
   if(!InpUseDynamicLot || slDistancePoints <= 0) return InpFixedLots;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (InpRiskPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return InpFixedLots;

   double lossPerLot = (slDistancePoints * _Point) / tickSize * tickValue;
   if(lossPerLot <= 0) return InpFixedLots;
   
   double rawLot = riskMoney / lossPerLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots = MathFloor(rawLot / step) * step;
   
   double min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lots < min) lots = min; if(lots > max) lots = max;
   return lots;
}

// =================================================================
// STANDARD FUNCTIONS (Queue, Safety, Etc)
// =================================================================
bool OpenOrderAsync(ENUM_ORDER_TYPE type, double lot, double price, double sl, double tp, string hash)
{
    double margin_required = 0.0;
    if(!OrderCalcMargin(type, _Symbol, lot, price, margin_required)) return false;
    if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required) return false;
    
    string comment = "EA_Bot_v2.0_Hybrid";
    bool result = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, comment) : trade.Sell(lot, _Symbol, price, sl, tp, comment);
    
    if(result && trade.ResultRetcode() == TRADE_RETCODE_DONE) {
        OrderTask task; task.ticket = trade.ResultOrder(); task.type = type; task.hash = hash; task.timestamp = GetTickCount();
        g_verify_queue.Push(task); UpdateHealth(true); return true;
    } else {
        OrderTask task; task.type = type; task.qty = lot; task.price = price; task.sl = sl; task.tp = tp; task.hash = hash; task.timestamp = GetTickCount(); task.retry_count = 0;
        g_retry_queue.Push(task); UpdateHealth(false); return false;
    }
}

// ... [Standard Queue & Maintenance Functions Same as V1.2] ...
void ProcessRetryQueue() {
    int q = g_retry_queue.Count(), p = 0;
    while(p < q && p < 5) {
        OrderTask t; if(!g_retry_queue.Pop(t)) break;
        if (t.retry_count > InpMaxRetryAttempts) { p++; continue; }
        if(GetTickCount() - t.timestamp >= (ulong)(1000 * (1 << MathMin(t.retry_count, 3)))) {
            if(!OpenOrderAsync(t.type, t.qty, t.price, t.sl, t.tp, t.hash)) {
                t.retry_count++; t.timestamp = GetTickCount(); g_retry_queue.Push(t);
            }
        } else g_retry_queue.Push(t);
        p++;
    }
}
void ProcessVerifyQueue() { 
    int m = g_verify_queue.Count(), x = 0;
    while(x < m && x < 10) { OrderTask t; if(!g_verify_queue.Pop(t)) break; if(GetTickCount() - t.timestamp < 10000 && !PositionSelectByTicket(t.ticket)) g_verify_queue.Push(t); x++; } 
}
void UpdateHealth(bool success) { 
    if(success) { g_health.exec_success++; g_health.consecutive_fails = 0; } 
    else { g_health.exec_fail++; g_health.consecutive_fails++; if(g_health.consecutive_fails > 5) { g_is_broken = true; g_broken_time = GetTickCount(); Print("Circuit Breaker!"); } } 
}
bool CheckFridayClose() {
    if(!InpCloseFriday) return false;
    MqlDateTime now; TimeCurrent(now);
    if(now.day_of_week != 5 || now.hour < InpFridayHour) return false;
    for(int i=PositionsTotal()-1; i>=0; i--) {
        ulong t = PositionGetTicket(i);
        if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC)==InpMagicNum) trade.PositionClose(t);
    }
    return (CountOpenPositions() > 0);
}
void ManageOpenPositions() { 
    if(!InpUseTrailingStop) return;
    double st = InpTrailingStart * cache_point, dt = InpTrailingDist * cache_point, sp = InpTrailingStep * cache_point;
    for(int i=PositionsTotal()-1; i>=0; i--) { 
        ulong t = PositionGetTicket(i);
        if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC)==InpMagicNum) { 
            double sl = PositionGetDouble(POSITION_SL), cr = PositionGetDouble(POSITION_PRICE_CURRENT), op = PositionGetDouble(POSITION_PRICE_OPEN), nsl = sl;
            bool mod = false;
            if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) { if(cr-op>st) { double tgt=cr-dt; if(tgt>sl+sp) { nsl=tgt; mod=true; } } }
            else { if(op-cr>st) { double tgt=cr+dt; if(tgt<sl-sp||sl==0) { nsl=tgt; mod=true; } } }
            if(mod) trade.PositionModify(t, NormalizeDouble(nsl,_Digits), PositionGetDouble(POSITION_TP));
        } 
    } 
}
bool RefreshCache() { cache_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); return (cache_point > 0); }
bool IsNewBar() { static datetime l=0; datetime c=iTime(_Symbol,_Period,0); if(l!=c) { l=c; return true; } return false; }
bool IsTradingTimeOptimized() { MqlDateTime n; TimeCurrent(n); if(n.day_of_week==6||n.day_of_week==0) return false; if(InpStartHour<=InpEndHour) return (n.hour>=InpStartHour && n.hour<InpEndHour); else return (n.hour>=InpStartHour || n.hour<InpEndHour); }
int CountOpenPositions() { int c=0; for(int i=PositionsTotal()-1; i>=0; i--) { ulong t=PositionGetTicket(i); if(t>0 && PositionGetInteger(POSITION_MAGIC)==InpMagicNum) c++; } return c; }
//+------------------------------------------------------------------+

