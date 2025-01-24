#property copyright "Copyright 2024"
#property link      ""
#property version   "1.35"
#property strict
#property description "Hedge Receiver EA for NinjaTrader trades"

// Constants
#define ERR_TRADE_HEDGE_PROHIBITED 4756

// Input parameters
input string    BridgeURL = "http://localhost.com:5000";  // Bridge Server URL
input double    DefaultLot = 0.1;     // Default lot size if not specified
input int       Slippage  = 200;       // Maximum slippage in points
input int       PollInterval = 1;     // How often to check for trades (seconds)
input int       MagicNumber = 12345;  // Magic number for trades

//+------------------------------------------------------------------+
//| Simple JSON parser class                                          |
//+------------------------------------------------------------------+
class JSONParser
{
private:
    string json_str;
    int    pos;
    
public:
    JSONParser(string js) { json_str = js; pos = 0; }
    
    // Skip whitespace
    void SkipWhitespace()
    {
        while(pos < StringLen(json_str))
        {
            ushort ch = StringGetCharacter(json_str, pos);
            if(ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r')
                break;
            pos++;
        }
    }
    
    // Parse a string value
    bool ParseString(string &value)
    {
        if(pos >= StringLen(json_str)) return false;
        
        SkipWhitespace();
        
        // Must start with quote
        if(StringGetCharacter(json_str, pos) != '"')
            return false;
        pos++;
        
        value = "";
        while(pos < StringLen(json_str))
        {
            ushort ch = StringGetCharacter(json_str, pos);
            if(ch == '"')
            {
                pos++;
                return true;
            }
            value += ShortToString(ch);
            pos++;
        }
        return false;
    }
    
    // Parse a number value
    bool ParseNumber(double &value)
    {
        if(pos >= StringLen(json_str)) return false;
        
        SkipWhitespace();
        
        string num = "";
        bool hasDecimal = false;
        
        // Optional minus sign
        if(StringGetCharacter(json_str, pos) == '-')
        {
            num += "-";
            pos++;
        }
        
        while(pos < StringLen(json_str))
        {
            ushort ch = StringGetCharacter(json_str, pos);
            if(ch >= '0' && ch <= '9')
            {
                num += ShortToString(ch);
            }
            else if(ch == '.' && !hasDecimal)
            {
                num += ".";
                hasDecimal = true;
            }
            else
                break;
            pos++;
        }
        
        value = StringToDouble(num);
        return true;
    }
    
    // Parse a boolean value
    bool ParseBool(bool &value)
    {
        if(pos >= StringLen(json_str)) return false;
        
        SkipWhitespace();
        
        if(pos + 4 <= StringLen(json_str) && StringSubstr(json_str, pos, 4) == "true")
        {
            value = true;
            pos += 4;
            return true;
        }
        
        if(pos + 5 <= StringLen(json_str) && StringSubstr(json_str, pos, 5) == "false")
        {
            value = false;
            pos += 5;
            return true;
        }
        
        return false;
    }
    
    // Skip a value (string, number, boolean, null, object, or array)
    void SkipValue()
    {
        SkipWhitespace();
        
        if(pos >= StringLen(json_str)) return;
        
        ushort ch = StringGetCharacter(json_str, pos);
        
        if(ch == '"')  // String
        {
            pos++;
            while(pos < StringLen(json_str))
            {
                if(StringGetCharacter(json_str, pos) == '"')
                {
                    pos++;
                    break;
                }
                pos++;
            }
        }
        else if(ch == '{')  // Object
        {
            int depth = 1;
            pos++;
            while(pos < StringLen(json_str) && depth > 0)
            {
                ch = StringGetCharacter(json_str, pos);
                if(ch == '{') depth++;
                if(ch == '}') depth--;
                pos++;
            }
        }
        else if(ch == '[')  // Array
        {
            int depth = 1;
            pos++;
            while(pos < StringLen(json_str) && depth > 0)
            {
                ch = StringGetCharacter(json_str, pos);
                if(ch == '[') depth++;
                if(ch == ']') depth--;
                pos++;
            }
        }
        else if(ch == 't' || ch == 'f')  // true or false
        {
            while(pos < StringLen(json_str))
            {
                ch = StringGetCharacter(json_str, pos);
                if(ch == ',' || ch == '}' || ch == ']') break;
                pos++;
            }
        }
        else if(ch == 'n')  // null
        {
            pos += 4;  // Skip "null"
        }
        else  // Number
        {
            while(pos < StringLen(json_str))
            {
                ch = StringGetCharacter(json_str, pos);
                if(ch == ',' || ch == '}' || ch == ']') break;
                pos++;
            }
        }
    }
    
    // Parse the entire trade object
    bool ParseObject(string &symbol, string &type, double &volume, double &price, string &comment, bool &is_close)
    {
        if(pos >= StringLen(json_str)) return false;
        
        SkipWhitespace();
        
        // Must start with {
        if(StringGetCharacter(json_str, pos) != '{')
            return false;
        pos++;
        
        // Initialize required field flags
        bool has_symbol = false;
        bool has_type = false;
        bool has_volume = false;
        bool has_price = false;
        bool has_comment = false;
        bool has_is_close = false;
        
        while(pos < StringLen(json_str))
        {
            SkipWhitespace();
            
            // Check for end of object
            if(StringGetCharacter(json_str, pos) == '}')
            {
                pos++;
                // Verify all required fields were found
                return has_symbol && has_type && has_volume && has_price && has_comment && has_is_close;
            }
            
            // Parse the key
            string key;
            if(!ParseString(key))
                return false;
                
            SkipWhitespace();
            
            // Must have a colon
            if(StringGetCharacter(json_str, pos) != ':')
                return false;
            pos++;
            
            // Parse the value based on the key
            if(key == "symbol")
            {
                if(!ParseString(symbol)) return false;
                has_symbol = true;
            }
            else if(key == "type")
            {
                if(!ParseString(type)) return false;
                has_type = true;
            }
            else if(key == "volume")
            {
                if(!ParseNumber(volume)) return false;
                has_volume = true;
            }
            else if(key == "price")
            {
                if(!ParseNumber(price)) return false;
                has_price = true;
            }
            else if(key == "comment")
            {
                if(!ParseString(comment)) return false;
                has_comment = true;
            }
            else if(key == "is_close")
            {
                if(!ParseBool(is_close)) return false;
                has_is_close = true;
            }
            else
            {
                // Skip unknown field value
                SkipValue();
            }
            
            SkipWhitespace();
            
            // Skip comma if present
            if(StringGetCharacter(json_str, pos) == ',')
                pos++;
        }
        
        return false;  // Reached end of input without finding closing }
    }
};

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // Check if automated trading is allowed
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      MessageBox("Please enable automated trading in MT5 settings!", "Error", MB_OK|MB_ICONERROR);
      return INIT_FAILED;
   }
   
   // Check account type and warn if hedging is not available
   ENUM_ACCOUNT_MARGIN_MODE margin_mode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(margin_mode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("Warning: Account does not support hedging. Operating in netting mode.");
      Print("Current margin mode: ", margin_mode);
   }
   
   // Add URL to allowed list
   string url = BridgeURL + "/mt5/get_trade";
   char tmp[];
   string headers = "";
   if(!WebRequest("GET", url, headers, 0, tmp, tmp, headers))
   {
      int error = GetLastError();
      if(error == ERR_FUNCTION_NOT_ALLOWED)
      {
         MessageBox("Please allow WebRequest for " + url, "Error", MB_OK|MB_ICONERROR);
         string terminal_data_path = TerminalInfoString(TERMINAL_DATA_PATH);
         string filename = terminal_data_path + "\\MQL5\\config\\terminal.ini";
         Print("Add the following URL to " + filename + " in [WebRequest] section:");
         Print(url);
         return INIT_FAILED;
      }
   }
   
   Print("HedgeReceiver EA initialized successfully");
   EventSetMillisecondTimer(PollInterval * 1000);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Timer function                                                     |
