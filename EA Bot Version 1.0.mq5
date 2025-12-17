//+------------------------------------------------------------------+
//|            EA Bot Version 1.1 (Optimized)                        |
//|      Refactored based on Weakness Analysis & Design Patterns     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Institutional Code"
#property link      "https://www.mql5.com"
#property version   "1.1"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

CTrade trade;
CPositionInfo positionInfo;

// =================================================================
// PARAMETER INPUT
// =================================================================
input group "=== CORE TRADING ==="
input int      InpMagicNum          = 998877;
input int      InpMaxPositions      = 1;
input double   InpFixedLots         = 0.02;

input group "=== TIME FILTER ==="
input bool     InpUseTimeFilter     = true;
input int      InpStartHour         = 1;
input int      InpEndHour           = 23;
input bool     InpCloseFriday       = true;
input int      InpFridayHour        = 21;

input group "=== STRATEGY SELECTORS ==="
input bool     InpUseStratMA        = true; // 1. Trend Filter
input bool     InpUseStratADX       = true; // 2. Strength Filter
input bool     InpUseStratRSI       = true; // 3. Momentum Filter
input bool     InpUseStratStoch     = true; // 4. Anti-Exhaustion Filter

input group "=== STRATEGY PARAMETERS ==="
input int      InpMAPeriod          = 14;
input int      InpADXPeriod         = 14;
input double   InpADXThreshold      = 20.0;
input int      InpRSIPeriod         = 14;
input int      InpStochK            = 8;
input int      InpStochD            = 3;
input int      InpStochSlowing      = 3;
input int      InpStochUpper        = 80;
input int      InpStochLower        = 20;

input group "=== RISK MANAGEMENT ==="
input int      InpStopLoss          = 6500;
input int      InpTakeProfit        = 12000;
input bool     InpUseTrailingStop   = true;
input int      InpTrailingStart     = 300;
input int      InpTrailingDist      = 300;
input int      InpTrailingStep      = 50;

input group "=== SYSTEM SAFETY & OPTS ==="
input bool     InpUseVolFilter      = false;
input int      InpATRPeriod         = 14;
input double   InpATRThreshold      = 0.7;   // NEW: Custom Sideways Threshold
input int      InpMaxSpread         = 500;
input int      InpSlippage          = 50;
input int      InpMaxRetryAttempts  = 5;     // NEW: Max Retries for Queue
input bool     InpEnableDebug       = true;

// =================================================================
// DATA STRUCTURES
// =================================================================
struct OrderTask {
    ulong ticket; 
    ENUM_ORDER_TYPE type;
    double qty, price, sl, tp;
    ulong timestamp; 
    int retry_count; 
    string hash; 
};

struct HealthMetrics {
    int exec_success;
    int exec_fail; 
    int consecutive_fails;
};

// IMPROVEMENT: Added explicit buffer management
class RingBufferOrderTask {
private: 
    OrderTask m_buffer[]; 
    int m_head, m_tail, m_count, m_capacity;
public:
    void Init(int capacity) { 
        ArrayResize(m_buffer, capacity);
        m_capacity = capacity; 
        m_head = 0; m_tail = 0; m_count = 0;
    }
    
    // Returns false if buffer is full (handling required by caller)
    bool Push(OrderTask &item) { 
        if(m_count >= m_capacity) { 
           // Strategy: Drop oldest item to make room for new (LIFO preference for market relevance)
           // Or return false to indicate congestion. Here we drop oldest.
           OrderTask temp;
           Pop(temp);
        } 
        m_buffer[m_tail] = item; 
        m_tail = (m_tail + 1) % m_capacity;
        m_count++; 
        return true; 
    }
    
    bool Pop(OrderTask &item) { 
        if(m_count <= 0) return false;
        item = m_buffer[m_head]; 
        m_head = (m_head + 1) % m_capacity; 
        m_count--; 
        return true;
    }
    
    int Count() { return m_count; }
};

// =================================================================
// GLOBAL VARIABLES
// =================================================================
int      handleMA = INVALID_HANDLE;
int      handleADX = INVALID_HANDLE;
int      handleRSI = INVALID_HANDLE;
int      handleATR = INVALID_HANDLE;
int      handleStoch = INVALID_HANDLE;

