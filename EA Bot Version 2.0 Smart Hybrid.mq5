//+------------------------------------------------------------------+
//|            EA Bot Version 2.0 (Smart Hybrid) - OPTIMIZED        |
//|      Features: Auto-Switch Strategy, MTF Filter, Dynamic MM      |
//|      OPTIMIZED FOR XAUUSD (Exness Raw Spread)                    |
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
// PARAMETER INPUT - OPTIMIZED FOR XAUUSD
// =================================================================
input group "=== INTELLIGENCE CORE (V2.0) ==="
input ENUM_STRAT_MODE InpStratMode  = MODE_AUTO_ATR; // Strategy Mode
input ENUM_TIMEFRAMES InpTrendTF    = PERIOD_H4;     // Multi-Timeframe Trend Filter
input int      InpATR_Switch_Period = 14;            // Period for Volatility Check
input double   InpATR_Switch_Level  = 0.0250;        // OPTIMIZED: Dynamic threshold for Gold

input group "=== MONEY MANAGEMENT ==="
input bool     InpUseDynamicLot     = true;      // Use Risk Based Lot
input double   InpRiskPercent       = 0.5;       // OPTIMIZED: Lower risk for Gold volatility
input double   InpFixedLots         = 0.01;      // OPTIMIZED: Smaller default lot

input group "=== DYNAMIC SL/TP ==="
input bool     InpUseATR_SLTP       = true;      // MUST BE TRUE for Gold
input int      InpATR_SLTP_Period   = 14;
input double   InpATR_SL_Ratio      = 2.0;       // OPTIMIZED: Wider SL for Gold volatility
input double   InpATR_TP_Ratio      = 4.0;       // OPTIMIZED: TP for 1:2 RR

input group "=== NEWS FILTER (CRITICAL) ==="      // +++ NEW GROUP +++
input bool     InpUseNewsFilter     = true;      // Enable News Filter
input int      InpNewsMinBefore     = 30;        // Minutes BEFORE news to avoid trading
input int      InpNewsMinAfter      = 90;        // Minutes AFTER news to avoid trading
input bool     InpCloseBeforeNews   = true;      // Close positions before high-impact news

input group "=== CORE SETTINGS ==="
input int      InpMagicNum          = 998822;
input int      InpMaxPositions      = 1;

input group "=== TIME FILTER ==="
input bool     InpUseTimeFilter     = true;
input int      InpStartHour         = 8;         // OPTIMIZED: London session start
input int      InpEndHour           = 22;        // OPTIMIZED: NY session end
input bool     InpCloseFriday       = true;
input int      InpFridayHour        = 20;        // OPTIMIZED: Earlier close before weekend

input group "=== STRATEGY PARAMETERS ==="
// Trend Indicators (Used in Trending Mode)
input int      InpMAPeriod          = 100;       // OPTIMIZED: Longer MA for Gold trends
input int      InpADXPeriod         = 14;
input double   InpADXThreshold      = 30.0;      // OPTIMIZED: Stronger trend filter

// Reversal Indicators (Used in Sideways Mode)
input int      InpRSIPeriod         = 14;
input int      InpStochK            = 8;
input int      InpStochD            = 3;
input int      InpStochSlowing      = 3;
input int      InpStochUpper        = 80;
input int      InpStochLower        = 20;

input group "=== RISK FALLBACK ==="
input int      InpStopLossFixed     = 15000;     // OPTIMIZED: Minimum 150 pips for Gold
input int      InpTakeProfitFixed   = 30000;     // OPTIMIZED: 300 pips minimum
input bool     InpUseTrailingStop   = true;
input int      InpTrailingStart     = 500;       // OPTIMIZED: Start after 50 pips
input int      InpTrailingDist      = 300;       // OPTIMIZED: 30 pips trailing distance
input int      InpTrailingStep      = 100;       // OPTIMIZED: 10 pips step

input group "=== SYSTEM SAFETY ==="
input int      InpMaxSpread         = 100;       // OPTIMIZED: Max 10 pips spread
input int      InpSlippage          = 20;        // OPTIMIZED: 2 pips for Exness execution
input int      InpMaxRetryAttempts  = 3;         // Reduced retries
input bool     InpEnableDebug       = true;
input double   InpMinSLPoints       = 1500;      // +++ NEW: Minimum SL points (15 pips)
input double   InpMinRRRatio        = 1.5;       // +++ NEW: Minimum Risk:Reward ratio

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

