#property copyright "MIT"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

// AI Trading EA: configurable mode, lots, trade limits, risk controls, and an
// optional HTTP AI signal. The technical strategy remains available as a safe
// fallback when the AI endpoint is disabled or unavailable.
enum ENUM_TRADING_MODE
  {
   MODE_SCALPING = 0,
   MODE_INTRADAY = 1,
   MODE_SWING    = 2
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED = 0,
   LOT_RISK_PERCENT = 1
  };

input group "Strategy"
input ENUM_TRADING_MODE TradingMode = MODE_INTRADAY;
input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_CURRENT;
input bool UseAISignals = false;
input string AIEndpoint = "https://example.com/ai/signal";
input string AIAuthHeader = ""; // Example: Bearer YOUR_TOKEN
input int AIWebRequestTimeoutMs = 3000;
input double MinimumAIConfidence = 0.60;
input bool UseTechnicalFallback = true;

input group "Position sizing"
input ENUM_LOT_MODE LotMode = LOT_RISK_PERCENT;
input double FixedLots = 0.01;
input double RiskPercent = 1.0;
input int MaxTradesPerSymbol = 1;
input int MaxTradesTotal = 3;
input ulong MagicNumber = 26092601;

input group "Risk and execution"
input int StopLossPoints = 0; // 0 = mode default
input int TakeProfitPoints = 0; // 0 = mode default
input int MaxSpreadPoints = 30;
input int SlippagePoints = 10;
input double DailyLossLimitPercent = 3.0;
input int CooldownMinutes = 15;
input bool OneTradePerBar = true;
input bool AllowLong = true;
input bool AllowShort = true;
input int StartHour = 0;
input int EndHour = 23;

input group "Technical fallback"
input int FastEMAPeriod = 20;
input int SlowEMAPeriod = 50;
input int RSIPeriod = 14;
input double BuyRSIMinimum = 52.0;
input double SellRSIMaximum = 48.0;
input int ATRPeriod = 14;
input double ATRStopMultiplier = 1.5;
input double ATRTakeMultiplier = 2.5;

CTrade trade;
int fastHandle = INVALID_HANDLE;
int slowHandle = INVALID_HANDLE;
int rsiHandle = INVALID_HANDLE;
int atrHandle = INVALID_HANDLE;
datetime lastBarTime = 0;
datetime lastTradeTime = 0;
double dayStartEquity = 0.0;
int trackedDay = -1;

string ModeName()
  {
   if(TradingMode == MODE_SCALPING) return "SCALPING";
   if(TradingMode == MODE_SWING) return "SWING";
   return "INTRADAY";
  }

ENUM_TIMEFRAMES WorkTimeframe()
  {
   if(SignalTimeframe != PERIOD_CURRENT) return SignalTimeframe;
   if(TradingMode == MODE_SCALPING) return PERIOD_M5;
   if(TradingMode == MODE_SWING) return PERIOD_H4;
   return PERIOD_M15;
  }

int DefaultSLPoints()
  {
   if(StopLossPoints > 0) return StopLossPoints;
   if(TradingMode == MODE_SCALPING) return 100;
   if(TradingMode == MODE_SWING) return 800;
   return 300;
  }

int DefaultTPPoints()
  {
   if(TakeProfitPoints > 0) return TakeProfitPoints;
   if(TradingMode == MODE_SCALPING) return 150;
   if(TradingMode == MODE_SWING) return 1200;
   return 600;
  }

int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   ENUM_TIMEFRAMES tf = WorkTimeframe();
   fastHandle = iMA(_Symbol, tf, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, tf, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, tf, RSIPeriod, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, tf, ATRPeriod);
   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
      return INIT_FAILED;
   ResetDailyEquity();
   Print("AI Trading EA started: ", _Symbol, " / ", ModeName(), " / ", EnumToString(tf));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(fastHandle != INVALID_HANDLE) IndicatorRelease(fastHandle);
   if(slowHandle != INVALID_HANDLE) IndicatorRelease(slowHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
  }

