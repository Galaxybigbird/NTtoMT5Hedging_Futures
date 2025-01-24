#region Using declarations
using System;
using System.Net.Http;
using System.Text;
using System.Collections.Generic;
using NinjaTrader.Cbi;
using NinjaTrader.Gui;
using NinjaTrader.Gui.Chart;
using NinjaTrader.Data;
using NinjaTrader.NinjaScript;
using NinjaTrader.Core.FloatingPoint;
using System.ComponentModel;
using System.ComponentModel.DataAnnotations;
using System.Windows.Media;
using System.Windows;
using NinjaTrader.Gui.Tools;
using NinjaTrader.NinjaScript.DrawingTools;

#endregion

namespace NinjaTrader.NinjaScript.Indicators
{
    public class TradeLoggerIndicator : Indicator
    {
        private Account selectedAccount;
        private bool statusTextDrawn;
        private readonly HttpClient httpClient;

        public TradeLoggerIndicator()
        {
            httpClient = new HttpClient();
        }

        private string accountName = string.Empty;
        
        [NinjaScriptProperty]
        [Display(Name = "Account", GroupName = "Parameters", Order = 0)]
        [TypeConverter(typeof(AccountNameConverter))]
        public string AccountName
        { 
            get { return accountName; }
            set
            {
                accountName = value;
                if (State == State.SetDefaults || State == State.Configure)
                {
                    if (Account.All != null)
                    {
                        foreach (Account acc in Account.All)
                        {
                            if (acc.Name == value)
                            {
                                selectedAccount = acc;
                                break;
                            }
                        }
                    }
                }
            }
        }

        // Custom TypeConverter for Account dropdown
        public class AccountNameConverter : TypeConverter
        {
            public override StandardValuesCollection GetStandardValues(ITypeDescriptorContext context)
            {
                List<string> accountNames = new List<string>();
                if (Account.All != null)
                {
                    foreach (Account account in Account.All)
                    {
                        // Only add accounts that are connected/active
                        if (account.Connection != null && account.Connection.Status == ConnectionStatus.Connected)
                        {
                            accountNames.Add(account.Name);
                        }
                    }
                }
                return new StandardValuesCollection(accountNames);
            }

            public override bool GetStandardValuesSupported(ITypeDescriptorContext context)
            {
                return true;
            }

            public override bool GetStandardValuesExclusive(ITypeDescriptorContext context)
            {
                return true;
            }
        }

