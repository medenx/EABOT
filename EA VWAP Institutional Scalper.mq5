//+------------------------------------------------------------------+
//|                                  VWAP Institutional Scalper v2.5 |
//|                                     Copyright 2025, Gemini AI    |
//|                                       For: XAUUSD / Major Pairs  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Gemini AI"
#property link      "https://www.mql5.com"
#property version   "2.50"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group             "--- Strategy Parameters ---"
input int               InpVolPeriod      = 20;          // Volume Avg Period
input double            InpVolMultiplier  = 1.5;         // Volume Spike Multiplier
input int               InpVWAPResetHour  = 0;           // VWAP Reset Hour (Server Time)

input group             "--- Risk Management (Adaptive) ---"
input double            InpLots           = 0.01;        // Fixed Lot Size
input bool              InpUseATR         = true;        // Use ATR for SL/TP?
input int               InpATRPeriod      = 14;          // ATR Period
input double            InpATR_SL_Ratio   = 1.5;         // ATR Multiplier for StopLoss
input double            InpATR_TP_Ratio   = 3.0;         // ATR Multiplier for TakeProfit
input int               InpFixedSL        = 300;         // Fixed SL (Points) if ATR=false
input int               InpFixedTP        = 800;         // Fixed TP (Points) if ATR=false
input int               InpMaxSpread      = 500;         // Max Spread (Points)
input int               InpSlippage       = 30;          // Max Slippage

input group             "--- Time Filter (Precision) ---"
input bool              InpUseTimeFilter  = true;
input int               InpStartHour      = 8;           // Start Hour
input int               InpStartMinute    = 30;          // Start Minute
input int               InpEndHour        = 20;          // End Hour
input int               InpEndMinute      = 0;           // End Minute

input group             "--- System Protection ---"
input int               InpMagicNum       = 123456;      // Magic Number
input int               InpMaxRetry       = 3;           // Max Order Retries
input int               InpCircuitBreak   = 5;           // Max Consecutive Errors before Pause

//+------------------------------------------------------------------+
//| STRUCTS & GLOBALS (OPTIMIZATION)                                 |
//+------------------------------------------------------------------+
// Struct untuk caching data simbol agar hemat CPU
struct SSymbolContext
{
   double   point;
   double   tick_size;
   int      digits;
   string   symbol;
   double   ask;
   double   bid;
   double   spread_points;
   
   void Init(string sym)
   {
      symbol      = sym;
      point       = SymbolInfoDouble(symbol, SYMBOL_POINT);
      digits      = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      tick_size   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   }
   
   void Refresh()
   {
      MqlTick tick;
      if(SymbolInfoTick(symbol, tick))
      {
         ask = tick.ask;
         bid = tick.bid;
         if(point > 0) spread_points = (ask - bid) / point;
      }
   }
};