// =================================================================
// RING BUFFER CLASS - CORRECTED VERSION
// =================================================================
class RingBufferOrderTask {
private: 
    OrderTask m_buffer[];
    int m_head;
    int m_tail;
    int m_count;
    int m_capacity;
    
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
            OrderTask t; 
            Pop(t); 
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
int      handleMA_MTF = INVALID_HANDLE;     // Multi-Timeframe MA
int      handleADX = INVALID_HANDLE;
int      handleRSI = INVALID_HANDLE;
int      handleStoch = INVALID_HANDLE;
int      handleATR_Switch = INVALID_HANDLE; // For Logic Switching
int      handleATR_SLTP = INVALID_HANDLE;   // For Dynamic SL/TP
int      handleATR_Daily = INVALID_HANDLE;  // For Daily ATR comparison

bool     g_is_broken = false;
ulong    g_broken_time = 0;
HealthMetrics g_health = {0, 0, 0};

RingBufferOrderTask g_retry_queue;
RingBufferOrderTask g_verify_queue;

double   cache_point;

// +++ NEW: News Event Arrays +++
string   gHighImpactEvents[];  // Will be initialized in OnInit
datetime gHighImpactTimes[];

// =================================================================
// NEW FUNCTIONS - MARKET CONDITIONS & NEWS FILTER
// =================================================================

// Function 1: Check Market Conditions (Spread, Volatility, Session)
bool CheckMarketConditions()
{
    // 1. Filter Spread (Exness-specific: tight spreads expected)
    int currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(currentSpread > InpMaxSpread) 
    {
        if(InpEnableDebug) Print("Spread terlalu tinggi: ", currentSpread, " points. Trade dibatalkan.");
        return false;
    }
    
    // 2. Filter Volatility Spike (ATR > 2x Daily ATR)
    double atrCurrent = GetATRValue(handleATR_SLTP);
    double atrDailyBuff[1];
    
    // Copy Daily ATR value (yesterday's ATR)
    if(CopyBuffer(handleATR_Daily, 0, 1, 1, atrDailyBuff) >= 1)
    {
        double atrDaily = atrDailyBuff[0];
        if(atrCurrent > (atrDaily * 2.0)) 
        {
            if(InpEnableDebug) Print("Volatilitas ekstrem terdeteksi. ATR Spike: ", atrCurrent, " vs Daily: ", atrDaily);
            return false;
        }
    }
    
    // 3. Additional filter for Gold: Avoid Asian session sideways
    MqlDateTime now; 
    TimeCurrent(now);
    if(now.hour >= 21 && now.hour < 24) // Early Asian session
    {
        // Optional: bisa di-enable jika mau skip sesi Asia
        // if(InpEnableDebug) Print("Sesi Asia - Trading dibatasi.");
        // return false;
    }
    
    return true;
}

// Function 2: Initialize News Data (Example dates - MUST BE UPDATED MANUALLY)
void InitializeNewsData()
{
    // Example: High-impact news events for May 2024
    // Format: "YYYY.MM.DD HH:MM|Event Name|HIGH"
    // YOU MUST UPDATE THIS ARRAY WITH ACTUAL NEWS DATES
    string newsEvents[] = 
    {
        "2024.05.10 12:30|US CPI (MoM)|HIGH",
        "2024.05.15 14:00|US Retail Sales (MoM)|HIGH",
        "2024.05.16 18:00|US FOMC Meeting Minutes|HIGH",
        "2024.05.22 12:30|US Core Durable Goods|MEDIUM",
        "2024.05.31 12:30|US Core PCE Price Index|HIGH"
    };
    
    ArrayResize(gHighImpactEvents, ArraySize(newsEvents));
    ArrayResize(gHighImpactTimes, ArraySize(newsEvents));
    
    for(int i = 0; i < ArraySize(newsEvents); i++)
    {
        string parts[];
        StringSplit(newsEvents[i], '|', parts);
        if(ArraySize(parts) >= 3)
        {
            gHighImpactTimes[i] = StringToTime(parts[0]);
            gHighImpactEvents[i] = parts[1];
        }
    }
    
    if(InpEnableDebug) Print("News Filter Initialized with ", ArraySize(newsEvents), " high-impact events.");
}

// Function 3: Check if Current Time is Near High-Impact News
bool IsNewsTime()
{
    if(!InpUseNewsFilter || ArraySize(gHighImpactTimes) == 0) 
        return false;
    
    datetime now = TimeCurrent();
    
    for(int i = 0; i < ArraySize(gHighImpactTimes); i++)
    {
        datetime newsTime = gHighImpactTimes[i];
        
        if(now >= (newsTime - (InpNewsMinBefore * 60)) && 
           now <= (newsTime + (InpNewsMinAfter * 60)))
        {
            if(InpEnableDebug) 
                Print("HIGH IMPACT NEWS AVOIDANCE: ", gHighImpactEvents[i], 
                      " at ", TimeToString(newsTime));
            
            // Optional: Close existing positions before news
            if(InpCloseBeforeNews && CountOpenPositions() > 0)
            {
                CloseAllPositionsBeforeNews();
            }
            
            return true;
        }
    }
    
    return false;
}

// Function 4: Close all positions before news (optional)
void CloseAllPositionsBeforeNews()
{
    int total = PositionsTotal();
    for(int i = total-1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket) && 
           PositionGetInteger(POSITION_MAGIC) == InpMagicNum)
        {
            trade.PositionClose(ticket);
            if(InpEnableDebug) 
                Print("Position ", ticket, " closed before high-impact news.");
        }
    }
}