        [NinjaScriptProperty]
        [Display(Name = "Python Server URL", GroupName = "Parameters", Order = 1)]
        public string PythonServerUrl { get; set; } = "http://localhost:5000/log_trade";

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Description = "Logs executed trades for this instrument to a Python server.";
                Name = "TradeLoggerIndicator";
                IsOverlay = true;
            }
            else if (State == State.Configure)
            {
                // Force clear and print debug info
                ClearOutputWindow();
                Print("====== TradeLoggerIndicator Debug Info ======");
                Print($"Current State: {State}");
                Print($"Selected Account: '{AccountName}'");
                Print("Available accounts:");
                
                bool foundAny = false;
                foreach (Account acc in Account.All)
                {
                    // Only check connected/active accounts
                    if (acc.Connection != null && acc.Connection.Status == ConnectionStatus.Connected)
                    {
                        foundAny = true;
                        Print($"- Account Name: '{acc.Name}'");
                        if (acc.Name == AccountName)
                        {
                            selectedAccount = acc;
                            Print($"Found matching account: '{acc.Name}'");
                        }
                    }
                }
                
                if (!foundAny)
                {
                    Print("WARNING: No connected accounts found!");
                }

                if (selectedAccount == null)
                {
                    Print($"ERROR: Account '{AccountName}' not found in available accounts!");
                    return;
                }

                Print($"Python Server URL: {PythonServerUrl}");
                Print("=======================================");

                selectedAccount.ExecutionUpdate += OnExecutionUpdate;
            }
            else if (State == State.DataLoaded)
            {
                Print("TradeLoggerIndicator: Data Loaded");
            }
            else if (State == State.Historical)
            {
                Print("TradeLoggerIndicator: Historical data processing");
            }
            else if (State == State.Realtime)
            {
                Print("TradeLoggerIndicator: Entering Realtime mode");
            }
            else if (State == State.Terminated)
            {
                Print("TradeLoggerIndicator: Terminating");
                if (selectedAccount != null)
                {
                    selectedAccount.ExecutionUpdate -= OnExecutionUpdate;
                }
                if (httpClient != null)
                {
                    httpClient.Dispose();
                }
            }
        }

        protected override void OnBarUpdate()
        {
            if (State == State.Realtime && !statusTextDrawn)
            {
                // Draw status text at the top-right of the chart
                Draw.TextFixed(this, "StatusText", "Trade Logger Active", 
                    TextPosition.TopRight,
                    Brushes.LimeGreen,
                    new NinjaTrader.Gui.Tools.SimpleFont("Arial", 12),
                    Brushes.Transparent,
                    Brushes.Transparent,
                    0);
                
                statusTextDrawn = true;
                Print("====== TradeLoggerIndicator Status ======");
                Print($"Account being monitored: '{AccountName}'");
                Print($"Instrument being monitored: {Instrument.FullName}");
                Print($"Python Server URL: {PythonServerUrl}");
                Print("Trade Logger Indicator started and ready to monitor trades.");
                Print("=========================================");
            }
        }

        private async void OnExecutionUpdate(object sender, ExecutionEventArgs e)
        {
            Print($"====== Execution Update Received ======");
            Print($"Execution Account: {e.Execution.Account.Name}");
            Print($"Execution Instrument: {e.Execution.Instrument.FullName}");
            Print($"Current Instrument: {Instrument.FullName}");
            Print($"Order State: {e.Execution.Order.OrderState}");
            Print($"Order Action: {e.Execution.Order.OrderAction}");
            Print($"Order Quantity: {e.Execution.Quantity}");
            Print($"Order Price: {e.Execution.Price}");

            if (e.Execution.Instrument.FullName != Instrument.FullName)
            {
                Print("Skipping - different instrument");
                return;
            }

            // Process both Working and Filled orders
            if (e.Execution.Order.OrderState == OrderState.Filled || e.Execution.Order.OrderState == OrderState.Working)
            {
                Print($"Processing {e.Execution.Order.OrderState} order");
                // Get the current position for this instrument from the account's positions
                Position position = null;
                foreach (Position pos in e.Execution.Account.Positions)
                {
                    Print($"Checking position - Instrument: {pos.Instrument.FullName}, Quantity: {pos.Quantity}");
                    if (pos.Instrument == e.Execution.Instrument)
                    {
                        position = pos;
                        Print("Found matching position");
                        break;
                    }
                }
                
                // Determine if this is an exit order by checking if it reduces/closes a position
                bool isExit = false;
                if (position != null)
                {
                    isExit = (e.Execution.Order.OrderAction == OrderAction.Buy && position.Quantity < 0) ||  // Buying to close short
                             (e.Execution.Order.OrderAction == OrderAction.Sell && position.Quantity > 0);   // Selling to close long
                }

                Print($"Order Action: {e.Execution.Order.OrderAction}, Position Quantity: {position?.Quantity}, IsExit: {isExit}");

                var tradeData = new
                {
                    time = e.Execution.Time.ToString("o"),
                    instrument = e.Execution.Instrument.MasterInstrument.Name,
                    action = e.Execution.Order.OrderAction.ToString(),
                    quantity = e.Execution.Quantity,
                    price = e.Execution.Price,
                    account = e.Execution.Account.Name,
                    is_exit = isExit
                };

                try
                {
                    string jsonData = SimpleJson.SerializeObject(tradeData);
                    Print($"Sending trade data to Python server: {jsonData}");
                    var content = new StringContent(jsonData, Encoding.UTF8, "application/json");

                    var response = await httpClient.PostAsync(PythonServerUrl, content);
                    if (response.IsSuccessStatusCode)
                    {
                        Print($"TradeLoggerIndicator: Trade sent to Python server successfully");
                    }
                    else
                    {
                        Print($"TradeLoggerIndicator: Failed to send trade to Python server. Status: {response.StatusCode}");
                    }
                }
                catch (Exception ex)
                {
                    Print($"TradeLoggerIndicator: Error sending trade to Python server - {ex.Message}");
                }
            }
            else
            {
                Print($"Skipping - order state is {e.Execution.Order.OrderState}");
            }
            Print("======================================");
        }
    }

    // Simple JSON serializer to avoid external dependencies
    internal static class SimpleJson
    {
        public static string SerializeObject(object obj)
        {
            if (obj == null) return "null";
            
            var properties = obj.GetType().GetProperties();
            var jsonPairs = new string[properties.Length];
            
            for (int i = 0; i < properties.Length; i++)
            {
                var prop = properties[i];
                var value = prop.GetValue(obj);
                var serializedValue = SerializeValue(value);
                jsonPairs[i] = $"\"{prop.Name.ToLower()}\":{serializedValue}";
            }
            
            return "{" + string.Join(",", jsonPairs) + "}";
        }

        private static string SerializeValue(object value)
        {
            if (value == null) return "null";
            if (value is string) return $"\"{value}\"";
            if (value is bool) return value.ToString().ToLower();
            if (value is DateTime dt) return $"\"{dt:o}\"";
            if (value.GetType().IsValueType) return value.ToString();
            return SerializeObject(value);
        }
    }
}