bool     g_is_broken = false;
ulong    g_broken_time = 0;
HealthMetrics g_health = {0, 0, 0};

RingBufferOrderTask g_retry_queue;
RingBufferOrderTask g_verify_queue;

double   cache_point;
ulong    g_failed_close_tickets[];

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

   // IMPROVEMENT: Retry mechanism for indicator initialization
   if(!InitIndicators()) return(INIT_FAILED);

   ArrayResize(g_failed_close_tickets, 0);
   Print("=== EA Bot Version 1.1 STARTED (Optimized) ===");
   
   return(INIT_SUCCEEDED);
}

// NEW: Separated Indicator Logic for Robustness
bool InitIndicators() {
    int attempts = 0;
    while(attempts < 3) {
        bool success = true;
        
        if(InpUseStratMA) {
            handleMA = iMA(_Symbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
            if(handleMA == INVALID_HANDLE) success = false;
        }
        
        if(InpUseStratADX) {
            handleADX = iADX(_Symbol, _Period, InpADXPeriod);
            if(handleADX == INVALID_HANDLE) success = false;
        }
        
        if(InpUseStratRSI) {
            handleRSI = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
            if(handleRSI == INVALID_HANDLE) success = false;
        }
        
        if(InpUseStratStoch) {
            handleStoch = iStochastic(_Symbol, _Period, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);
            if(handleStoch == INVALID_HANDLE) success = false;
        }
        
        handleATR = iATR(_Symbol, _Period, InpATRPeriod);
        if(handleATR == INVALID_HANDLE) success = false;

        if(success) return true;
        
        attempts++;
        Sleep(500); // Wait before retry
    }
    Print("Error: Indicators failed to initialize after 3 attempts");
    return false;
}

void OnDeinit(const int reason)
{
   if(handleMA != INVALID_HANDLE) IndicatorRelease(handleMA);
   if(handleADX != INVALID_HANDLE) IndicatorRelease(handleADX);
   if(handleRSI != INVALID_HANDLE) IndicatorRelease(handleRSI);
   if(handleATR != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleStoch != INVALID_HANDLE) IndicatorRelease(handleStoch);
}

// =================================================================
// ON TICK
// =================================================================
void OnTick()
{
   // 1. Process Queues
   ProcessVerifyQueue(); 
   ProcessRetryQueue();

   // 2. Circuit Breaker Check
   if(g_is_broken) {
      if(GetTickCount() - g_broken_time > 300000) { 
         g_is_broken = false;
         g_health.consecutive_fails = 0; 
         Print("Info: Circuit Breaker Reset");
      }
      return;
   }

   // 3. Pre-checks
   if(!RefreshCache()) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;

   // 4. Friday Logic (Priority)
   if(CheckFridayClose()) {
       // If Friday close is active, we do not scan for new signals
      return;
   }
   
   ManageOpenPositions();
   
   // 5. Entry Filters
   if(!IsNewBar()) return;
   if(InpUseTimeFilter && !IsTradingTimeOptimized()) return;
   if(CountOpenPositions() >= InpMaxPositions) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;
   if(InpUseVolFilter && IsSidewaysAuto()) return;

   // 6. Signal Execution
   ProcessSignal();
}

// ... [IsTradingTimeOptimized remains mostly the same] ...
bool IsTradingTimeOptimized() {
    MqlDateTime now;
    TimeCurrent(now);
    if(now.day_of_week == 6 || now.day_of_week == 0) return false;
    int current_hour = now.hour;
    if(InpStartHour <= InpEndHour) return (current_hour >= InpStartHour && current_hour < InpEndHour);
    else return (current_hour >= InpStartHour || current_hour < InpEndHour);
}

// ... [ProcessSignal & GetEntrySignal Logic remains the same - omitted for brevity] ...

void ProcessSignal()
{
   int signal = GetEntrySignal();
   if(signal == 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ENUM_ORDER_TYPE type = (signal == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = (signal == 1) ? ask : bid;
   
   double sl = 0, tp = 0;
   if(InpStopLoss > 0) sl = (signal == 1) ? price - (InpStopLoss * cache_point) : price + (InpStopLoss * cache_point);
   if(InpTakeProfit > 0) tp = (signal == 1) ? price + (InpTakeProfit * cache_point) : price - (InpTakeProfit * cache_point);

   string hash = StringFormat("%d_%.5f_%d", type, price, TimeCurrent());
   OpenOrderAsync(type, InpFixedLots, price, sl, tp, hash);
}

int GetEntrySignal()
{
   if(!InpUseStratMA && !InpUseStratADX && !InpUseStratRSI && !InpUseStratStoch) return 0;
   bool doBuy = true, doSell = true;
   double close1 = iClose(_Symbol, _Period, 1);

   // --- Logic A: MA ---
   if(InpUseStratMA) {
      double ma[1];
      if(CopyBuffer(handleMA, 0, 1, 1, ma) < 1) return 0; 
      if(close1 < ma[0]) doBuy = false;
      if(close1 > ma[0]) doSell = false;
   }

   // --- Logic B: ADX ---
   if(InpUseStratADX) {
      double adx[1], plus[1], minus[1];
      if(CopyBuffer(handleADX, 0, 1, 1, adx) < 1 || CopyBuffer(handleADX, 1, 1, 1, plus) < 1 || CopyBuffer(handleADX, 2, 1, 1, minus) < 1) return 0;
      if(adx[0] < InpADXThreshold) { doBuy = false; doSell = false; }
      else {
         if(plus[0] < minus[0]) doBuy = false;
         if(minus[0] < plus[0]) doSell = false;
      }
   }

   // --- Logic C: RSI ---
   if(InpUseStratRSI) {
      double rsi[1];
      if(CopyBuffer(handleRSI, 0, 1, 1, rsi) < 1) return 0;
      if(rsi[0] < 50.0) doBuy = false;
      if(rsi[0] > 50.0) doSell = false;
   }

   // --- Logic D: Stoch ---
   if(InpUseStratStoch) {
      double stoch_main[1];
      if(CopyBuffer(handleStoch, 0, 1, 1, stoch_main) < 1) return 0;
      if(stoch_main[0] > InpStochUpper && doBuy) doBuy = false;
      if(stoch_main[0] < InpStochLower && doSell) doSell = false;
   }

   if(doBuy && !doSell) return 1;
   if(doSell && !doBuy) return -1;
   return 0; 
}

bool OpenOrderAsync(ENUM_ORDER_TYPE type, double lot, double price, double sl, double tp, string hash)
{
    // Simplified margin check
    double margin_required = 0.0;
    if(!OrderCalcMargin(type, _Symbol, lot, price, margin_required)) return false;
    if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required) {
        if(InpEnableDebug) Print("Error: Insufficient Margin");
        return false;
    }
    
    string comment = "EA_Bot_v1.1";
    bool result = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, comment) : trade.Sell(lot, _Symbol, price, sl, tp, comment);
    
    if(result && trade.ResultRetcode() == TRADE_RETCODE_DONE) {
        OrderTask task;
        task.ticket = trade.ResultOrder();
        task.type = type;
        task.hash = hash;
        task.timestamp = GetTickCount();
        g_verify_queue.Push(task);
        UpdateHealth(true);
        return true;
    } else {
        // Enqueue for retry
        OrderTask task;
        task.type = type; task.qty = lot; task.price = price; task.sl = sl; task.tp = tp;
        task.hash = hash; task.timestamp = GetTickCount(); task.retry_count = 0;
        g_retry_queue.Push(task);
        UpdateHealth(false);
        return false;
    }
}

// IMPROVEMENT: Refactored Friday Close for robustness
bool CheckFridayClose()
{
    if(!InpCloseFriday) return false;
    MqlDateTime now;
    TimeCurrent(now);
    
    // Check if it is Friday past the hour
    if(now.day_of_week != 5 || now.hour < InpFridayHour) return false;

    // Check if we still have open positions
    int total = PositionsTotal();
    if (total == 0) return false;

    for(int i = total - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol) {
                 trade.PositionClose(ticket);
                 // We do not return immediately, we try to close all
            }
        }
    }
    
    return (CountOpenPositions() > 0); // Return true if positions still exist (blocks new entry)
}