CTrade         trade;
SSymbolContext ctx;
int            hATR;                // Handle untuk indikator ATR
int            g_error_count = 0;   // Counter untuk Circuit Breaker
datetime       g_break_until = 0;   // Waktu sampai kapan pause aktif

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION FUNCTION                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // 1. Inisialisasi Context
   ctx.Init(_Symbol);
   if(ctx.point == 0) 
   {
      Print("Error: Failed to init symbol context.");
      return(INIT_FAILED);
   }

   // 2. Setup Trade Class
   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC); 

   // 3. Inisialisasi Indikator ATR (Jika dipakai)
   if(InpUseATR)
   {
      hATR = iATR(_Symbol, _Period, InpATRPeriod);
      if(hATR == INVALID_HANDLE)
      {
         Print("Error: Failed to create ATR handle.");
         return(INIT_FAILED);
      }
   }

   Print("VWAP Institutional Scalper v2.5 Initialized.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION FUNCTION                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hATR);
   Print("EA Deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| EXPERT TICK FUNCTION                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // --- 1. Refresh Data Pasar (Ringan) ---
   ctx.Refresh();
   
   // --- 2. Cek Circuit Breaker (Safety) ---
   if(TimeCurrent() < g_break_until) return; // Sedang dalam masa hukuman (pause)
   
   // --- 3. Filter Spread & Time ---
   if(ctx.spread_points > InpMaxSpread) return;
   if(!IsTradingAllowedByTime()) return;
   
   // --- 4. Logic: Cek Posisi Terbuka ---
   if(PositionSelectByMagic()) return; // Satu posisi pada satu waktu
   
   // --- 5. Kalkulasi Sinyal ---
   double vwap = CalculateIntradayVWAP();
   bool isVolSpike = IsVolumeSpike();
   
   // Kondisi Trading Sederhana (Contoh Logika VWAP)
   // Buy: Harga Close di atas VWAP + Volume Spike
   // Sell: Harga Close di bawah VWAP + Volume Spike
   
   double close = iClose(_Symbol, _Period, 1);
   
   if(isVolSpike && close > vwap)
   {
      ExecuteTrade(ORDER_TYPE_BUY);
   }
   else if(isVolSpike && close < vwap)
   {
      ExecuteTrade(ORDER_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//| HELPER: Execution Logic with Adaptive SL/TP                      |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type)
{
   // Reset error count jika berhasil masuk logika order
   int sl_points = 0;
   int tp_points = 0;
   
   // A. Hitung Dynamic SL/TP
   GetAdaptiveSLTP(sl_points, tp_points);
   
   double price = (type == ORDER_TYPE_BUY) ? ctx.ask : ctx.bid;
   double sl    = (type == ORDER_TYPE_BUY) ? price - (sl_points * ctx.point) : price + (sl_points * ctx.point);
   double tp    = (type == ORDER_TYPE_BUY) ? price + (tp_points * ctx.point) : price - (tp_points * ctx.point);
   
   // Normalisasi harga agar valid
   price = NormalizeDouble(price, ctx.digits);
   sl    = NormalizeDouble(sl, ctx.digits);
   tp    = NormalizeDouble(tp, ctx.digits);
   
   // B. Kirim Order dengan Retry Logic
   bool res = false;
   for(int i=0; i<InpMaxRetry; i++)
   {
      if(type == ORDER_TYPE_BUY) res = trade.Buy(InpLots, _Symbol, price, sl, tp, "VWAP v2.5 Buy");
      else                       res = trade.Sell(InpLots, _Symbol, price, sl, tp, "VWAP v2.5 Sell");
      
      if(res) 
      {
         g_error_count = 0; // Reset error counter jika sukses
         break; 
      }
      else
      {
         Print("Order failed. Retrying... Error: ", GetLastError());
         Sleep(100); // Backoff delay kecil
         ctx.Refresh(); // Refresh harga sebelum retry
         price = (type == ORDER_TYPE_BUY) ? ctx.ask : ctx.bid; // Update harga
      }
   }
   
   // C. Handle Circuit Breaker jika gagal total
   if(!res)
   {
      g_error_count++;
      if(g_error_count >= InpCircuitBreak)
      {
         Print("CRITICAL: Circuit Breaker Triggered! Pausing for 1 hour.");
         g_break_until = TimeCurrent() + 3600; // Pause 1 jam
         g_error_count = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| HELPER: Adaptive SL/TP Calculation                               |
//+------------------------------------------------------------------+
void GetAdaptiveSLTP(int &sl_p, int &tp_p)
{
   if(!InpUseATR)
   {
      sl_p = InpFixedSL;
      tp_p = InpFixedTP;
      return;
   }
   
   double atr_val[];
   ArraySetAsSeries(atr_val, true);
   
   if(CopyBuffer(hATR, 0, 1, 1, atr_val) < 1) // Copy ATR bar terakhir (closed)
   {
      Print("Warning: ATR Copy failed, using fixed SL/TP");
      sl_p = InpFixedSL;
      tp_p = InpFixedTP;
      return;
   }
   
   // Konversi Nilai ATR ke Points
   int atr_points = (int)(atr_val[0] / ctx.point);
   
   sl_p = (int)(atr_points * InpATR_SL_Ratio);
   tp_p = (int)(atr_points * InpATR_TP_Ratio);
   
   // Safety check: Jangan biarkan SL/TP bernilai 0 atau negatif
   if(sl_p <= 0) sl_p = InpFixedSL;
   if(tp_p <= 0) tp_p = InpFixedTP;
}

//+------------------------------------------------------------------+
//| HELPER: Time Filter (Precision Minutes)                          |
//+------------------------------------------------------------------+
bool IsTradingAllowedByTime()
{
   if(!InpUseTimeFilter) return(true);

   MqlDateTime dt;
   TimeCurrent(dt); 

   // Konversi semua ke total menit dari 00:00
   int current_min = (dt.hour * 60) + dt.min;
   int start_min   = (InpStartHour * 60) + InpStartMinute;
   int end_min     = (InpEndHour * 60) + InpEndMinute;

   // Logika Normal (contoh: 08:00 - 20:00)
   if(start_min < end_min)
   {
      if(current_min >= start_min && current_min < end_min) return(true);
   }
   // Logika Lintas Hari (contoh: 22:00 - 02:00)
   else 
   {
      if(current_min >= start_min || current_min < end_min) return(true);
   }

   return(false);
}

//+------------------------------------------------------------------+
//| HELPER: Calculate Intraday VWAP                                  |
//+------------------------------------------------------------------+
double CalculateIntradayVWAP()
{
   // Loop sederhana untuk mendapatkan start bar hari ini
   int start_bar = 0;
   MqlDateTime dt;
   
   // Cari bar pertama hari ini (reset hour)
   // Optimasi: Jangan loop lebih dari 1440 (untuk M1)
   for(int i=0; i<1440; i++)
   {
      datetime time = iTime(_Symbol, _Period, i);
      TimeToStruct(time, dt);
      if(dt.hour == InpVWAPResetHour && dt.min == 0)
      {
         start_bar = i;
         break;
      }
   }
   
   double sum_pv = 0;
   double sum_v  = 0;
   
   // Hitung VWAP dari start_bar sampai bar 1 (bar 0 sedang berjalan)
   for(int k=start_bar; k>=1; k--)
   {
      long vol = iVolume(_Symbol, _Period, k);
      double price = (iHigh(_Symbol, _Period, k) + iLow(_Symbol, _Period, k) + iClose(_Symbol, _Period, k)) / 3.0;
      
      sum_pv += price * vol;
      sum_v  += vol;
   }
   
   if(sum_v == 0) return(iClose(_Symbol, _Period, 1));
   return(sum_pv / sum_v);
}

//+------------------------------------------------------------------+
//| HELPER: Volume Spike Detection                                   |
//+------------------------------------------------------------------+
bool IsVolumeSpike()
{
   long current_vol = iVolume(_Symbol, _Period, 0);
   
   // Hitung rata-rata volume masa lalu (index 1 ke InpVolPeriod)
   double sum_vol = 0;
   for(int i=1; i<=InpVolPeriod; i++)
   {
      sum_vol += iVolume(_Symbol, _Period, i);
   }
   double avg_vol = sum_vol / InpVolPeriod;
   
   if(avg_vol == 0) return(false);
   
   // Apakah volume sekarang > rata-rata * multiplier?
   return (current_vol > avg_vol * InpVolMultiplier);
}

//+------------------------------------------------------------------+
//| HELPER: Check Existing Positions                                 |
//+------------------------------------------------------------------+
bool PositionSelectByMagic()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum && 
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            return(true);
         }
      }
   }
   return(false);
}