//+------------------------------------------------------------------+
void OnTimer()
{
   string response = GetTradeFromBridge();
   if(response == "") return;
   
   Print("Response: ", response);
   Print("");
   
   Print("Processing trade response...");
   
   // Parse the JSON response
   JSONParser parser(response);
   string symbol = "", type = "", comment = "";
   double volume = 0.0, price = 0.0;
   bool is_close = false;
   
   if(!parser.ParseObject(symbol, type, volume, price, comment, is_close))
   {
      Print("Failed to parse JSON response");
      return;
   }
   
   // Scale volume to match DefaultLot setting
   volume = volume * DefaultLot;
   
   Print("Trade data parsed successfully:");
   Print("- Symbol: ", symbol);
   Print("- Type: ", type);
   Print("- Volume: ", volume);
   Print("- Price: ", price);
   Print("- Is Close: ", is_close);
   Print("- Comment: ", comment);
   
   // Check if symbol exists in Market Watch
   Print("Checking symbol: ", symbol);
   if(!SymbolSelect(symbol, true))
   {
      Print("Symbol not found in Market Watch: ", symbol);
      return;
   }
   Print("Symbol found in Market Watch: ", symbol);
   
   // Process the trade
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   // Set up the trade request
   request.action = TRADE_ACTION_DEAL;
   request.symbol = symbol;
   request.volume = volume;
   request.magic = MagicNumber;
   request.comment = comment;
   request.type_filling = ORDER_FILLING_FOK;
   request.deviation = Slippage;
   
   // If this is a close request, first close any existing positions
   if(is_close)
   {
      Print("Total positions: ", PositionsTotal());
      bool found_position = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         
         if(!PositionSelectByTicket(ticket)) continue;
         
         string pos_symbol = PositionGetString(POSITION_SYMBOL);
         if(pos_symbol != symbol) continue;
         
         double pos_volume = PositionGetDouble(POSITION_VOLUME);
         ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         
         Print("Found position - Type: ", pos_type == POSITION_TYPE_BUY ? "Buy" : "Sell", ", Volume: ", pos_volume);
         
         request.action = TRADE_ACTION_DEAL;
         request.position = ticket;
         request.volume = pos_volume;
         request.type = pos_type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         request.price = SymbolInfoDouble(symbol, request.type == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
         
         Print("Closing position - Type: ", request.type == ORDER_TYPE_BUY ? "Buy" : "Sell", ", Volume: ", request.volume, ", Price: ", request.price);
         
         if(!OrderSend(request, result))
         {
            Print("Failed to close position. Error: ", GetLastError());
            continue;
         }
         
         Print("Position closed successfully");
         found_position = true;
      }
      
      if(found_position)
      {
         SendTradeResult(symbol, volume, result.order, true);
         return;
      }
      else
      {
         Print("No positions found to close, proceeding to open new position");
         // Continue to open new position since there was nothing to close
         is_close = false;  // Reset is_close flag since we're opening a new position
      }
   }
   else
   {
      // For new trades, first close any opposite positions
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket <= 0) continue;
         
         if(!PositionSelectByTicket(ticket)) continue;
         
         string pos_symbol = PositionGetString(POSITION_SYMBOL);
         if(pos_symbol != symbol) continue;
         
         ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         bool is_opposite = (type == "Buy" && pos_type == POSITION_TYPE_SELL) || 
                          (type == "Sell" && pos_type == POSITION_TYPE_BUY);
         
         Print("Checking position - Type: ", pos_type == POSITION_TYPE_BUY ? "Buy" : "Sell", 
               ", Incoming type: ", type, 
               ", Is opposite: ", is_opposite ? "true" : "false");
         
         if(is_opposite)
         {
            request.action = TRADE_ACTION_DEAL;
            request.position = ticket;
            request.volume = PositionGetDouble(POSITION_VOLUME);
            request.type = pos_type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
            request.price = SymbolInfoDouble(symbol, request.type == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
            
            Print("Closing opposite position before new trade");
            
            if(!OrderSend(request, result))
            {
               Print("Failed to close opposite position. Error: ", GetLastError());
               return;
            }
            
            Print("Opposite position closed successfully");
            Sleep(100); // Add a small delay to allow MT5 to process the position closure
         }
      }
   }
   
   // If this was just a close request and we didn't find a position to close, we're done
   if(is_close) return;
   
   // Place the market order - use same direction as NinjaTrader since we're hedging
   request.type = type == "Buy" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = SymbolInfoDouble(symbol, request.type == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
   request.volume = volume;
   
   Print("Placing market order: ", request.type == ORDER_TYPE_BUY ? "Buy" : "Sell", " ", request.volume, " lots at ", request.price);
   
   // Try up to 3 times with increasing delays if we get ERR_TRADE_HEDGE_PROHIBITED
   for(int attempt = 1; attempt <= 3; attempt++)
   {
      if(OrderSend(request, result))
      {
         Print("Order placed successfully. Ticket: ", result.order);
         SendTradeResult(symbol, volume, result.order, false);
         return;
      }
      
      int error = GetLastError();
      if(error == ERR_TRADE_HEDGE_PROHIBITED)
      {
         Print("Attempt ", attempt, " failed with ERR_TRADE_HEDGE_PROHIBITED. Waiting before retry...");
         Sleep(100 * attempt); // Increase delay with each attempt
         continue;
      }
      
      Print("Order failed. Error: ", error);
      return;
   }
   
   Print("Failed to place order after 3 attempts");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Main trading logic is handled in OnTimer
}

