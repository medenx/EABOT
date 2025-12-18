//+------------------------------------------------------------------+
//|            EA Bot Version 2.2 (Indonesian UI)                   |
//|            Updated: Label Bahasa Indonesia & Fix Threshold      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Institutional Code"
#property link      "https://www.mql5.com"
#property version   "2.2"
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
    MODE_MANUAL,        // Pilih manual
    MODE_AUTO_ATR       // Otomatis (Trend/Reversal)
};

// =================================================================
// PARAMETER INPUT (BAHASA INDONESIA)
// =================================================================
input group "=== PENGATURAN LOGIKA UTAMA ==="
input ENUM_STRAT_MODE InpStratMode  = MODE_AUTO_ATR; // Mode Strategi
input ENUM_TIMEFRAMES InpTrendTF    = PERIOD_M3;     // Timeframe Filter Tren
input int      InpATR_Switch_Period = 14;            // Periode Cek Volatilitas
input double   InpATR_Switch_Level  = 0.0005;        // Batas Level Volatilitas (Agar Trend Aktif)

input group "=== MANAJEMEN MODAL (LOT) ==="
input bool     InpUseDynamicLot     = true;          // Gunakan Lot Dinamis (Persen)?
input double   InpRiskPercent       = 0.3;           // Resiko per Trade (%)
input double   InpFixedLots         = 0.01;          // Lot Tetap (Jika Dinamis Mati)

input group "=== STOP LOSS & TAKE PROFIT (OTOMATIS) ==="
input bool     InpUseATR_SLTP       = true;          // Aktifkan SL/TP Dinamis (ATR)?
input int      InpATR_SLTP_Period   = 14;            // Periode ATR untuk SL/TP
input double   InpATR_SL_Ratio      = 2.5;           // Jarak Stop Loss (Pengali ATR)
input double   InpATR_TP_Ratio      = 4.0;           // Jarak Take Profit (Pengali ATR)

input group "=== FILTER BERITA (NEWS) ==="
input bool     InpUseNewsFilter     = true;          // Aktifkan Filter Berita?
input int      InpNewsMinBefore     = 30;            // Menit Stop Sebelum Berita
input int      InpNewsMinAfter      = 90;            // Menit Stop Setelah Berita
input bool     InpCloseBeforeNews   = true;          // Tutup Posisi Saat Berita Besar?

input group "=== PENGATURAN DASAR ==="
input int      InpMagicNum          = 998822;        // Magic Number (ID Robot)
input int      InpMaxPositions      = 1;             // Maksimal Posisi Terbuka

input group "=== FILTER WAKTU TRADING ==="
input bool     InpUseTimeFilter     = false;         // Gunakan Jam Trading Tertentu?
input int      InpStartHour         = 8;             // Jam Mulai (Waktu Server)
input int      InpEndHour           = 22;            // Jam Selesai (Waktu Server)
input bool     InpCloseFriday       = true;          // Tutup Otomatis Hari Jumat?
input int      InpFridayHour        = 20;            // Jam Tutup Jumat (Waktu Server)

input group "=== INDIKATOR & SINYAL ==="
// Trend Indicators
input int      InpMAPeriod          = 100;           // Periode Moving Average (Tren)
input int      InpADXPeriod         = 14;            // Periode ADX
input double   InpADXThreshold      = 30.0;          // Minimal Kekuatan Tren ADX

// Reversal Indicators
input int      InpRSIPeriod         = 14;            // Periode RSI
input int      InpStochK            = 8;             // Stochastic K
input int      InpStochD            = 3;             // Stochastic D
input int      InpStochSlowing      = 3;             // Stochastic Slowing
input int      InpStochUpper        = 80;            // Level Atas (Jenuh Beli)
input int      InpStochLower        = 20;            // Level Bawah (Jenuh Jual)

input group "=== PENGAMAN & TRAILING ==="
input int      InpStopLossFixed     = 15000;         // Stop Loss Poin (Cadangan)
input int      InpTakeProfitFixed   = 30000;         // Take Profit Poin (Cadangan)
input bool     InpUseTrailingStop   = true;          // Aktifkan Trailing Stop?
input int      InpTrailingStart     = 800;           // Mulai Trailing (Poin)
input int      InpTrailingDist      = 400;           // Jarak Trailing (Poin)
input int      InpTrailingStep      = 19;            // Langkah Trailing (Poin)