#region NinjaScript generated code. Neither change nor remove.

namespace NinjaTrader.NinjaScript.Indicators
{
    public partial class Indicator : NinjaTrader.Gui.NinjaScript.IndicatorRenderBase
    {
        private TradeLoggerIndicator[] cacheTradeLoggerIndicator;
        public TradeLoggerIndicator TradeLoggerIndicator(string accountName, string pythonServerUrl)
        {
            return TradeLoggerIndicator(Input, accountName, pythonServerUrl);
        }

        public TradeLoggerIndicator TradeLoggerIndicator(ISeries<double> input, string accountName, string pythonServerUrl)
        {
            if (cacheTradeLoggerIndicator != null)
                for (int idx = 0; idx < cacheTradeLoggerIndicator.Length; idx++)
                    if (cacheTradeLoggerIndicator[idx] != null && cacheTradeLoggerIndicator[idx].AccountName == accountName && cacheTradeLoggerIndicator[idx].PythonServerUrl == pythonServerUrl && cacheTradeLoggerIndicator[idx].EqualsInput(input))
                        return cacheTradeLoggerIndicator[idx];
            return CacheIndicator<TradeLoggerIndicator>(new TradeLoggerIndicator(){ AccountName = accountName, PythonServerUrl = pythonServerUrl }, input, ref cacheTradeLoggerIndicator);
        }
    }
}

namespace NinjaTrader.NinjaScript.MarketAnalyzerColumns
{
    public partial class MarketAnalyzerColumn : MarketAnalyzerColumnBase
    {
        public Indicators.TradeLoggerIndicator TradeLoggerIndicator(string accountName, string pythonServerUrl)
        {
            return indicator.TradeLoggerIndicator(Input, accountName, pythonServerUrl);
        }

        public Indicators.TradeLoggerIndicator TradeLoggerIndicator(ISeries<double> input , string accountName, string pythonServerUrl)
        {
            return indicator.TradeLoggerIndicator(input, accountName, pythonServerUrl);
        }
    }
}

namespace NinjaTrader.NinjaScript.Strategies
{
    public partial class Strategy : NinjaTrader.Gui.NinjaScript.StrategyRenderBase
    {
        public Indicators.TradeLoggerIndicator TradeLoggerIndicator(string accountName, string pythonServerUrl)
        {
            return indicator.TradeLoggerIndicator(Input, accountName, pythonServerUrl);
        }

        public Indicators.TradeLoggerIndicator TradeLoggerIndicator(ISeries<double> input , string accountName, string pythonServerUrl)
        {
            return indicator.TradeLoggerIndicator(input, accountName, pythonServerUrl);
        }
    }
}

#endregion