// IMPROVEMENT: Added Max Retry limit to prevent infinite loops
void ProcessRetryQueue()
{
    int queue_size = g_retry_queue.Count();
    int processed = 0;
    while(processed < queue_size && processed < 5) {
        OrderTask task;
        if(!g_retry_queue.Pop(task)) break;
        
        // Discard if max retries exceeded
        if (task.retry_count > InpMaxRetryAttempts) {
             if(InpEnableDebug) Print("Queue: Task discarded after max retries. Hash: ", task.hash);
             processed++;
             continue;
        }

        ulong backoff_ms = 1000 * (1 << MathMin(task.retry_count, 3));
        
        if(GetTickCount() - task.timestamp >= backoff_ms) {
            if(!OpenOrderAsync(task.type, task.qty, task.price, task.sl, task.tp, task.hash)) {
                task.retry_count++;
                task.timestamp = GetTickCount();
                g_retry_queue.Push(task);
            }
        } else {
            g_retry_queue.Push(task);
        }
        processed++;
    }
}

// IMPROVEMENT: Added dynamic input for Sideways Threshold
bool IsSidewaysAuto() 
{ 
    int p = (_Period == PERIOD_M1) ? 1440 : 100; 
    double a[]; 
    ArraySetAsSeries(a, true); 
    if(CopyBuffer(handleATR, 0, 1, p, a) < p) return false; 
    
    double s = 0;
    for(int i = 0; i < p; i++) s += a[i];
    double avg = s / p;
    
    return (a[0] < (avg * InpATRThreshold)); // Used User Input
}