void OnTick()
  {
   UpdateDailyEquity();
   if(!TradingAllowed()) return;
   if(OneTradePerBar && !IsNewBar()) return;
   if(CountOurPositions(_Symbol) >= MaxTradesPerSymbol || CountOurPositions("") >= MaxTradesTotal) return;
   if(lastTradeTime > 0 && (TimeCurrent() - lastTradeTime) < CooldownMinutes * 60) return;
   if((int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints) return;

   string action = "HOLD";
   double confidence = 0.0;
   double aiSL = 0.0;
   double aiTP = 0.0;
   bool aiWorked = false;
   if(UseAISignals) aiWorked = RequestAISignal(action, confidence, aiSL, aiTP);
   if(!aiWorked && UseTechnicalFallback) TechnicalSignal(action, confidence);
   if(confidence < MinimumAIConfidence && UseAISignals && aiWorked) action = "HOLD";
   if(action == "BUY" && AllowLong) OpenTrade(ORDER_TYPE_BUY, aiSL, aiTP);
   if(action == "SELL" && AllowShort) OpenTrade(ORDER_TYPE_SELL, aiSL, aiTP);
  }

bool IsNewBar()
  {
   datetime times[1];
   if(CopyTime(_Symbol, WorkTimeframe(), 0, 1, times) != 1) return false;
   if(times[0] == lastBarTime) return false;
   lastBarTime = times[0];
   return true;
  }

void ResetDailyEquity()
  {
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   trackedDay = now.day_of_year;
   dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  }

void UpdateDailyEquity()
  {
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   if(now.day_of_year != trackedDay) ResetDailyEquity();
  }

bool TradingAllowed()
  {
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   bool inSession = (StartHour <= EndHour) ? (now.hour >= StartHour && now.hour <= EndHour) : (now.hour >= StartHour || now.hour <= EndHour);
   if(!inSession) return false;
   if(dayStartEquity > 0.0 && DailyLossLimitPercent > 0.0)
     {
      double lossPct = (dayStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / dayStartEquity * 100.0;
      if(lossPct >= DailyLossLimitPercent) return false;
     }
   return TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED);
  }

int CountOurPositions(string symbolFilter)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(symbolFilter != "" && PositionGetString(POSITION_SYMBOL) != symbolFilter) continue;
      count++;
     }
   return count;
  }

void TechnicalSignal(string &action, double &confidence)
  {
   double fast[3], slow[3], rsi[3];
   ArraySetAsSeries(fast, true); ArraySetAsSeries(slow, true); ArraySetAsSeries(rsi, true);
   if(CopyBuffer(fastHandle, 0, 0, 3, fast) < 3 || CopyBuffer(slowHandle, 0, 0, 3, slow) < 3 || CopyBuffer(rsiHandle, 0, 0, 3, rsi) < 3) return;
   if(fast[1] > slow[1] && fast[2] <= slow[2] && rsi[1] >= BuyRSIMinimum)
     { action = "BUY"; confidence = 0.70; }
   else if(fast[1] < slow[1] && fast[2] >= slow[2] && rsi[1] <= SellRSIMaximum)
     { action = "SELL"; confidence = 0.70; }
  }