bool SendTradeResult(string symbol, double volume, ulong ticket, bool is_close)
{
   string result = StringFormat("{\"status\":\"success\",\"ticket\":%I64u,\"symbol\":\"%s\",\"volume\":%.2f,\"is_close\":%s}",
                               ticket, symbol, volume, is_close ? "true" : "false");
   
   Print("Preparing to send result: ", result);
   
   char result_data[];
   StringToCharArray(result, result_data);
   
   string headers = "Content-Type: application/json\r\n";
   char response_data[];
   string response_headers;
   
   int res = WebRequest("POST", BridgeURL + "/mt5/trade_result", headers, 0, result_data, response_data, response_headers);
   
   if(res == -1)
   {
      Print("Error in WebRequest. Error code: ", GetLastError());
      return false;
   }
   
   Print("Result sent to bridge successfully");
   return true;
}

bool ClosePosition(string symbol, double volume, ENUM_POSITION_TYPE type)
{
   Print("Looking for position to close - Symbol: ", symbol, ", Volume: ", volume, ", Type: ", type);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(!PositionSelectByTicket(ticket)) continue;
      
      string pos_symbol = PositionGetString(POSITION_SYMBOL);
      double pos_volume = PositionGetDouble(POSITION_VOLUME);
      ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      Print("Checking position - Ticket: ", ticket, ", Symbol: ", pos_symbol, ", Volume: ", pos_volume, ", Type: ", pos_type);
      
      if(pos_symbol == symbol && pos_type == type)
      {
         Print("Found matching position to close");
         
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         
         request.action = TRADE_ACTION_DEAL;
         request.position = ticket;
         request.symbol = symbol;
         request.volume = volume;
         request.deviation = Slippage;
         request.magic = MagicNumber;
         request.type = type == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         request.price = SymbolInfoDouble(symbol, type == POSITION_TYPE_BUY ? SYMBOL_BID : SYMBOL_ASK);
         request.comment = "Close hedge position";
         
         Print("Sending close request - Type: ", request.type, ", Price: ", request.price);
         
         if(!OrderSend(request, result))
         {
            Print("OrderSend error: ", GetLastError());
            return false;
         }
         
         Print("Position closed successfully");
         return true;
      }
   }
   
   Print("No matching position found to close");
   return false;
}

string GetTradeFromBridge()
{
   char response_data[];
   string headers = "";
   string response_headers;
   int web_result = WebRequest("GET", BridgeURL + "/mt5/get_trade", headers, 0, response_data, response_data, response_headers);
   
   if(web_result == -1)
   {
      Print("Error in WebRequest. Error code: ", GetLastError());
      return "";
   }
   
   string response_str = CharArrayToString(response_data);
   
   // Check for no trades
   if(StringFind(response_str, "no_trade") >= 0)
   {
      return "";
   }
   
   return response_str;
} 