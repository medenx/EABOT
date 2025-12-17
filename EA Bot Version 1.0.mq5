//+------------------------------------------------------------------+
//|            EA Bot Version 1.2 (Advanced MM & Robustness)         |
//|      Features: Dynamic Risk Lots, ATR SL/TP, Queue Safety        |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Institutional Code"
#property link      "https://www.mql5.com"
#property version   "1.2"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

CTrade trade;
CPositionInfo positionInfo;

// =================================================================
// PARAMETER INPUT
// =================================================================
input group "=== MONEY MANAGEMENT (NEW) ==="
input bool     InpUseDynamicLot     = true;      // Use Risk Based Lot
input double   InpRiskPercent       = 1.0;       // Risk % per trade (e.g. 1.0% of Equity)
input double   InpFixedLots         = 0.05;      // Base/Fallback Lot Size

input group "=== DYNAMIC SL/TP (NEW) ==="
input bool     InpUseATR_SLTP       = true;      // Use ATR for SL/TP distances
input int      InpATR_SLTP_Period   = 14;        // ATR Period for Calculation
input double   InpATR_SL_Ratio      = 1.5;       // Stop Loss = ATR * 1.5
input double   InpATR_TP_Ratio      = 3.0;       // Take Profit = ATR * 3.0

input group "=== CORE SETTINGS ==="
input int      InpMagicNum          = 998877;
input int      InpMaxPositions      = 1;

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

input group "=== RISK FALLBACK ==="
input int      InpStopLossFixed     = 6500;  // Fixed SL (Points) if ATR disabled
input int      InpTakeProfitFixed   = 12000; // Fixed TP (Points) if ATR disabled
input bool     InpUseTrailingStop   = true;
input int      InpTrailingStart     = 300;
input int      InpTrailingDist      = 300;
input int      InpTrailingStep      = 50;

input group "=== SYSTEM SAFETY & OPTS ==="
input bool     InpUseVolFilter      = false;
input int      InpATRPeriod         = 14;    // ATR for Sideways Filter
input double   InpATRThreshold      = 0.7;   // Custom Sideways Threshold
input int      InpMaxSpread         = 500;
input int      InpSlippage          = 50;
input int      InpMaxRetryAttempts  = 5;     // Max Retries for Queue
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
    
    bool Push(OrderTask &item) { 
        if(m_count >= m_capacity) { 
           OrderTask temp; Pop(temp); // Drop oldest
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
int      handleATR_Filter = INVALID_HANDLE; // For Sideways
int      handleATR_SLTP = INVALID_HANDLE;   // For Dynamic SL/TP
int      handleStoch = INVALID_HANDLE;

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

   Print("=== EA Bot Version 1.2 STARTED ===");
   Print("Mode: ", InpUseDynamicLot ? "Dynamic Risk (" + DoubleToString(InpRiskPercent,1) + "%)" : "Fixed Lot");
   Print("SL/TP: ", InpUseATR_SLTP ? "Dynamic ATR" : "Fixed Points");
   
   return(INIT_SUCCEEDED);
}

// Robust Indicator Init
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
        
        // ATR for Sideways Filter
        handleATR_Filter = iATR(_Symbol, _Period, InpATRPeriod);
        if(handleATR_Filter == INVALID_HANDLE) success = false;

        // ATR for SL/TP (Ensure handle is created even if periods overlap)
        if(InpUseATR_SLTP) {
             handleATR_SLTP = iATR(_Symbol, _Period, InpATR_SLTP_Period);
             if(handleATR_SLTP == INVALID_HANDLE) success = false;
        }

        if(success) return true;
        
        attempts++;
        Sleep(500);
    }
    Print("Error: Indicators failed to initialize after 3 attempts");
    return false;
}