// Function 5: Dynamic ATR Threshold based on Gold Price
double GetDynamicATRThreshold()
{
    double goldPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    // Base threshold: 0.3% dari harga Gold (adjustable)
    double baseThreshold = goldPrice * 0.003; 
    
    // Minimum threshold untuk harga rendah
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
   
   // Initialize News Filter Data
   if(InpUseNewsFilter)
   {
       InitializeNewsData();
   }

   Print("=== EA Bot Version 2.0 OPTIMIZED FOR XAUUSD STARTED ===");
   Print("Broker: Exness | Max Spread: ", InpMaxSpread, " | Slippage: ", InpSlippage);
   Print("News Filter: ", InpUseNewsFilter ? "ENABLED" : "DISABLED");
   Print("Dynamic ATR Threshold: ", GetDynamicATRThreshold());
   
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
        
        // 7. ATR for Daily comparison
        handleATR_Daily = iATR(_Symbol, PERIOD_D1, 14);
        if(handleATR_Daily == INVALID_HANDLE) success = false;

        if(success) return true;
        attempts++; 
        Sleep(500);
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
   if(handleATR_Daily != INVALID_HANDLE) IndicatorRelease(handleATR_Daily);
}

// =================================================================
// ON TICK - MODIFIED WITH NEW FILTERS
// =================================================================
void OnTick()
{
   ProcessVerifyQueue(); 
   ProcessRetryQueue();

   if(g_is_broken) {
      if(GetTickCount() - g_broken_time > 300000) { 
         g_is_broken = false; 
         g_health.consecutive_fails = 0; 
         Print("Info: Circuit Breaker Reset");
      }
      return;
   }

   if(!RefreshCache()) return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(CheckFridayClose()) return;
   
   // +++ NEW: Market Conditions Check +++
   if(!CheckMarketConditions()) return;
   
   // +++ NEW: News Filter Check +++
   if(IsNewsTime()) {
       if(InpEnableDebug) Print("Skipping trading due to high-impact news window.");
       return;
   }
   
   ManageOpenPositions();
   
   if(!IsNewBar()) return;
   if(InpUseTimeFilter && !IsTradingTimeOptimized()) return;
   if(CountOpenPositions() >= InpMaxPositions) return;
   if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpread) return;

   ProcessSignal();
}

