//+------------------------------------------------------------------+
//|            EA VWAP Institutional Scalper v2.4 (Enhanced)         |
//|            Based on EA Bot Version 2.3                           |
//|            Improvements: Validation, Logging, Alerts, News Guard |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Institutional Code (Enhanced)"
#property link      "https://www.mql5.com"
#property version   "2.4"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

CTrade trade;
CPositionInfo positionInfo;
CHistoryOrderInfo historyOrderInfo;

// =================================================================
// PARAMETER INPUT
// =================================================================
input group "=== CORE TRADING ==="
input int      InpMagicNum          = 889911;
input int      InpMaxPositions      = 1;
input double   InpFixedLots         = 0.05; 

input group "=== VWAP STRATEGY ==="
input double   InpVWAPTolerance     = 1000; // Toleransi jarak (points)
input double   InpVolMultiplier     = 1.3;  // Min. 1.1
input int      InpVolPeriod         = 20;   

input group "=== RISK MANAGEMENT ==="
input int      InpStopLoss          = 3000; 
input int      InpTakeProfit        = 8000; 
input bool     InpUseTrailingStop   = true;
input int      InpTrailingStart     = 1500; 
input int      InpTrailingDist      = 500;  
input int      InpTrailingStep      = 100;

input group "=== TIME & NEWS FILTER ==="
input bool     InpUseTimeFilter     = true;
input int      InpStartHour         = 1;    
input int      InpEndHour           = 23;   
input bool     InpCloseFriday       = true;
input int      InpFridayHour        = 20;
// News Guard Manual (Blokir jam tertentu, misal saat NFP)
input bool     InpUseNewsGuard      = false; 
input int      InpNewsStartHour     = 15;   // Jam mulai blokir
input int      InpNewsEndHour       = 17;   // Jam selesai blokir

input group "=== SYSTEM SAFETY & LOGS ==="
input int      InpMaxSpread         = 500;  
input int      InpSlippage          = 100;
input bool     InpEnableDebug       = true; 
input bool     InpUseFileLogging    = true; // Simpan log ke file
input bool     InpUseMobileAlerts   = true; // Kirim notif ke HP saat error kritis

// =================================================================
// GLOBAL VARIABLES
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
        if(m_count >= m_capacity) { OrderTask d; Pop(d); } 
        m_buffer[m_tail] = item; 
        m_tail = (m_tail + 1) % m_capacity;
        m_count++; return true; 
    }
    bool Pop(OrderTask &item) { 
        if(m_count <= 0) return false;
        item = m_buffer[m_head]; 
        m_head = (m_head + 1) % m_capacity; 
        m_count--; return true;
    }
    int Count() { return m_count; }
};

bool          g_is_broken = false;
ulong         g_broken_time = 0;
HealthMetrics g_health = {0, 0, 0};
string        g_log_filename;

RingBufferOrderTask g_retry_queue;
RingBufferOrderTask g_verify_queue;
double        cache_point;

// Forward declaration
double CalculateIntradayVWAP(int shift);
void ShowDashboard();
void LogSystem(string msg, bool is_error = false);

// =================================================================
// INITIALIZATION & VALIDATION
// =================================================================
int OnInit()
{
   // 1. VALIDASI PARAMETER (Safety Check)
   if(InpMagicNum <= 0) {
       Alert("Error: Magic Number invalid!"); return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpVolMultiplier < 1.0) {
       Alert("Error: Volume Multiplier harus >= 1.0"); return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpFixedLots <= 0) {
       Alert("Error: Lot size invalid!"); return(INIT_PARAMETERS_INCORRECT);
   }

   // 2. Setup Nama File Log (Unik per Simbol & Magic)
   g_log_filename = "Log_VWAP_" + _Symbol + "_" + IntegerToString(InpMagicNum) + ".txt";

   // 3. Init Struktur Data
   g_retry_queue.Init(50); 
   g_verify_queue.Init(100);
   
   if(!RefreshCache()) return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   LogSystem("=== SYSTEM STARTED v2.4 (Enhanced) ===");
   Print("=== VWAP SCALPER XAUUSD V2.4 STARTED ===");
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
   LogSystem("=== SYSTEM STOPPED ===");
}