bool RequestAISignal(string &action, double &confidence, double &slPoints, double &tpPoints)
  {
   if(StringLen(AIEndpoint) < 8 || StringFind(AIEndpoint, "example.com") >= 0) return false;
   double fast[2], slow[2], rsi[2], atr[2];
   ArraySetAsSeries(fast, true); ArraySetAsSeries(slow, true); ArraySetAsSeries(rsi, true); ArraySetAsSeries(atr, true);
   if(CopyBuffer(fastHandle, 0, 0, 2, fast) < 2 || CopyBuffer(slowHandle, 0, 0, 2, slow) < 2 || CopyBuffer(rsiHandle, 0, 0, 2, rsi) < 2 || CopyBuffer(atrHandle, 0, 0, 2, atr) < 2) return false;
   MqlTick tick; if(!SymbolInfoTick(_Symbol, tick)) return false;
   string body = StringFormat("{\"symbol\":\"%s\",\"mode\":\"%s\",\"timeframe\":\"%s\",\"bid\":%.8f,\"ask\":%.8f,\"ema_fast\":%.8f,\"ema_slow\":%.8f,\"rsi\":%.4f,\"atr\":%.8f}", _Symbol, ModeName(), EnumToString(WorkTimeframe()), tick.bid, tick.ask, fast[1], slow[1], rsi[1], atr[1]);
   char data[], result[]; string resultHeaders;
   StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   string headers = "Content-Type: application/json\r\n";
   if(StringLen(AIAuthHeader) > 0) headers += "Authorization: " + AIAuthHeader + "\r\n";
   ResetLastError();
   int status = WebRequest("POST", AIEndpoint, headers, AIWebRequestTimeoutMs, data, result, resultHeaders);
   if(status < 200 || status >= 300) { Print("AI WebRequest failed. HTTP=", status, " error=", GetLastError()); return false; }
   string response = CharArrayToString(result, 0, -1, CP_UTF8);
   action = StringToUpper(ExtractString(response, "action", "HOLD"));
   confidence = ExtractNumber(response, "confidence", 0.0);
   slPoints = ExtractNumber(response, "sl_points", 0.0);
   tpPoints = ExtractNumber(response, "tp_points", 0.0);
   return (action == "BUY" || action == "SELL" || action == "HOLD");
  }

string ExtractString(string json, string key, string fallback)
  {
   string needle = "\"" + key + "\"";
   int p = StringFind(json, needle); if(p < 0) return fallback;
   p = StringFind(json, ":", p); if(p < 0) return fallback;
   p = StringFind(json, "\"", p); if(p < 0) return fallback;
   int e = StringFind(json, "\"", p + 1); if(e < 0) return fallback;
   return StringSubstr(json, p + 1, e - p - 1);
  }

double ExtractNumber(string json, string key, double fallback)
  {
   string needle = "\"" + key + "\""; int p = StringFind(json, needle); if(p < 0) return fallback;
   p = StringFind(json, ":", p); if(p < 0) return fallback; p++;
   while(p < StringLen(json) && (StringGetCharacter(json, p) == ' ' || StringGetCharacter(json, p) == '\t')) p++;
   int e = p; while(e < StringLen(json) && StringFind("0123456789.-+eE", StringSubstr(json, e, 1)) >= 0) e++;
   return StringToDouble(StringSubstr(json, p, e - p));
  }

void OpenTrade(ENUM_ORDER_TYPE type, double aiSL, double aiTP)
  {
   MqlTick tick; if(!SymbolInfoTick(_Symbol, tick)) return;
   double price = (type == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   int slPts = (aiSL > 0.0) ? (int)aiSL : DefaultSLPoints();
   int tpPts = (aiTP > 0.0) ? (int)aiTP : DefaultTPPoints();
   double sl = (type == ORDER_TYPE_BUY) ? price - slPts * _Point : price + slPts * _Point;
   double tp = (type == ORDER_TYPE_BUY) ? price + tpPts * _Point : price - tpPts * _Point;
   double lots = CalculateLots(slPts);
   if(lots <= 0.0) return;
   bool ok = (type == ORDER_TYPE_BUY) ? trade.Buy(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "AI-EA") : trade.Sell(lots, _Symbol, 0.0, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), "AI-EA");
   if(ok) { lastTradeTime = TimeCurrent(); Print("Opened ", EnumToString(type), " ", DoubleToString(lots, 2), " lots"); }
   else Print("Order failed: ", trade.ResultRetcodeDescription());
  }

double CalculateLots(int slPoints)
  {
   double lots = FixedLots;
   if(LotMode == LOT_RISK_PERCENT)
     {
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue > 0.0 && tickSize > 0.0) lots = riskMoney / ((slPoints * _Point) / tickSize * tickValue);
     }
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = minLot;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots / step) * step;
   return NormalizeDouble(lots, 2);
  }