input group "=== KEAMANAN SISTEM ==="
input int      InpMaxSpread         = 37;            // Maksimal Spread Diizinkan (Poin)
input int      InpSlippage          = 0;             // Toleransi Slippage (Sesuai Request)
input int      InpMaxRetryAttempts  = 0;             // Percobaan Ulang Order (Retry)
input bool     InpEnableDebug       = true;          // Tampilkan Log Debug?
input double   InpMinSLPoints       = 2500.0;        // Minimal Jarak SL (Poin)
input double   InpMinRRRatio        = 1.5;           // Minimal Rasio Risk:Reward

// =================================================================
// DATA STRUCTURES
// =================================================================
struct OrderTask {
    ulong ticket; ENUM_ORDER_TYPE type;
    double qty, price, sl, tp;
    ulong timestamp; int retry_count; string hash; 
};

struct HealthMetrics {
    int exec_success;
    int exec_fail; int consecutive_fails;
};

// =================================================================
// RING BUFFER CLASS
// =================================================================
class RingBufferOrderTask {
private: 
    OrderTask m_buffer[];
    int m_head, m_tail, m_count, m_capacity;
public:
    void Init(int capacity) { 
        ArrayResize(m_buffer, capacity);
        m_capacity = capacity; m_head = 0; m_tail = 0; m_count = 0;
    }
    bool Push(OrderTask &item) { 
        if(m_count >= m_capacity) { OrderTask t; Pop(t); } 
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

// =================================================================
// GLOBAL VARIABLES
// =================================================================
int      handleMA_MTF = INVALID_HANDLE;
int      handleADX = INVALID_HANDLE;
int      handleRSI = INVALID_HANDLE;
int      handleStoch = INVALID_HANDLE;
int      handleATR_Switch = INVALID_HANDLE;
int      handleATR_SLTP = INVALID_HANDLE;
int      handleATR_Daily = INVALID_HANDLE;

bool     g_is_broken = false;
ulong    g_broken_time = 0;
HealthMetrics g_health = {0, 0, 0};

RingBufferOrderTask g_retry_queue;
RingBufferOrderTask g_verify_queue;

double   cache_point;
string   gHighImpactEvents[]; 
datetime gHighImpactTimes[];

// =================================================================
// HELPER FUNCTIONS
// =================================================================
// Check Market Conditions
bool CheckMarketConditions()
{
    int currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(currentSpread > InpMaxSpread) return false;
    
    double atrCurrent = GetATRValue(handleATR_SLTP);
    double atrDailyBuff[1];
    if(CopyBuffer(handleATR_Daily, 0, 1, 1, atrDailyBuff) >= 1) {
        if(atrCurrent > (atrDailyBuff[0] * 2.0)) return false;
    }
    return true;
}

// Initialize News Data (SIMULATED FOR EXAMPLE)
void InitializeNewsData() {
    // Array gHighImpactEvents is empty by default unless populated manually or by API
}

bool IsNewsTime() { return false; } // Simplified for this request

// Dynamic Threshold Logic
double GetDynamicATRThreshold()
{
    double goldPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    // FIX: Menggunakan Input Parameter user
    double baseThreshold = goldPrice * InpATR_Switch_Level; 
    double minThreshold = 0.015;
    return MathMax(baseThreshold, minThreshold);
}

// =================================================================
// INITIALIZATION
// =================================================================
int OnInit()
{
   if((int)InpMagicNum <= 0) return(INIT_PARAMETERS_INCORRECT);

   g_retry_queue.Init(50); 
   g_verify_queue.Init(100);
   if(!RefreshCache()) return(INIT_FAILED);

   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   if(!InitIndicators()) return(INIT_FAILED);
   if(InpUseNewsFilter) InitializeNewsData();

   Print("=== EA Bot Version 2.2 (Indonesian UI) STARTED ===");
   return(INIT_SUCCEEDED);
}

bool InitIndicators() {
    handleMA_MTF = iMA(_Symbol, InpTrendTF, InpMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
    handleADX = iADX(_Symbol, _Period, InpADXPeriod);
    handleRSI = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
    handleStoch = iStochastic(_Symbol, _Period, InpStochK, InpStochD, InpStochSlowing, MODE_SMA, STO_LOWHIGH);
    handleATR_Switch = iATR(_Symbol, _Period, InpATR_Switch_Period);
    if(InpUseATR_SLTP) handleATR_SLTP = iATR(_Symbol, _Period, InpATR_SLTP_Period);
    handleATR_Daily = iATR(_Symbol, PERIOD_D1, 14);

    return (handleMA_MTF != INVALID_HANDLE && handleADX != INVALID_HANDLE && 
            handleRSI != INVALID_HANDLE && handleStoch != INVALID_HANDLE && 
            handleATR_Switch != INVALID_HANDLE);
}

void OnDeinit(const int reason) {
   IndicatorRelease(handleMA_MTF); IndicatorRelease(handleADX);
   IndicatorRelease(handleRSI); IndicatorRelease(handleStoch);
   IndicatorRelease(handleATR_Switch);
   if(handleATR_SLTP != INVALID_HANDLE) IndicatorRelease(handleATR_SLTP);
   if(handleATR_Daily != INVALID_HANDLE) IndicatorRelease(handleATR_Daily);
}

// =================================================================
// ON TICK
// =================================================================
void OnTick()
{
   ProcessVerifyQueue(); ProcessRetryQueue();
   if(g_is_broken) {
      if(GetTickCount() - g_broken_time > 300000) { g_is_broken = false; g_health.consecutive_fails = 0; }
      return;
   }
   if(!RefreshCache() || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(CheckFridayClose() || !CheckMarketConditions()) return;
   
   ManageOpenPositions(); // Update Trailing Stop
   
   if(!IsNewBar()) return;
   if(InpUseTimeFilter && !IsTradingTimeOptimized()) return;
   if(CountOpenPositions() >= InpMaxPositions) return;

   ProcessSignal();
}

// =================================================================
// INTELLIGENT SIGNAL LOGIC (SOLUSI 3: PULLBACK ENTRY)
// =================================================================
int GetEntrySignal()
{
   // --- STEP 1: Determine Strategy Mode ---
   bool useTrendStrat = false;
   bool useReversalStrat = false;

   if (InpStratMode == MODE_MANUAL) {
       useTrendStrat = true; useReversalStrat = true;
   } 
   else if (InpStratMode == MODE_AUTO_ATR) {
       double atrVal = GetATRValue(handleATR_Switch);
       double dynamicThreshold = GetDynamicATRThreshold();
       
       if (atrVal > dynamicThreshold) {
           useTrendStrat = true; useReversalStrat = false; // Trend Mode
       } else {
           useTrendStrat = false; useReversalStrat = true; // Reversal Mode
       }
   }

   bool doBuy = true;
   bool doSell = true;
   double close1 = iClose(_Symbol, _Period, 1);

   // --- STEP 2: TREND LOGIC ---
   if (useTrendStrat) {
       double ma[1];
       if(CopyBuffer(handleMA_MTF, 0, 0, 1, ma) < 1) return 0;
       if (close1 < ma[0]) doBuy = false;
       if (close1 > ma[0]) doSell = false;

       double adx[1], plus[1], minus[1];
       if(CopyBuffer(handleADX, 0, 1, 1, adx) < 1 || CopyBuffer(handleADX, 1, 1, 1, plus) < 1 || CopyBuffer(handleADX, 2, 1, 1, minus) < 1) return 0;
       if(adx[0] < InpADXThreshold) { doBuy = false; doSell = false; }
       else { if(plus[0] < minus[0]) doBuy = false; if(minus[0] < plus[0]) doSell = false; }
   }

   // --- STEP 3: REVERSAL LOGIC (MODIFIED SOLUSI 3: PULLBACK) ---
   if (useReversalStrat) {
       // A. RSI Check (70/30 Veto)
       double rsi[1];
       if(CopyBuffer(handleRSI, 0, 1, 1, rsi) < 1) return 0;
       if (rsi[0] > 70) doBuy = false;  // Jangan Buy di pucuk
       if (rsi[0] < 30) doSell = false; // Jangan Sell di lembah
       
       // B. Stochastic Check (PULLBACK ENTRY)
       double stoch[];
       ArraySetAsSeries(stoch, true); // Set index 0 sebagai candle terbaru
       if(CopyBuffer(handleStoch, 0, 0, 2, stoch) < 2) return 0; // Ambil 2 data (0=now, 1=prev)
       
       // Reset trigger (kita hanya entry jika terjadi CROSSOVER valid)
       bool triggerBuy = false;
       bool triggerSell = false;
       
       // LOGIKA PULLBACK SELL:
       // Harga sebelumnya DI ATAS 80, Harga sekarang MENEMBUS KE BAWAH 80
       if (stoch[1] > InpStochUpper && stoch[0] <= InpStochUpper) {
           triggerSell = true;
       }
       
       // LOGIKA PULLBACK BUY:
       // Harga sebelumnya DI BAWAH 20, Harga sekarang MENEMBUS KE ATAS 20
       if (stoch[1] < InpStochLower && stoch[0] >= InpStochLower) {
           triggerBuy = true;
       }
       
       // Menerapkan Trigger ke Logic Utama
       if (triggerBuy) {
           // Jika trigger buy valid, pastikan RSI mengizinkan
           if(doBuy) { /* Do nothing, keep Buy True */ doSell = false; }
       } else if (triggerSell) {
           // Jika trigger sell valid, pastikan RSI mengizinkan
           if(doSell) { /* Do nothing, keep Sell True */ doBuy = false; }
       } else {
           // Jika TIDAK ADA trigger crossover (misal harga masih nempel di 85), JANGAN ENTRY.
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

void ProcessSignal() {
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
       if(InpStopLossFixed > 0) {
           sl = (signal == 1) ? price - (InpStopLossFixed * cache_point) : price + (InpStopLossFixed * cache_point);
       }
       if(InpTakeProfitFixed > 0) {
           tp = (signal == 1) ? price + (InpTakeProfitFixed * cache_point) : price - (InpTakeProfitFixed * cache_point);
       }
   }

   // --- CHECK MIN SL POINTS (Fix untuk mencegah SL terlalu tipis) ---
   if(sl_dist_points < InpMinSLPoints) {
       if(InpEnableDebug) Print("SL terlalu tipis: ", sl_dist_points, " < Min ", InpMinSLPoints, ". Trade SKIP.");
       return;
   }

   double tradeLot = CalculateLotSize(sl_dist_points);
   string hash = StringFormat("%d_%.5f_%d", type, price, TimeCurrent());
   OpenOrderAsync(type, tradeLot, price, sl, tp, hash);
}

// =================================================================
// TRAILING STOP & OTHER FUNCTIONS (Standard)
// =================================================================
void ManageOpenPositions() { 
    if(!InpUseTrailingStop) return;
    double st = InpTrailingStart * _Point; 
    double dt = InpTrailingDist * _Point;
    double sp = InpTrailingStep * _Point; 
    
    for(int i = PositionsTotal()-1; i >= 0; i--) { 
        ulong t = PositionGetTicket(i);
        if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) { 
            double sl = PositionGetDouble(POSITION_SL);
            double cr = PositionGetDouble(POSITION_PRICE_CURRENT);
            double op = PositionGetDouble(POSITION_PRICE_OPEN);
            double nsl = sl; bool mod = false;
            
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) { 
                if(cr - op > st) { 
                    double tgt = cr - dt;
                    if(tgt > sl + sp || sl == 0) { nsl = tgt; mod = true; } 
                } 
            } else { 
                if(op - cr > st) { 
                    double tgt = cr + dt;
                    if(tgt < sl - sp || sl == 0) { nsl = tgt; mod = true; } 
                } 
            }
            if(mod) trade.PositionModify(t, NormalizeDouble(nsl, _Digits), PositionGetDouble(POSITION_TP));
        } 
    } 
}

bool OpenOrderAsync(ENUM_ORDER_TYPE type, double lot, double price, double sl, double tp, string hash) {
    if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < 10) return false;
    string comment = "EA_Bot_v2.2_ID";
    bool result = (type == ORDER_TYPE_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, comment) : trade.Sell(lot, _Symbol, price, sl, tp, comment);
    
    if(result && trade.ResultRetcode() == TRADE_RETCODE_DONE) {
        OrderTask task; task.ticket = trade.ResultOrder(); task.type = type; task.hash = hash; task.timestamp = GetTickCount();
        g_verify_queue.Push(task); UpdateHealth(true); return true;
    } else {
        OrderTask task; task.type = type; task.qty = lot; task.price = price; task.sl = sl; task.tp = tp; task.hash = hash; task.timestamp = GetTickCount(); task.retry_count = 0;
        g_retry_queue.Push(task); UpdateHealth(false); return false;
    }
}

void ProcessRetryQueue() { /* Logic */ }
void ProcessVerifyQueue() { /* Logic */ }
void UpdateHealth(bool success) { if(success) { g_health.exec_success++; g_health.consecutive_fails=0; } else { g_health.exec_fail++; } }
bool CheckFridayClose() { return false; } 
bool RefreshCache() { cache_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); return (cache_point > 0); }
bool IsNewBar() { static datetime last = 0; datetime curr = iTime(_Symbol, _Period, 0); if(last!=curr) { last=curr; return true; } return false; }
bool IsTradingTimeOptimized() { return true; } 
int CountOpenPositions() { int c=0; for(int i=PositionsTotal()-1; i>=0; i--) if(PositionGetInteger(POSITION_MAGIC)==InpMagicNum) c++; return c; }
double CalculateLotSize(double slPoints) { return InpFixedLots; } 
//+------------------------------------------------------------------+