// =================================================================
// ON TICK
// =================================================================
void OnTick()
{
   if(!RefreshCache()) return;

   // 1. SAFETY: Manage Positions (Always Run)
   ManageOpenPositions();

   // 2. Friday Close Logic
   if(CheckFridayClose()) { ShowDashboard(); return; }
   
   // 3. Process Queues
   ProcessVerifyQueue(); 
   ProcessRetryQueue();

   // 4. Circuit Breaker Handler
   if(g_is_broken) {
      if(GetTickCount() - g_broken_time > 300000) { // 5 menit
         g_is_broken = false;
         g_health.consecutive_fails = 0; 
         LogSystem("System Recovered from Circuit Breaker.");
      }
      ShowDashboard();
      return;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;

   ShowDashboard();

   // 5. Entry Filters
   if(!IsNewBar()) return;
   if(InpUseTimeFilter && !IsTradingTimeOptimized()) return;
   if(InpUseNewsGuard && IsNewsTime()) return; // Filter News Manual
   if(CountOpenPositions() >= InpMaxPositions) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;

   // 6. Signal Processing
   ProcessSignal();
}

// =================================================================
// CORE STRATEGY
// =================================================================
double CalculateIntradayVWAP(int shift)
{
    datetime time_curr = iTime(_Symbol, _Period, shift);
    datetime time_start = time_curr - (time_curr % 86400); 
    
    int start_bar = iBarShift(_Symbol, _Period, time_start);
    int curr_bar = iBarShift(_Symbol, _Period, time_curr);
    
    double sum_pv = 0.0;
    double sum_vol = 0.0;
    
    // Limit loop untuk efisiensi
    if(start_bar - curr_bar > 1440) start_bar = curr_bar + 1440; 

    for(int i = start_bar; i >= curr_bar; i--) {
        double price = (iHigh(_Symbol, _Period, i) + iLow(_Symbol, _Period, i) + iClose(_Symbol, _Period, i)) / 3.0;
        long vol = iVolume(_Symbol, _Period, i); 
        if(vol > 0) {
            sum_pv += price * (double)vol;
            sum_vol += (double)vol;
        }
    }
    return (sum_vol == 0) ? 0 : sum_pv / sum_vol;
}

bool IsVolumeSpike(int shift)
{
    long curr_vol = iVolume(_Symbol, _Period, shift);
    double sum_vol = 0;
    for(int i = shift + 1; i <= shift + InpVolPeriod; i++) {
        sum_vol += (double)iVolume(_Symbol, _Period, i);
    }
    double avg_vol = sum_vol / InpVolPeriod;
    return (avg_vol > 0 && (double)curr_vol > (avg_vol * InpVolMultiplier));
}

void ProcessSignal()
{
   int shift = 1;
   double vwap = CalculateIntradayVWAP(shift);
   if(vwap == 0) return;
   
   double close = iClose(_Symbol, _Period, shift);
   double high = iHigh(_Symbol, _Period, shift);
   double low = iLow(_Symbol, _Period, shift);
   double tol = InpVWAPTolerance * cache_point;
   
   int signal = 0;
   
   // Logic Buy (Rejection Low at VWAP)
   if(low <= (vwap + tol) && close > vwap) {
       if(IsVolumeSpike(shift)) signal = 1;
   }
   // Logic Sell (Rejection High at VWAP)
   else if(high >= (vwap - tol) && close < vwap) {
       if(IsVolumeSpike(shift)) signal = -1;
   }
   
   if(signal == 0) return;
   
   double price = (signal == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ENUM_ORDER_TYPE type = (signal == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   double sl = (InpStopLoss > 0) ? ((signal == 1) ? price - (InpStopLoss*cache_point) : price + (InpStopLoss*cache_point)) : 0;
   double tp = (InpTakeProfit > 0) ? ((signal == 1) ? price + (InpTakeProfit*cache_point) : price - (InpTakeProfit*cache_point)) : 0;

   string hash = StringFormat("%d_%.5f_%d", type, price, TimeCurrent());
   OpenOrderAsync(type, InpFixedLots, price, sl, tp, hash);
}

// =================================================================
// UTILITIES (LOGGING & ALERTS)
// =================================================================
void LogSystem(string msg, bool is_error = false)
{
    if(!InpUseFileLogging) return;
    
    int handle = FileOpen(g_log_filename, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        string time = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
        string type = is_error ? "[ERROR]" : "[INFO]";
        FileWrite(handle, time + " " + type + " " + msg);
        FileClose(handle);
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
        
        string err_msg = "Order Failed. Retry: " + IntegerToString(g_health.consecutive_fails);
        LogSystem(err_msg, true);
        
        if(g_health.consecutive_fails > 5) { 
            g_is_broken = true; 
            g_broken_time = GetTickCount();
            
            string crit_msg = "CRITICAL: Circuit Breaker Activated on " + _Symbol + ". Trading Paused.";
            LogSystem(crit_msg, true);
            Print(crit_msg);
            
            if(InpUseMobileAlerts) SendNotification(crit_msg);
        }
    } 
}

// =================================================================
// EXECUTION & SAFETY
// =================================================================
bool OpenOrderAsync(ENUM_ORDER_TYPE type, double lot, double price, double sl, double tp, string hash)
{
    if(lot <= 0) return false;
    double margin_required = 0.0;
    if(!OrderCalcMargin(type, _Symbol, lot, price, margin_required)) return false;
    if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required) return false;
    
    bool result = false;
    string comment = "VWAP_v2.4";
    
    if(type == ORDER_TYPE_BUY) result = trade.Buy(lot, _Symbol, price, sl, tp, comment);
    else if(type == ORDER_TYPE_SELL) result = trade.Sell(lot, _Symbol, price, sl, tp, comment);
    
    if(result && trade.ResultRetcode() == TRADE_RETCODE_DONE) {
        OrderTask task;
        task.ticket = trade.ResultOrder();
        task.type = type; task.hash = hash; task.timestamp = GetTickCount();
        g_verify_queue.Push(task);
        UpdateHealth(true);
        LogSystem("Order Executed: " + (string)task.ticket);
        return true;
    } else {
        OrderTask task;
        task.type = type; task.qty = lot;
        task.price = price; task.sl = sl; task.tp = tp;
        task.hash = hash; task.timestamp = GetTickCount(); task.retry_count = 0;
        g_retry_queue.Push(task);
        UpdateHealth(false);
        return false;
    }
}

void ProcessRetryQueue()
{
    int processed = 0;
    while(processed < 3 && g_retry_queue.Count() > 0) { 
        OrderTask task;
        if(!g_retry_queue.Pop(task)) break;
        
        ulong backoff = 1000 * (1 << MathMin(task.retry_count, 3));
        if(GetTickCount() - task.timestamp >= backoff) {
            
            // Refresh Price for Retry
            double new_price = (task.type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double new_sl = (InpStopLoss > 0) ? ((task.type == ORDER_TYPE_BUY) ? new_price - (InpStopLoss*cache_point) : new_price + (InpStopLoss*cache_point)) : 0;
            double new_tp = (InpTakeProfit > 0) ? ((task.type == ORDER_TYPE_BUY) ? new_price + (InpTakeProfit*cache_point) : new_price - (InpTakeProfit*cache_point)) : 0;

            if(!OpenOrderAsync(task.type, task.qty, new_price, new_sl, new_tp, task.hash)) {
                task.retry_count++;
                task.timestamp = GetTickCount();
                if(task.retry_count <= 3) g_retry_queue.Push(task);
            }
        } else {
            g_retry_queue.Push(task);
        }
        processed++;
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
        if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) { 
            double sl = PositionGetDouble(POSITION_SL);
            double cr = PositionGetDouble(POSITION_PRICE_CURRENT);
            double op = PositionGetDouble(POSITION_PRICE_OPEN);
            double nsl = sl;
            bool modified = false;

            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) { 
                if(cr - op > st) { 
                    double target = cr - dt;
                    if(target > sl + sp) { nsl = target; modified = true; } 
                } 
            } else { 
                if(op - cr > st) { 
                    double target = cr + dt;
                    if(target < sl - sp || sl == 0) { nsl = target; modified = true; } 
                } 
            } 
            if(modified) {
                if(trade.PositionModify(ticket, NormalizeDouble(nsl, _Digits), PositionGetDouble(POSITION_TP)))
                    LogSystem("Trailing Stop Updated: " + (string)ticket);
            }
        } 
    } 
}

// =================================================================
// HELPERS
// =================================================================
void ShowDashboard() {
    if(!InpEnableDebug) { Comment(""); return; }
    if(SeriesInfoInteger(_Symbol, _Period, SERIES_BARS_COUNT) < InpVolPeriod) return;

    double vwap = CalculateIntradayVWAP(1);
    string sys_status = g_is_broken ? "[!] PAUSED" : "[ON] RUNNING";
    string news_status = (InpUseNewsGuard && IsNewsTime()) ? "[!] NEWS BLOCK ACTIVE" : "No News Filter";

    string text = "=== VWAP INSTITUTIONAL SCALPER v2.4 ===\n";
    text += "Status        : " + sys_status + "\n";
    text += "News Filter   : " + news_status + "\n";
    text += "Positions     : " + IntegerToString(CountOpenPositions()) + "\n";
    text += "Failures      : " + IntegerToString(g_health.consecutive_fails) + "/5\n";
    text += "VWAP          : " + DoubleToString(vwap, _Digits) + "\n";
    Comment(text);
}

bool IsTradingTimeOptimized() {
    MqlDateTime now; TimeCurrent(now);
    if(now.day_of_week == 6 || now.day_of_week == 0) return false;
    int ch = now.hour;
    if(InpStartHour <= InpEndHour) return (ch >= InpStartHour && ch < InpEndHour);
    else return (ch >= InpStartHour || ch < InpEndHour);
}

bool IsNewsTime() {
    if(!InpUseNewsGuard) return false;
    MqlDateTime now; TimeCurrent(now);
    return (now.hour >= InpNewsStartHour && now.hour < InpNewsEndHour);
}

bool CheckFridayClose() {
    if(!InpCloseFriday) return false;
    MqlDateTime now; TimeCurrent(now);
    if(now.day_of_week != 5 || now.hour < InpFridayHour) return false;
    
    bool has_pos = false;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
            has_pos = true;
            trade.PositionClose(ticket);
            LogSystem("Friday Force Close: " + (string)ticket);
        }
    }
    return has_pos;
}

void ProcessVerifyQueue() { 
    int x = 0;
    while(x < 10 && g_verify_queue.Count() > 0) { 
        OrderTask t; 
        if(!g_verify_queue.Pop(t)) break;
        if(GetTickCount() - t.timestamp < 10000 && !PositionSelectByTicket(t.ticket)) 
            g_verify_queue.Push(t);
        x++; 
    } 
}

bool RefreshCache() { 
    cache_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); 
    return (cache_point > 0);
}

bool IsNewBar() { 
    static datetime last_bar_time = 0;
    datetime current_bar_time = iTime(_Symbol, _Period, 0);
    if(last_bar_time != current_bar_time) { 
        last_bar_time = current_bar_time; 
        return true; 
    } 
    return false;
}

int CountOpenPositions() { 
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum) count++;
    }
    return count; 
}
