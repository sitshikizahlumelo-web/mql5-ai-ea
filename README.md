# MQL5 AI Trading EA

A configurable MetaTrader 5 Expert Advisor with three trading profiles, fixed or risk-based position sizing, trade-count limits, technical fallback signals, and an optional HTTP AI signal provider.

> **Risk warning:** This is software, not financial advice. Test on a demo account and in the MT5 Strategy Tester before considering live use. AI output can be wrong, delayed, malformed, or unavailable. Never risk money you cannot afford to lose.

## Features

- Trading modes: **Scalping**, **Intraday**, and **Swing Trading**
- `MaxTradesPerSymbol` and `MaxTradesTotal`
- Fixed lots or automatic lot calculation from account risk percentage
- Configurable stop loss, take profit, spread limit, slippage, cooldown, trading hours, and daily loss limit
- EMA/RSI crossover technical fallback
- Optional HTTP POST AI integration with confidence filtering
- Uses a magic number so it does not count unrelated positions

## Installation

1. Download `Experts/AITradingEA.mq5` from this repository.
2. In MT5, select **File → Open Data Folder**.
3. Copy the file to `MQL5/Experts/` (create the directory if necessary).
4. Open MetaEditor, open `AITradingEA.mq5`, and press **F7** to compile.
5. In MT5, refresh **Navigator → Expert Advisors**, then attach the EA to a chart.
6. Enable **Algo Trading**.

## Basic setup

Recommended first test settings:

- `TradingMode = MODE_INTRADAY`
- `UseAISignals = false`
- `LotMode = LOT_FIXED`, `FixedLots = 0.01`
- `MaxTradesPerSymbol = 1`
- `MaxTradesTotal = 1`
- `DailyLossLimitPercent = 1.0`

The EA selects M5 for scalping, M15 for intraday, and H4 for swing trading when `SignalTimeframe = PERIOD_CURRENT`. You can override this explicitly.

## AI endpoint contract

Set `UseAISignals = true`, enter your HTTPS endpoint in `AIEndpoint`, and optionally enter an authorization value such as `Bearer YOUR_TOKEN` in `AIAuthHeader`.

The EA sends JSON similar to:

```json
{"symbol":"EURUSD","mode":"INTRADAY","timeframe":"PERIOD_M15","bid":1.0801,"ask":1.0802,"ema_fast":1.0799,"ema_slow":1.0795,"rsi":56.2,"atr":0.0011}
```

Your endpoint should return JSON like:

```json
{"action":"BUY","confidence":0.78,"sl_points":300,"tp_points":600}
```

Valid actions are `BUY`, `SELL`, and `HOLD`. `confidence` must be at least `MinimumAIConfidence`; otherwise the trade is ignored. `sl_points` and `tp_points` are optional and fall back to the EA inputs. If the request fails and `UseTechnicalFallback = true`, the EMA/RSI strategy is used.

### Enable WebRequest in MT5

1. Go to **Tools → Options → Expert Advisors**.
2. Enable **Allow WebRequest for listed URL**.
3. Add the exact base URL of your API, for example `https://your-domain.example`.
4. Restart the EA and inspect the **Experts** tab for HTTP status messages.

Use HTTPS, authenticate requests, validate the incoming symbol and risk parameters on your server, and do not expose secrets in screenshots or source code.

## Backtesting

1. Open **View → Strategy Tester**.
2. Select `AITradingEA`, a symbol, and a timeframe matching `SignalTimeframe`.
3. Use real ticks where available.
4. Start with `UseAISignals = false` because Strategy Tester WebRequest behavior depends on terminal configuration and a live endpoint is not deterministic.
5. Review drawdown, spread sensitivity, trade frequency, and out-of-sample performance.
6. Forward-test on a demo account before live deployment.

## Important implementation notes

- Risk-based lots use `SYMBOL_TRADE_TICK_VALUE`, `SYMBOL_TRADE_TICK_SIZE`, stop distance, and broker volume limits.
- The daily loss guard resets at the broker server day and blocks new entries after the configured loss percentage; it does not forcibly close existing positions.
- The EA uses the previous completed candle for technical indicator decisions.
- Broker minimum stop distances, contract specifications, and netting/hedging rules still apply. Check the `Experts` and `Journal` tabs after attaching it.
- AI is an optional decision input, not a guarantee of profitability.