// =================================================================
// INTELLIGENT SIGNAL LOGIC (V2.0 Core) - OPTIMIZED
// =================================================================
int GetEntrySignal()
{
   // --- STEP 1: Determine Strategy Mode ---
   bool useTrendStrat = false;
   bool useReversalStrat = false;

   if (InpStratMode == MODE_MANUAL) {
       useTrendStrat = true; 
       useReversalStrat = true;
   } 
   else if (InpStratMode == MODE_AUTO_ATR) {
       double atrVal = GetATRValue(handleATR_Switch);
       
       // +++ MODIFIED: Use Dynamic Threshold for Gold +++
       double dynamicThreshold = GetDynamicATRThreshold();
       
       if (atrVal > dynamicThreshold) {
           useTrendStrat = true;
           useReversalStrat = false;
           if(InpEnableDebug) Print("Auto-Mode: High Volatility (", DoubleToString(atrVal,5), 
                 " > ", DoubleToString(dynamicThreshold,5), "). Strategy: TREND");
       } else {
           useTrendStrat = false;
           useReversalStrat = true;
           if(InpEnableDebug) Print("Auto-Mode: Low Volatility (", DoubleToString(atrVal,5), 
                 " <= ", DoubleToString(dynamicThreshold,5), "). Strategy: REVERSAL");
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
       if(CopyBuffer(handleMA_MTF, 0, 0, 1, ma) < 1) return 0;
       
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
       
       // Modified for Gold: Use stricter levels
       if (rsi[0] > 55) doBuy = false;  // More conservative
       if (rsi[0] < 45) doSell = false; // More conservative
       
       // B. Stochastic (Precision Entry)
       double stoch[1];
       if(CopyBuffer(handleStoch, 0, 1, 1, stoch) < 1) return 0;
       
       if (stoch[0] > InpStochUpper) {
            if(doBuy) doBuy = false;
       } else if (stoch[0] < InpStochLower) {
            if(doSell) doSell = false;
       } else {
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

// =================================================================
// PROCESS SIGNAL - MODIFIED WITH MINIMUM SL & RR CHECK
// =================================================================
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
           
           if(signal == 1) { 
               sl = price - sl_val; 
               tp = price + tp_val; 
           } else { 
               sl = price + sl_val; 
               tp = price - tp_val; 
           }
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

   // +++ NEW: MINIMUM STOP LOSS CHECK FOR GOLD +++
   if(sl_dist_points < InpMinSLPoints)
   {
       if(InpEnableDebug) Print("SL terlalu ketat: ", sl_dist_points, 
             " points. Minimal required: ", InpMinSLPoints, ". Trade DITOLAK.");
       return;
   }
   
   // +++ NEW: RISK:REWARD RATIO CHECK +++
   if(tp != 0) {
       double tp_dist_points = MathAbs(tp - price) / _Point;
       double currentRR = tp_dist_points / sl_dist_points;
       
       if(currentRR < InpMinRRRatio)
       {
           // Auto-adjust TP to meet minimum RR
           if(signal == 1) {
               tp = price + (sl_dist_points * InpMinRRRatio * _Point);
           } else {
               tp = price - (sl_dist_points * InpMinRRRatio * _Point);
           }
           
           if(InpEnableDebug) Print("TP di-adjust untuk RR minimal ", InpMinRRRatio, 
                 ":1. RR Lama: ", DoubleToString(currentRR, 2), 
                 ", TP Baru: ", DoubleToString(tp, 2));
       }
   }

   double tradeLot = CalculateLotSize(sl_dist_points);
   string hash = StringFormat("%d_%.5f_%d", type, price, TimeCurrent());
   
   if(InpEnableDebug) Print("SIGNAL V2 OPTIMIZED: ", EnumToString(type), 
         " | Mode: ", EnumToString(InpStratMode), 
         " | Lot: ", tradeLot, 
         " | SL: ", DoubleToString(sl, 2), 
         " | TP: ", DoubleToString(tp, 2));

   OpenOrderAsync(type, tradeLot, price, sl, tp, hash);
}

// =================================================================
// TRAILING STOP OPTIMIZED FOR GOLD
// =================================================================
void ManageOpenPositions() 
{ 
    if(!InpUseTrailingStop) return;
    
    // For Gold, use ATR-based trailing for dynamic adjustment
    double atr = GetATRValue(handleATR_SLTP);
    double st = atr * 1.0;  // Start after profit 1x ATR
    double dt = atr * 0.5;  // Distance 0.5x ATR
    double sp = 100 * _Point;   // Step 1 pip (100 points)
    
    for(int i = PositionsTotal()-1; i >= 0; i--) 
    { 
        ulong t = PositionGetTicket(i);
        if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) 
        { 
            double sl = PositionGetDouble(POSITION_SL);
            double cr = PositionGetDouble(POSITION_PRICE_CURRENT);
            double op = PositionGetDouble(POSITION_PRICE_OPEN);
            double nsl = sl;
            bool mod = false;
            
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) 
            { 
                if(cr - op > st) 
                { 
                    double tgt = cr - dt; 
                    if(tgt > sl + sp || sl == 0) 
                    { 
                        nsl = tgt; 
                        mod = true; 
                    } 
                } 
            }
            else 
            { 
                if(op - cr > st) 
                { 
                    double tgt = cr + dt; 
                    if(tgt < sl - sp || sl == 0) 
                    { 
                        nsl = tgt; 
                        mod = true; 
                    } 
                } 
            }
            
            if(mod) 
            {
                trade.PositionModify(t, NormalizeDouble(nsl, _Digits), PositionGetDouble(POSITION_TP));
                if(InpEnableDebug) 
                    Print("Trailing Stop updated for ticket ", t, 
                          " | New SL: ", NormalizeDouble(nsl, _Digits));
            }
        } 
    } 
}

// =================================================================
// STANDARD FUNCTIONS (Queue, Safety, Etc)
// =================================================================
bool OpenOrderAsync(ENUM_ORDER_TYPE type, double lot, double price, double sl, double tp, string hash)
{
    double margin_required = 0.0;
    if(!OrderCalcMargin(type, _Symbol, lot, price, margin_required)) return false;
    if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required) {
        if(InpEnableDebug) Print("Margin tidak cukup untuk open order.");
        return false;
    }
    
    string comment = "EA_Bot_v2.0_XAUUSD_Optimized";
    bool result = (type == ORDER_TYPE_BUY) ? 
                  trade.Buy(lot, _Symbol, price, sl, tp, comment) : 
                  trade.Sell(lot, _Symbol, price, sl, tp, comment);
    
    if(result && trade.ResultRetcode() == TRADE_RETCODE_DONE) {
        OrderTask task; 
        task.ticket = trade.ResultOrder(); 
        task.type = type; 
        task.hash = hash; 
        task.timestamp = GetTickCount();
        g_verify_queue.Push(task); 
        UpdateHealth(true); 
        
        if(InpEnableDebug) Print("Order sukses: Ticket ", trade.ResultOrder(), 
              " | Price: ", price, " | SL: ", sl, " | TP: ", tp);
        return true;
    } else {
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
        
        if(InpEnableDebug) Print("Order gagal: ", trade.ResultRetcodeDescription());
        return false;
    }
}

