//+------------------------------------------------------------------+
//|            EA Bot Version 1.0.mq5                                   |
//|      Version 1: Anti-Exhaustion (Stoch Filter Added)           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Institutional Code"
#property link      "https://www.mql5.com"
#property version   "1.0"  // Diubah dari "3.6" untuk kompatibilitas Market
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

CTrade trade;
CPositionInfo positionInfo;
CHistoryOrderInfo historyOrderInfo;

// =================================================================
// PARAMETER INPUT - DIPERBAIKI
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

input group "=== SURVIVOR STRATEGY SELECTOR ==="
input bool     InpUseStratMA        = true;     // 1. Trend Filter (diperbaiki nama)
input bool     InpUseStratADX       = true;     // 2. Strength Filter
input bool     InpUseStratRSI       = true;     // 3. Momentum Filter
input bool     InpUseStratStoch     = true;     // 4. ANTI-EXHAUSTION FILTER

input group "=== STRATEGY PARAMETERS ==="
input int      InpMAPeriod          = 14;       
input int      InpADXPeriod         = 14;       
input double   InpADXThreshold      = 20.0;     
input int      InpRSIPeriod         = 14;       

// Parameter Stochastic
input int      InpStochK            = 8;        // K Period
input int      InpStochD            = 3;        // D Period
input int      InpStochSlowing      = 3;        // Slowing
input int      InpStochUpper        = 80;       // Batas Atas
input int      InpStochLower        = 20;       // Batas Bawah

input group "=== RISK MANAGEMENT ==="
input int      InpStopLoss          = 6500;     
input int      InpTakeProfit        = 12000;    
input bool     InpUseTrailingStop   = true;     
input int      InpTrailingStart     = 300;      
input int      InpTrailingDist      = 300;      
input int      InpTrailingStep      = 50;       

input group "=== SYSTEM SAFETY ==="
input bool     InpUseVolFilter      = false;    
input int      InpATRPeriod         = 14;       
input int      InpMaxSpread         = 500;      
input int      InpSlippage          = 50;       
input bool     InpEnableDebug       = true;     // Debug Mode