void OnDeinit(const int reason)
{
   if(handleMA != INVALID_HANDLE) IndicatorRelease(handleMA);
   if(handleADX != INVALID_HANDLE) IndicatorRelease(handleADX);
   if(handleRSI != INVALID_HANDLE) IndicatorRelease(handleRSI);
   if(handleATR_Filter != INVALID_HANDLE) IndicatorRelease(handleATR_Filter);
   if(handleATR_SLTP != INVALID_HANDLE) IndicatorRelease(handleATR_SLTP);
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

   // 2. Circuit Breaker
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

   // 4. Friday Logic
   if(CheckFridayClose()) return;
   
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

// =================================================================
// TRADING LOGIC
// =================================================================

// NEW: Dynamic Lot Calculation
double CalculateLotSize(double slDistancePoints)
{
   if(!InpUseDynamicLot) return InpFixedLots;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (InpRiskPercent / 100.0);
   
   // Get Value per Point
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   // Safety check to avoid division by zero
   if(slDistancePoints <= 0 || tickValue <= 0 || tickSize <= 0) {
       if(InpEnableDebug) Print("Warning: Cannot calc dynamic lot (Data invalid). Using Fixed.");
       return InpFixedLots;
   }

   // Formula: Lot = RiskMoney / (SL_Points * TickValue_Per_Point)
   // We convert SL Points to monetary loss per 1.0 lot
   double lossPerLot = (slDistancePoints * _Point) / tickSize * tickValue;
   
   if(lossPerLot <= 0) return InpFixedLots;

   double rawLot = riskMoney / lossPerLot;
   
   // Normalize to broker limits
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   double lots = MathFloor(rawLot / stepLot) * stepLot;
   
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   
   return lots;
}

void ProcessSignal()
{
   int signal = GetEntrySignal();
   if(signal == 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ENUM_ORDER_TYPE type = (signal == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = (signal == 1) ? ask : bid;
   
   // --- NEW: SL/TP LOGIC ---
   double sl = 0, tp = 0;
   double sl_dist_points = 0; // Needed for Money Management

   if(InpUseATR_SLTP) {
       double atr[];
       if(CopyBuffer(handleATR_SLTP, 0, 0, 1, atr) > 0) {
           double atrVal = atr[0];
           double sl_val = atrVal * InpATR_SL_Ratio;
           double tp_val = atrVal * InpATR_TP_Ratio;
           
           sl_dist_points = sl_val / _Point; // Convert value to points
           
           if(signal == 1) { // BUY
               sl = price - sl_val;
               tp = price + tp_val;
           } else { // SELL
               sl = price + sl_val;
               tp = price - tp_val;
           }
       } else {
           Print("Error: Failed to fetch ATR for SL/TP");
           return;
       }
   } else {
       // Fixed Logic
       sl_dist_points = InpStopLossFixed;
       if(InpStopLossFixed > 0) {
           sl = (signal == 1) ? price - (InpStopLossFixed * cache_point) : price + (InpStopLossFixed * cache_point);
       }
       if(InpTakeProfitFixed > 0) {
           tp = (signal == 1) ? price + (InpTakeProfitFixed * cache_point) : price - (InpTakeProfitFixed * cache_point);
       }
   }

   // --- NEW: MONEY MANAGEMENT ---
   double tradeLot = CalculateLotSize(sl_dist_points);

   string hash = StringFormat("%d_%.5f_%d", type, price, TimeCurrent());
   
   if(InpEnableDebug) {
       Print("SIGNAL: ", EnumToString(type), 
             " | Lot: ", DoubleToString(tradeLot, 2), 
             " | SL Dist: ", DoubleToString(sl_dist_points, 0));
   }

   OpenOrderAsync(type, tradeLot, price, sl, tp, hash);
}

int GetEntrySignal()
{
   if(!InpUseStratMA && !InpUseStratADX && !InpUseStratRSI && !InpUseStratStoch) return 0;
   bool doBuy = true, doSell = true;
   double close1 = iClose(_Symbol, _Period, 1);

   if(InpUseStratMA) {
      double ma[1];
      if(CopyBuffer(handleMA, 0, 1, 1, ma) < 1) return 0; 
      if(close1 < ma[0]) doBuy = false;
      if(close1 > ma[0]) doSell = false;
   }

   if(InpUseStratADX) {
      double adx[1], plus[1], minus[1];
      if(CopyBuffer(handleADX, 0, 1, 1, adx) < 1 || CopyBuffer(handleADX, 1, 1, 1, plus) < 1 || CopyBuffer(handleADX, 2, 1, 1, minus) < 1) return 0;
      if(adx[0] < InpADXThreshold) { doBuy = false; doSell = false; }
      else {
         if(plus[0] < minus[0]) doBuy = false;
         if(minus[0] < plus[0]) doSell = false;
      }
   }

   if(InpUseStratRSI) {
      double rsi[1];
      if(CopyBuffer(handleRSI, 0, 1, 1, rsi) < 1) return 0;
      if(rsi[0] < 50.0) doBuy = false;
      if(rsi[0] > 50.0) doSell = false;
   }

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
    // Margin Check
    double margin_required = 0.0;
    if(!OrderCalcMargin(type, _Symbol, lot, price, margin_required)) return false;
    if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required) {
        if(InpEnableDebug) Print("Error: Insufficient Margin for Lot ", lot);
        return false;
    }
    
    string comment = "EA_Bot_v1.2";
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
        OrderTask task;
        task.type = type; task.qty = lot; task.price = price; task.sl = sl; task.tp = tp;
        task.hash = hash; task.timestamp = GetTickCount(); task.retry_count = 0;
        g_retry_queue.Push(task);
        UpdateHealth(false);
        return false;
    }
}

// =================================================================
// HELPER FUNCTIONS & QUEUE
// =================================================================
bool IsTradingTimeOptimized() {
    MqlDateTime now;
    TimeCurrent(now);
    if(now.day_of_week == 6 || now.day_of_week == 0) return false;
    int current_hour = now.hour;
    if(InpStartHour <= InpEndHour) return (current_hour >= InpStartHour && current_hour < InpEndHour);
    else return (current_hour >= InpStartHour || current_hour < InpEndHour);
}

bool CheckFridayClose()
{
    if(!InpCloseFriday) return false;
    MqlDateTime now;
    TimeCurrent(now);
    if(now.day_of_week != 5 || now.hour < InpFridayHour) return false;

    int total = PositionsTotal();
    if (total == 0) return false;

    for(int i = total - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol) {
                 trade.PositionClose(ticket);
            }
        }
    }
    return (CountOpenPositions() > 0); 
}

void ProcessRetryQueue()
{
    int queue_size = g_retry_queue.Count();
    int processed = 0;
    while(processed < queue_size && processed < 5) {
        OrderTask task;
        if(!g_retry_queue.Pop(task)) break;
        
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

bool IsSidewaysAuto() 
{ 
    int p = (_Period == PERIOD_M1) ? 1440 : 100; 
    double a[]; 
    ArraySetAsSeries(a, true); 
    if(CopyBuffer(handleATR_Filter, 0, 1, p, a) < p) return false; 
    
    double s = 0;
    for(int i = 0; i < p; i++) s += a[i];
    double avg = s / p;
    
    return (a[0] < (avg * InpATRThreshold)); 
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
            Print("Alert: Circuit Breaker Activated!");
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