void ProcessRetryQueue() {
    int q = g_retry_queue.Count();
    int p = 0;
    while(p < q && p < 5) {
        OrderTask t; 
        if(!g_retry_queue.Pop(t)) break;
        if (t.retry_count > InpMaxRetryAttempts) { 
            p++; 
            continue; 
        }
        if(GetTickCount() - t.timestamp >= (ulong)(1000 * (1 << MathMin(t.retry_count, 3)))) {
            if(!OpenOrderAsync(t.type, t.qty, t.price, t.sl, t.tp, t.hash)) {
                t.retry_count++; 
                t.timestamp = GetTickCount(); 
                g_retry_queue.Push(t);
            }
        } else {
            g_retry_queue.Push(t);
        }
        p++;
    }
}

void ProcessVerifyQueue() { 
    int m = g_verify_queue.Count();
    int x = 0;
    while(x < m && x < 10) { 
        OrderTask t; 
        if(!g_verify_queue.Pop(t)) break; 
        if(GetTickCount() - t.timestamp < 10000 && !PositionSelectByTicket(t.ticket)) {
            g_verify_queue.Push(t); 
        }
        x++; 
    } 
}

void UpdateHealth(bool success) { 
    if(success) { 
        g_health.exec_success++; 
        g_health.consecutive_fails = 0; 
    } 
    else { 
        g_health.exec_fail++; 
        g_health.consecutive_fails++; 
        if(g_health.consecutive_fails > 5) { 
            g_is_broken = true; 
            g_broken_time = GetTickCount(); 
            Print("Circuit Breaker! Terlalu banyak gagal berturut-turut."); 
        } 
    } 
}

bool CheckFridayClose() {
    if(!InpCloseFriday) return false;
    MqlDateTime now; 
    TimeCurrent(now);
    if(now.day_of_week != 5 || now.hour < InpFridayHour) return false;
    
    bool positionsClosed = false;
    for(int i = PositionsTotal()-1; i >= 0; i--) {
        ulong t = PositionGetTicket(i);
        if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) 
        {
            trade.PositionClose(t);
            if(InpEnableDebug) Print("Friday close: Position ", t, " closed.");
            positionsClosed = true;
        }
    }
    return positionsClosed;
}

bool RefreshCache() { 
    cache_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT); 
    return (cache_point > 0); 
}

bool IsNewBar() { 
    static datetime lastBarTime = 0; 
    datetime currentBarTime = iTime(_Symbol, _Period, 0); 
    if(lastBarTime != currentBarTime) { 
        lastBarTime = currentBarTime; 
        return true; 
    } 
    return false; 
}

bool IsTradingTimeOptimized() { 
    MqlDateTime now; 
    TimeCurrent(now);
    if(now.day_of_week == 6 || now.day_of_week == 0) return false; // Weekend
    if(InpStartHour <= InpEndHour) 
        return (now.hour >= InpStartHour && now.hour < InpEndHour);
    else 
        return (now.hour >= InpStartHour || now.hour < InpEndHour);
}

int CountOpenPositions() { 
    int count = 0; 
    for(int i = PositionsTotal()-1; i >= 0; i--) { 
        ulong ticket = PositionGetTicket(i); 
        if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNum) 
            count++; 
    } 
    return count; 
}

// =================================================================
// MONEY MANAGEMENT FUNCTION
// =================================================================
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
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   if(lots < minLot) lots = minLot; 
   if(lots > maxLot) lots = maxLot;
   
   return lots;
}
//+------------------------------------------------------------------+