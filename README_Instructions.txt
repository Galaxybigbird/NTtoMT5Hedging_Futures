# NinjaTrader to MT5 Hedge Bot

This tool automatically copies trades from NinjaTrader to MetaTrader 5 (MT5) in the opposite direction, creating a perfect hedge.

## Quick Start Guide

1. Extract folder to any folder location you want to put it in

2. **Setup NinjaTrader**
      - Open NinjaTrader
      - Go to Tools > Import > NinjaScript
      - Select the `TradeLoggerIndicator.cs` file from this package
      - Add the indicator to your chart:
         1. Right-click on your chart
         2. Select Indicators
         3. Find "TradeLoggerIndicator"
         4. Set "Account Name" to your NinjaTrader account name
         5. Click OK

3. **Setup MetaTrader 5**
      - Open MetaTrader 5
      - Go to File > Open Data Folder
      - Open the "MQL5" folder
      - Copy the `HedgeReceiver.ex5` file to the "Experts" folder
      - Under Tools > Options > WebRequest URLs, paste these 2 URLs in and enable Allow DLL & Allow Webrequests:
            http://localhost.com:5000/mt5/get_trade
            http://localhost.com:5000/mt5/trade_result
      - Add the EA to your chart:

4. **Start the System**
      - Double-click `start_bridge.bat` to start the bridge
      - Wait for the message "Bridge server started successfully"
      - You're ready to trade!

## How It Works

   1. Place a trade in NinjaTrader
   2. The indicator detects your trade and sends it to the bridge
   3. The EA in MT5 receives the trade and places an opposite trade
   4. When you close your NinjaTrader trade, the MT5 trade will also close 
      NOTE: Don't press the "Close" button to close your trade, it will open another hedging trade
      in your Metatrader, must either market or limit buy/sell it. It's a bug im working on fixing

## Important Settings

### NinjaTrader Indicator Settings
   - Account Name: Your NinjaTrader account name (must match exactly)
   - Python Server URL: Leave as default (http://localhost.com:5000/log_trade)

### MT5 EA Settings
   - DefaultLot: Base lot size (e.g., 0.1)
   - If you trade 2 contracts in NinjaTrader, MT5 will trade 0.2 lots
   - BridgeURL: Leave as default (http://localhost.com:5000)

## Troubleshooting

1. **"Trade Logger Active" not showing on NinjaTrader chart**
      - Remove and re-add the indicator
      - Make sure your account name is correct
      - it takes about a minute to show up so give it a bit of time for "Trade Logger Active" to show up on
      the top right of your chart

2. **MT5 not placing trades**
      - Check that AutoTrading is enabled (green "🔒" button)
      - Make sure the bridge is running
      - Add USTECH to your Market Watch if trading NQ, make sure symbols are the same instruments

3. **Bridge not starting**
      - Make sure Python is installed and added to PATH
      - Try running as Administrator

## Need Help?

If you encounter any issues:
1. Check the Output window in NinjaTrader
2. Check the Experts tab in MT5
3. Check the bridge console window for error messages

## Safety Notes

- Always test with small positions first
- Monitor both platforms to ensure trades are being copied correctly
- Keep the bridge running while trading
- Make sure your MT5 account has enough margin for hedging trades 