// =================================================================
// GLOBAL VARIABLES - DIPERBAIKI
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
        m_head = 0; 
        m_tail = 0; 
        m_count = 0; 
    }
    
    bool Push(OrderTask &item) { 
        if(m_count >= m_capacity) { 
            OrderTask d; 
            Pop(d); 
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

// Deklarasi handles yang benar
int      handleMA = INVALID_HANDLE;      // Diperbaiki nama variabel
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

// Array untuk menyimpan ticket yang gagal ditutup
ulong    g_failed_close_tickets[];

// =================================================================
// INITIALIZATION - DIPERBAIKI
// =================================================================
int OnInit()
{
   if(InpMagicNum <= 0) {
      Print("Error: Magic number must be > 0");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_retry_queue.Init(50); 
   g_verify_queue.Init(100);
   
   if(!RefreshCache()) {
      Print("Error: Failed to refresh cache");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   // --- Init Indicators ---
   if(InpUseStratMA) {
      handleMA = iMA(_Symbol, _Period, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
      if(handleMA == INVALID_HANDLE) {
         Print("Error: MA Handle");
         return(INIT_FAILED);
      }
   }
   
   if(InpUseStratADX) {
      handleADX = iADX(_Symbol, _Period, InpADXPeriod);
      if(handleADX == INVALID_HANDLE) {
         Print("Error: ADX Handle");
         return(INIT_FAILED);
      }
   }
   
   if(InpUseStratRSI) {
      handleRSI = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
      if(handleRSI == INVALID_HANDLE) {
         Print("Error: RSI Handle");
         return(INIT_FAILED);
      }
   }
   
   // Init Stochastic
   if(InpUseStratStoch) {
      handleStoch = iStochastic(_Symbol, _Period, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);
      if(handleStoch == INVALID_HANDLE) { 
         Print("Error: Stoch Handle"); 
         return(INIT_FAILED); 
      }
   }
   
   handleATR = iATR(_Symbol, _Period, InpATRPeriod);
   if(handleATR == INVALID_HANDLE) {
      Print("Error: ATR Handle");
      return(INIT_FAILED);
   }

   // Inisialisasi array failed close tickets
   ArrayResize(g_failed_close_tickets, 0);

   Print("=== XAUUSD TRAILING v3.6 STARTED ===");
   Print("Feature: Anti-Exhaustion Filter (Stochastic) Added");
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Release semua handles yang valid
   if(handleMA != INVALID_HANDLE) IndicatorRelease(handleMA);
   if(handleADX != INVALID_HANDLE) IndicatorRelease(handleADX);
   if(handleRSI != INVALID_HANDLE) IndicatorRelease(handleRSI);
   if(handleATR != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleStoch != INVALID_HANDLE) IndicatorRelease(handleStoch);
}

// =================================================================
// ON TICK - DIPERBAIKI
// =================================================================
void OnTick()
{
   // Proses queue terlebih dahulu
   ProcessVerifyQueue(); 
   ProcessRetryQueue();

   // Cek circuit breaker
   if(g_is_broken) {
      if(GetTickCount() - g_broken_time > 300000) { 
         g_is_broken = false; 
         g_health.consecutive_fails = 0; 
      }
      return;
   }

   // Refresh cache dan cek trading allowed
   if(!RefreshCache()) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;

   // Cek penutupan Jumat
   if(CheckFridayClose()) {
      ManageOpenPositions(); // Tetap manage trailing
      return; // Tidak buka posisi baru
   }
   
   // Manage posisi terbuka
   ManageOpenPositions();

   // Cek bar baru
   if(!IsNewBar()) return;
   
   // Filter trading
   if(InpUseTimeFilter && !IsTradingTimeOptimized()) return;
   if(CountOpenPositions() >= InpMaxPositions) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;
   if(InpUseVolFilter && IsSidewaysAuto()) return;

   // Proses sinyal
   ProcessSignal();
}

// =================================================================
// FUNGSI UTAMA - DIPERBAIKI
// =================================================================

// 1. IsTradingTimeOptimized() - FIXED
bool IsTradingTimeOptimized()
{
    MqlDateTime now;
    TimeCurrent(now);
    
    // Cek hari weekend
    if(now.day_of_week == 6 || now.day_of_week == 0) // Sabtu atau Minggu
        return false;
    
    int current_hour = now.hour;
    
    // Logika waktu trading
    if(InpStartHour <= InpEndHour) {
        // Trading dalam hari yang sama (contoh: 08:00 - 18:00)
        return (current_hour >= InpStartHour && current_hour < InpEndHour);
    } else {
        // Trading melewati tengah malam (contoh: 22:00 - 02:00)
        return (current_hour >= InpStartHour || current_hour < InpEndHour);
    }
}

// 2. ProcessSignal() - FIXED
void ProcessSignal()
{
   int signal = GetEntrySignal();
   if(signal == 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ENUM_ORDER_TYPE type = (signal == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price = (signal == 1) ? ask : bid;
   
   double sl = 0, tp = 0;
   if(InpStopLoss > 0) {
      sl = (signal == 1) ? price - (InpStopLoss * cache_point) : price + (InpStopLoss * cache_point);
   }
   if(InpTakeProfit > 0) {
      tp = (signal == 1) ? price + (InpTakeProfit * cache_point) : price - (InpTakeProfit * cache_point);
   }

   string hash = StringFormat("%d_%.5f_%d", type, price, TimeCurrent());
   if(InpEnableDebug) Print("EXECUTION: Signal Validated. Sending Order...");
   OpenOrderAsync(type, InpFixedLots, price, sl, tp, hash);
}

// 3. GetEntrySignal() - FIXED dengan nama variabel yang benar
int GetEntrySignal()
{
   if(!InpUseStratMA && !InpUseStratADX && !InpUseStratRSI && !InpUseStratStoch) return 0;

   // Inisialisasi
   bool doBuy  = true;
   bool doSell = true;
   
   double close1 = iClose(_Symbol, _Period, 1);
   
   // --- LOGIC A: MA TREND ---
   if(InpUseStratMA) {
      double ma[1];
      if(CopyBuffer(handleMA, 0, 1, 1, ma) < 1) return 0; 
      
      if(close1 < ma[0]) doBuy = false; 
      if(close1 > ma[0]) doSell = false;
      
      if(InpEnableDebug) {
         if(!doBuy && doSell) Print("DEBUG: MA Only supports SELL");
         if(!doSell && doBuy) Print("DEBUG: MA Only supports BUY");
      }
   }

   // --- LOGIC B: ADX CROSS ---
   if(InpUseStratADX) {
      double adx[1], plus[1], minus[1];
      if(CopyBuffer(handleADX, 0, 1, 1, adx) < 1 || 
         CopyBuffer(handleADX, 1, 1, 1, plus) < 1 || 
         CopyBuffer(handleADX, 2, 1, 1, minus) < 1) return 0;

      if(adx[0] < InpADXThreshold) { 
         doBuy = false; 
         doSell = false; // Trend lemah
      } else {
         if(plus[0] < minus[0]) doBuy = false;
         if(minus[0] < plus[0]) doSell = false;
      }
   }

   // --- LOGIC C: RSI MOMENTUM ---
   if(InpUseStratRSI) {
      double rsi[1];
      if(CopyBuffer(handleRSI, 0, 1, 1, rsi) < 1) return 0;
      
      if(rsi[0] < 50.0) doBuy = false;
      if(rsi[0] > 50.0) doSell = false;
   }

   // --- LOGIC D: STOCHASTIC ANTI-REVERSAL ---
   if(InpUseStratStoch) {
      double stoch_main[1];
      if(CopyBuffer(handleStoch, 0, 1, 1, stoch_main) < 1) return 0;
      
      double stochVal = stoch_main[0];
      
      // Overbought: blokir BUY
      if(stochVal > InpStochUpper) {
         if(doBuy) {
            doBuy = false;
            if(InpEnableDebug) Print("DEBUG: BUY Blocked by Stochastic (> ", InpStochUpper, ") - Overbought Risk");
         }
      }
      
      // Oversold: blokir SELL
      if(stochVal < InpStochLower) {
         if(doSell) {
            doSell = false;
            if(InpEnableDebug) Print("DEBUG: SELL Blocked by Stochastic (< ", InpStochLower, ") - Oversold Risk");
         }
      }
   }

   // Keputusan final
   if(doBuy && !doSell) return 1;
   if(doSell && !doBuy) return -1;
   
   return 0; 
}

// 4. OpenOrderAsync() - FIXED
bool OpenOrderAsync(ENUM_ORDER_TYPE type, double lot, double price, double sl, double tp, string hash)
{
    // Validasi lot
    if(lot <= 0) {
        Print("Error: Invalid lot size: ", lot);
        return false;
    }
    
    // Cek margin
    double margin_required = 0.0;
    if(!OrderCalcMargin(type, _Symbol, lot, price, margin_required)) {
        Print("Error calculating margin for ", EnumToString(type), 
              ", Lot: ", lot, ", Price: ", price, ", Error: ", GetLastError());
        return false;
    }
    
    double free_margin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    if(free_margin < margin_required) {
        if(InpEnableDebug) {
            Print("Margin check failed. Required: ", margin_required, 
                  ", Free: ", free_margin, ", Symbol: ", _Symbol);
        }
        return false;
    }
    
    // Eksekusi order
    bool result = false;
    string comment = StringFormat("XAU_Trail_v3.6|%s|%s", 
                    EnumToString(type), TimeToString(TimeCurrent(), TIME_MINUTES));
    
    if(type == ORDER_TYPE_BUY) {
        result = trade.Buy(lot, _Symbol, price, sl, tp, comment);
    } 
    else if(type == ORDER_TYPE_SELL) {
        result = trade.Sell(lot, _Symbol, price, sl, tp, comment);
    }
    
    // Handle hasil
    if(result && trade.ResultRetcode() == TRADE_RETCODE_DONE) {
        OrderTask task;
        task.ticket = trade.ResultOrder();
        task.type = type;
        task.hash = hash;
        task.timestamp = GetTickCount();
        g_verify_queue.Push(task);
        UpdateHealth(true);
        
        if(InpEnableDebug) {
            Print("Order SUCCESS: ", EnumToString(type), 
                  ", Ticket: ", task.ticket, 
                  ", Price: ", price, 
                  ", Lot: ", lot);
        }
        return true;
    } 
    else {
        // Masukkan ke retry queue
        OrderTask task;
        task.type = type;
        task.qty = lot;
        task.price = price;
        task.sl = sl;
        task.tp = tp;
        task.hash = hash;
        task.timestamp = GetTickCount();
        task.retry_count = 0;
        
        g_retry_queue.Push(task);
        UpdateHealth(false);
        
        if(InpEnableDebug) {
            Print("Order FAILED: ", EnumToString(type), 
                  ", Retcode: ", trade.ResultRetcode(), 
                  ", Error: ", trade.ResultRetcodeDescription(),
                  ", Added to retry queue");
        }
        return false;
    }
}

// 5. CheckFridayClose() - FIXED
bool CheckFridayClose()
{
    if(!InpCloseFriday) 
        return false;
    
    MqlDateTime now;
    TimeCurrent(now);
    
    // Hanya proses pada hari Jumat setelah jam yang ditentukan
    if(now.day_of_week != 5 || now.hour < InpFridayHour) 
        return false;
    
    int positions_closed = 0;
    int positions_failed = 0;
    
    // Tutup semua posisi yang dibuka oleh EA ini
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        
        if(PositionSelectByTicket(ticket)) {
            // Cek apakah posisi milik EA ini
            if(PositionGetInteger(POSITION_MAGIC) != InpMagicNum || 
               PositionGetString(POSITION_SYMBOL) != _Symbol) {
                continue;
            }
            
            // Coba tutup posisi
            if(trade.PositionClose(ticket)) {
                positions_closed++;
                if(InpEnableDebug) {
                    Print("Friday Close: Position closed. Ticket: ", ticket, 
                          ", P/L: ", PositionGetDouble(POSITION_PROFIT));
                }
            } else {
                positions_failed++;
                
                // Simpan ticket yang gagal
                int size = ArraySize(g_failed_close_tickets);
                ArrayResize(g_failed_close_tickets, size + 1);
                g_failed_close_tickets[size] = ticket;
                
                if(InpEnableDebug) {
                    Print("Friday Close FAILED: Ticket ", ticket, 
                          ", Error: ", GetLastError());
                }
            }
        }
    }
    
    // Coba tutup kembali yang gagal
    for(int i = ArraySize(g_failed_close_tickets) - 1; i >= 0; i--) {
        ulong ticket = g_failed_close_tickets[i];
        if(PositionSelectByTicket(ticket)) {
            if(trade.PositionClose(ticket)) {
                // Hapus dari array
                ArrayRemove(g_failed_close_tickets, i, 1);
            }
        } else {
            // Posisi sudah tidak ada, hapus dari array
            ArrayRemove(g_failed_close_tickets, i, 1);
        }
    }
    
    // Log hasil
    if(InpEnableDebug && (positions_closed > 0 || positions_failed > 0)) {
        Print("Friday Close Summary: Closed ", positions_closed, 
              ", Failed ", positions_failed);
    }
    
    // Return true jika masih ada posisi terbuka
    return (CountOpenPositions() > 0);
}

// 6. ProcessRetryQueue() - FIXED
void ProcessRetryQueue()
{
    int queue_size = g_retry_queue.Count();
    int processed = 0;
    
    while(processed < queue_size && processed < 5) {
        OrderTask task;
        if(!g_retry_queue.Pop(task)) break;
        
        ulong backoff_ms = 1000 * (1 << MathMin(task.retry_count, 3));
        
        if(GetTickCount() - task.timestamp >= backoff_ms) {
            // Coba eksekusi ulang
            if(!OpenOrderAsync(task.type, task.qty, task.price, task.sl, task.tp, task.hash)) {
                task.retry_count++;
                task.timestamp = GetTickCount();
                if(task.retry_count <= 3) {
                    g_retry_queue.Push(task);
                }
            }
        } else {
            g_retry_queue.Push(task);
        }
        
        processed++;
    }
}

// =================================================================
// FUNGSI PENDUKUNG - DIPERBAIKI
// =================================================================

bool IsSidewaysAuto() 
{ 
    int p = (_Period == PERIOD_M1) ? 1440 : 100; 
    double a[]; 
    ArraySetAsSeries(a, true); 
    if(CopyBuffer(handleATR, 0, 1, p, a) < p) return false; 
    double s = 0;
    for(int i = 0; i < p; i++) s += a[i];
    double avg = s / p;
    return (a[0] < (avg * 0.7)); 
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
        if(PositionSelectByTicket(ticket) && 
           PositionGetInteger(POSITION_MAGIC) == InpMagicNum && 
           PositionGetString(POSITION_SYMBOL) == _Symbol) { 
            
            double sl = PositionGetDouble(POSITION_SL);
            double cr = PositionGetDouble(POSITION_PRICE_CURRENT);
            double op = PositionGetDouble(POSITION_PRICE_OPEN);
            double nsl = sl;
            bool modified = false;
            
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) { 
                if(cr - op > st) { 
                    double target_sl = cr - dt; 
                    if(target_sl > sl + sp) { 
                        nsl = target_sl; 
                        modified = true; 
                    } 
                } 
            } else { 
                if(op - cr > st) { 
                    double target_sl = cr + dt; 
                    if(target_sl < sl - sp || sl == 0) { 
                        nsl = target_sl; 
                        modified = true; 
                    } 
                } 
            } 
            
            if(modified) {
                trade.PositionModify(ticket, NormalizeDouble(nsl, _Digits), PositionGetDouble(POSITION_TP));
            }
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
        if(ticket > 0 && 
           PositionGetInteger(POSITION_MAGIC) == InpMagicNum && 
           PositionGetString(POSITION_SYMBOL) == _Symbol) {
            count++; 
        }
    }
    return count; 
}

//+------------------------------------------------------------------+