void ProcessVerifyQueue() 
{ 
    int m = g_verify_queue.Count(), x = 0;
    while(x < m && x < 10) { 
        OrderTask t; 
        if(!g_verify_queue.Pop(t)) break;
        if(GetTickCount() - t.timestamp < 10000 && !PositionSelectByTicket(t.ticket)) 
            g_verify_queue.Push(t);
        x++; 
    } 
}

void UpdateHealth(bool success) 
{ 
    if(success) {
        g_health.exec_success++;
        g_health.consecutive_fails = 0;
    } else {
        g_health.exec_fail++;
        g_health.consecutive_fails++;
        if(g_health.consecutive_fails > 5) {
            g_is_broken = true;
            g_broken_time = GetTickCount();
            Print("Alert: Circuit Breaker Activated! Too many consecutive failures.");
        }
    } 
}

void ManageOpenPositions() 
{ 
    if(!InpUseTrailingStop) return;
    double st = InpTrailingStart * cache_point;
    double dt = InpTrailingDist * cache_point;
    double sp = InpTrailingStep * cache_point;

    for(int i = PositionsTotal() - 1; i >= 0; i--) { 
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol) { 
            double sl = PositionGetDouble(POSITION_SL);
            double cr = PositionGetDouble(POSITION_PRICE_CURRENT);
            double op = PositionGetDouble(POSITION_PRICE_OPEN);
            double nsl = sl;
            bool modified = false;

            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) { 
                if(cr - op > st) { 
                    double target_sl = cr - dt;
                    if(target_sl > sl + sp) { nsl = target_sl; modified = true; } 
                } 
            } else { 
                if(op - cr > st) { 
                    double target_sl = cr + dt;
                    if(target_sl < sl - sp || sl == 0) { nsl = target_sl; modified = true; } 
                } 
            } 
            if(modified) trade.PositionModify(ticket, NormalizeDouble(nsl, _Digits), PositionGetDouble(POSITION_TP));
        } 
    } 
}

bool RefreshCache() 
{ 
    cache_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    return (cache_point > 0); 
}

bool IsNewBar() 
{ 
    static datetime last_bar_time = 0;
    datetime current_bar_time = iTime(_Symbol, _Period, 0); 
    if(last_bar_time != current_bar_time) {
        last_bar_time = current_bar_time;
        return true;
    } 
    return false; 
}

int CountOpenPositions() 
{ 
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol) {
            count++;
        }
    }
    return count; 
}
//+------------------------------------------------------------------+
