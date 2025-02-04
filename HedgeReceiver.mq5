#property link      ""
#property version   "1.61"
#property strict
#property description "Hedge Receiver EA for Go bridge server"

// Error code constant for hedging-related errors
#define ERR_TRADE_NOT_ALLOWED           4756  // Trading is prohibited

// Input parameters that can be configured in the EA settings
input string    BridgeURL = "http://127.0.0.1:5000";  // Bridge Server URL - Connection point to Go bridge
input double    DefaultLot = 0.1;     // Default lot size if not specified - Base multiplier for trade volumes
input int       Slippage  = 200;       // Maximum allowed price deviation in points
input int       PollInterval = 1;     // Frequency of checking for new trades (in seconds)
input int       MagicNumber = 12345;  // Unique identifier for trades placed by this EA
input bool      VerboseMode = false;  // Show all polling messages in Experts tab
input string    CommentPrefix = "NT_Hedge_";  // Prefix for hedge order comments

// Global variable to track the aggregated net futures position from NT trades.
// A Buy increases the net position; a Sell reduces it.
double globalFutures = 0.0;
string lastTradeTime = "";  // Track the last processed trade time

//+------------------------------------------------------------------+
//| Simple JSON parser class for processing bridge messages            |
//+------------------------------------------------------------------+
class JSONParser
{
private:
    string json_str;    // Stores the JSON string to be parsed
    int    pos;         // Current position in the JSON string during parsing
    
public:
    // Constructor initializes parser with JSON string
    JSONParser(string js) { json_str = js; pos = 0; }
    
    // Utility function to skip whitespace characters
    void SkipWhitespace()
    {
        while(pos < StringLen(json_str))
        {
            ushort ch = StringGetCharacter(json_str, pos);
            // Skip spaces, tabs, newlines, and carriage returns
            if(ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r')
                break;
            pos++;
        }
    }
    
    // Parse a JSON string value enclosed in quotes
    bool ParseString(string &value)
    {
        if(pos >= StringLen(json_str)) return false;
        
        SkipWhitespace();
        
        // Verify string starts with quote
        if(StringGetCharacter(json_str, pos) != '"')
            return false;
        pos++;
        
        // Build string until closing quote
        value = "";
        while(pos < StringLen(json_str))
        {
            ushort ch = StringGetCharacter(json_str, pos);
            if(ch == '"')
            {
                pos++;
                return true;
            }
            value += CharToString((uchar)ch);
            pos++;
        }
        return false;
    }
    
    // Parse a numeric value (integer or decimal)
    bool ParseNumber(double &value)
    {
        if(pos >= StringLen(json_str)) return false;
        
        SkipWhitespace();
        
        string num = "";
        bool hasDecimal = false;
        
        // Handle negative numbers
        if(StringGetCharacter(json_str, pos) == '-')
        {
            num += "-";
            pos++;
        }
        
        // Build number string including decimal point if present
        while(pos < StringLen(json_str))
        {
            ushort ch = StringGetCharacter(json_str, pos);
            if(ch >= '0' && ch <= '9')
            {
                num += CharToString((uchar)ch);
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
        
        // Convert string to double
        value = StringToDouble(num);
        return true;
    }
    
    // Parse boolean true/false values
    bool ParseBool(bool &value)
    {
        if(pos >= StringLen(json_str)) return false;
        
        SkipWhitespace();
        
        // Check for "true" literal
        if(pos + 4 <= StringLen(json_str) && StringSubstr(json_str, pos, 4) == "true")
        {
            value = true;
            pos += 4;
            return true;
        }
        
        // Check for "false" literal
        if(pos + 5 <= StringLen(json_str) && StringSubstr(json_str, pos, 5) == "false")
        {
            value = false;
            pos += 5;
            return true;
        }
        
        return false;
    }
    
    // Skip over any JSON value without parsing it
    void SkipValue()
    {
        SkipWhitespace();
        
        if(pos >= StringLen(json_str)) return;
        
        ushort ch = StringGetCharacter(json_str, pos);
        
        // Handle different value types
        if(ch == '"')  // Skip string
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
        else if(ch == '{')  // Skip object
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
        else if(ch == '[')  // Skip array
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
        else if(ch == 't' || ch == 'f')  // Skip boolean
        {
            while(pos < StringLen(json_str))
            {
                ch = StringGetCharacter(json_str, pos);
                if(ch == ',' || ch == '}' || ch == ']') break;
                pos++;
            }
        }
        else if(ch == 'n')  // Skip null
        {
            pos += 4;
        }
        else  // Skip number
        {
            while(pos < StringLen(json_str))
            {
                ch = StringGetCharacter(json_str, pos);
                if(ch == ',' || ch == '}' || ch == ']') break;
                pos++;
            }
        }
    }
    
    // Parse a complete trade object from JSON
    bool ParseObject(string &type, double &volume, double &price, string &executionId, bool &isExit)
    {
        // Skip any leading whitespace and ensure object starts with '{'
        SkipWhitespace();
        if(StringGetCharacter(json_str, pos) != '{')
            return false;
        pos++; // skip '{'

        // Initialize defaults
        type = "";
        volume = 0.0;
        price = 0.0;
        executionId = "";
        isExit = false;

        // Loop through key/value pairs
        while(true)
        {
            SkipWhitespace();
            if(pos >= StringLen(json_str))
                return false;

            ushort ch = StringGetCharacter(json_str, pos);
            // End of object
            if(ch == '}')
            {
                pos++; // skip '}'
                break;
            }
            
            // Parse the key
            string key = "";
            if(!ParseString(key))
                return false;
            
            SkipWhitespace();
            if(StringGetCharacter(json_str, pos) != ':')
                return false;
            pos++; // skip ':'
            SkipWhitespace();
            
            // Parse the value based on the key. Note the new checks.
            if(key=="action" || key=="type")
            {
                if(!ParseString(type))
                    return false;
            }
            else if(key=="quantity" || key=="volume")
            {
                if(!ParseNumber(volume))
                    return false;
            }
            else if(key=="price")
            {
                if(!ParseNumber(price))
                    return false;
            }
            else if(key=="executionId")
            {
                if(!ParseString(executionId))
                    return false;
            }
            else if(key=="isExit" || key=="is_close")
            {
                if(!ParseBool(isExit))
                    return false;
            }
            else
            {
                // For any unknown key, just skip its value
                SkipValue();
            }
            
            SkipWhitespace();
            // If there's a comma, continue parsing the next pair.
            if(pos < StringLen(json_str) && StringGetCharacter(json_str, pos)==',')
            {
                pos++; // skip comma
                continue;
            }
            // End of the object
            if(pos < StringLen(json_str) && StringGetCharacter(json_str, pos)=='}')
            {
                pos++; // skip closing brace
                break;
            }
        }
        return true;
    }
};

//+------------------------------------------------------------------+
//| Expert initialization function - Called when EA is first loaded    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Verify automated trading is enabled in MT5
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
   
   Print("Testing connection to bridge server...");
   
   // Test bridge connection with health check
   char tmp[];
   string headers = "";
   string response_headers;
   
   if(!WebRequest("GET", BridgeURL + "/health", headers, 0, tmp, tmp, response_headers))
   {
      int error = GetLastError();
      if(error == ERR_FUNCTION_NOT_ALLOWED)
      {
         MessageBox("Please allow WebRequest for " + BridgeURL, "Error", MB_OK|MB_ICONERROR);
         string terminal_data_path = TerminalInfoString(TERMINAL_DATA_PATH);
         string filename = terminal_data_path + "\\MQL5\\config\\terminal.ini";
         Print("Add the following URLs to " + filename + " in [WebRequest] section:");
         Print(BridgeURL + "/mt5/get_trade");
         Print(BridgeURL + "/mt5/trade_result");
         Print(BridgeURL + "/health");
         return INIT_FAILED;
      }
      Print("ERROR: Could not connect to bridge server!");
      Print("Make sure the bridge server is running and accessible at: ", BridgeURL);
      return INIT_FAILED;
   }
   
   Print("=================================");
   Print("✓ Bridge server connection test passed");
   Print("✓ HedgeReceiver EA initialized successfully");
   Print("✓ Connected to bridge server at: ", BridgeURL);
   Print("✓ Monitoring for trades...");
   Print("=================================");
   
   // Set up timer for periodic trade checks
   EventSetMillisecondTimer(PollInterval * 100);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function - Cleanup when EA is removed      |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Stop the timer to prevent further trade checks
   EventKillTimer();
}

//+------------------------------------------------------------------+
//| Helper function to extract a double value from a JSON string for |
//| a given key                                                      |
//+------------------------------------------------------------------+
double GetJSONDouble(string json, string key)
{
   string searchKey = "\"" + key + "\"";
   int keyPos = StringFind(json, searchKey);
   if(keyPos == -1)
      return 0.0;
      
   int colonPos = StringFind(json, ":", keyPos);
   if(colonPos == -1)
      return 0.0;
      
   int start = colonPos + 1;
   // Skip whitespace characters
   while(start < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, start);
      if(ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r')
         break;
      start++;
   }
   
   // Build the numeric string
   string numStr = "";
   while(start < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, start);
      if((ch >= '0' && ch <= '9') || ch == '.' || ch == '-')
      {
         numStr += CharToString((uchar)ch);
         start++;
      }
      else
         break;
   }
   
   return StringToDouble(numStr);
}

//+------------------------------------------------------------------+
//| Helper function to count open hedge positions with a given hedge origin.
//| The hedge origin is stored in the order comment as "NT_Hedge_" + origin.
//+------------------------------------------------------------------+
int CountHedgePositions(string hedgeOrigin)
{
   int count = 0;
   
   // First get total number of positions
   int total = PositionsTotal();
   
   // Loop through all positions
   for(int i = 0; i < total; i++)
   {
       // Get position ticket
       ulong ticket = PositionGetTicket(i);
       if(ticket <= 0) continue;
       
       // Select the position
       if(!PositionSelectByTicket(ticket)) continue;
       
       // Check if it's for our symbol
       if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
       
       // Check if it's our EA's position by magic number
       if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
       
       // Get and check the comment
       string comment = PositionGetString(POSITION_COMMENT);
       string searchStr = "NT_Hedge_" + hedgeOrigin;
       if(StringFind(comment, searchStr) != -1)
       {
           // Count each 0.02 lot as 1 position
           double posVolume = PositionGetDouble(POSITION_VOLUME);
           count += (int)MathRound(posVolume / DefaultLot);
       }
   }
   
   return count;
}

//+------------------------------------------------------------------+
//| Helper function to close one hedge position matching the provided hedge origin.
//| Returns true if a hedge position is closed successfully.
//+------------------------------------------------------------------+
bool CloseOneHedgePosition(string hedgeOrigin, string specificTradeId="")
{
   // First get total number of positions
   int total = PositionsTotal();
   
   // Loop through all positions
   for(int i = 0; i < total; i++)
   {
       // Get position ticket
       ulong ticket = PositionGetTicket(i);
       if(ticket <= 0) continue;
       
       // Select the position
       if(!PositionSelectByTicket(ticket)) continue;
       
       // Check if it's for our symbol
       if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
       
       // Check if it's our EA's position by magic number
       if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
       
       // Get and check the comment
       string comment = PositionGetString(POSITION_COMMENT);
       string searchStr = CommentPrefix + hedgeOrigin;
       
       // If we're looking for a specific trade ID, make sure it matches
       if(specificTradeId != "" && StringFind(comment, specificTradeId) == -1)
           continue;
       
       if(StringFind(comment, searchStr) != -1)
       {
           double posVolume = PositionGetDouble(POSITION_VOLUME);
           ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
           
           MqlTradeRequest closeRequest = {};
           MqlTradeResult closeResult = {};
           
           closeRequest.action = TRADE_ACTION_DEAL;
           closeRequest.position = ticket;
           closeRequest.symbol = _Symbol;
           closeRequest.volume = DefaultLot; // Close only one contract worth
           closeRequest.magic = MagicNumber;
           closeRequest.deviation = Slippage;
           closeRequest.type = posType == POSITION_TYPE_BUY ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
           closeRequest.price = SymbolInfoDouble(_Symbol, closeRequest.type == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
           
           Print(StringFormat("DEBUG: Closing hedge position - Ticket: %d, Volume: %.2f, Type: %s, Comment: %s", 
                 ticket, closeRequest.volume, posType == POSITION_TYPE_BUY ? "Buy" : "Sell", comment));
           
           if(OrderSend(closeRequest, closeResult))
           {
               Print("DEBUG: Hedge position closed successfully. Ticket: ", closeResult.order);
               // Extract trade ID from comment if it exists
               string closedTradeId = "";
               int idStart = StringFind(comment, "_", StringFind(comment, hedgeOrigin)) + 1;
               if(idStart > 0)
               {
                   closedTradeId = StringSubstr(comment, idStart);
                   Print("DEBUG: Extracted trade ID from closing position: ", closedTradeId);
               }
               SendTradeResult(closeRequest.volume, closeResult.order, true, closedTradeId);
               return true;
           }
           else
           {
               Print("DEBUG: Failed to close hedge position. Error: ", GetLastError());
               return false;
           }
       }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Timer function - Called periodically to check for new trades     |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Get any pending trades from the bridge.
   string response = GetTradeFromBridge();
   if(response == "") return;
   
   Print("DEBUG: Received trade response: ", response);
   
   // Check for duplicate trade based on timestamp
   string tradeTime = "";
   int timePos = StringFind(response, "\"time\":\"");
   if(timePos >= 0)
   {
       timePos += 8;  // Length of "\"time\":\""
       int timeEndPos = StringFind(response, "\"", timePos);
       if(timeEndPos > timePos)
       {
           tradeTime = StringSubstr(response, timePos, timeEndPos - timePos);
           if(tradeTime == lastTradeTime)
           {
               Print("DEBUG: Ignoring duplicate trade with time: ", tradeTime);
               return;
           }
           lastTradeTime = tradeTime;
       }
   }
   
   Print("Processing trade response...");
   
   // Parse trade information from the JSON response.
   JSONParser parser(response);
   string type = "";
   double volume = 0.0, price = 0.0;
   string executionId = "";
   bool isExit = false;
   
   if(!parser.ParseObject(type, volume, price, executionId, isExit))
   {
      Print("DEBUG: Failed to parse JSON response: ", response);
      return;
   }
   
   // Extract trade ID from response if it exists
   string tradeId = "";
   int idPos = StringFind(response, "\"id\":\"");
   if(idPos >= 0)
   {
       idPos += 6;  // Length of "\"id\":\""
       int idEndPos = StringFind(response, "\"", idPos);
       if(idEndPos > idPos)
       {
           tradeId = StringSubstr(response, idPos, idEndPos - idPos);
           Print("DEBUG: Found trade ID: ", tradeId);
       }
   }
   
   // If the response contains a "quantity" field, override the parsed volume.
   if(StringFind(response, "\"quantity\"") != -1)
   {
       double qty = GetJSONDouble(response, "quantity");
       Print("DEBUG: Found 'quantity' field in JSON, overriding parsed volume with value: ", qty);
       volume = qty;
   }
   
   // Calculate lot size based on quantity
   double lotSize = DefaultLot;  // Use fixed lot size for each hedge order
   Print("DEBUG: Using lot size for hedge orders: ", lotSize);

   // Update the global futures position based on trade type
   double prevFutures = globalFutures;
   if(type == "Buy" || type == "BuyToCover")
      globalFutures += volume;
   else if(type == "Sell" || type == "SellShort")
      globalFutures -= volume;

   Print("DEBUG: Updated global futures position: ", globalFutures);
   
   // Compute the desired hedge count from the absolute net futures.
   int desiredHedgeCount = (int)MathRound(MathAbs(globalFutures));
   Print("DEBUG: Desired hedge count: ", desiredHedgeCount);
   
   if(MathAbs(globalFutures) < 0.000001)
   {
      Print("DEBUG: Net futures position is zero. Initiating closure of all hedge orders.");
      
      int hedgeCountBuy = CountHedgePositions("Buy");
      int hedgeCountSell = CountHedgePositions("Sell");
      Print("DEBUG: Current hedge orders - Buy: ", hedgeCountBuy, ", Sell: ", hedgeCountSell);
      
      // Close all Buy hedge orders.
      while(hedgeCountBuy > 0)
      {
         if(!CloseOneHedgePosition("Buy"))
         {
            Print("ERROR: Failed to close a Buy hedge order.");
            break;
         }
         Sleep(500);
         hedgeCountBuy = CountHedgePositions("Buy");
         Print("DEBUG: Updated Buy hedge order count: ", hedgeCountBuy);
      }
      
      // Close all Sell hedge orders.
      while(hedgeCountSell > 0)
      {
         if(!CloseOneHedgePosition("Sell"))
         {
            Print("ERROR: Failed to close a Sell hedge order.");
            break;
         }
         Sleep(500);
         hedgeCountSell = CountHedgePositions("Sell");
         Print("DEBUG: Updated Sell hedge order count: ", hedgeCountSell);
      }
   }
   else
   {
      string hedgeOrigin = "";
      int hedgeOrderType = 0;
      if(globalFutures > 0)
      {
            hedgeOrigin = "Buy";
            hedgeOrderType = ORDER_TYPE_SELL;
      }
      else if(globalFutures < 0)
      {
            hedgeOrigin = "Sell";
            hedgeOrderType = ORDER_TYPE_BUY;
      }
      Print("DEBUG: Hedge Origin: ", hedgeOrigin);
      
      // Get the current number of open hedge orders for this side.
      int currentHedgeCount = CountHedgePositions(hedgeOrigin);
      Print("DEBUG: Current hedge count (", hedgeOrigin, "): ", currentHedgeCount);
      
      // If we have too many hedge orders, close them one at a time
      while(currentHedgeCount > desiredHedgeCount)
      {
            Print("DEBUG: Closing excess hedge position. Current: ", currentHedgeCount, ", Desired: ", desiredHedgeCount);
            if(!CloseOneHedgePosition(hedgeOrigin))
            {
                Print("ERROR: Failed to close an excess hedge order.");
                break;
            }
            Sleep(500);
            currentHedgeCount = CountHedgePositions(hedgeOrigin);
            Print("DEBUG: Updated hedge count after closing: ", currentHedgeCount);
      }
      
      // If we need more hedge orders, place them one at a time
      while(currentHedgeCount < desiredHedgeCount)
      {
            Print("DEBUG: Adding new hedge position. Current: ", currentHedgeCount, ", Desired: ", desiredHedgeCount);
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            request.action    = TRADE_ACTION_DEAL;
            request.symbol    = _Symbol;
            request.volume    = lotSize;
            request.magic     = MagicNumber;
            request.deviation = Slippage;
            
            // Use the trade ID directly from NinjaTrader
            request.comment   = tradeId != "" ? StringFormat("%s%s_%s", CommentPrefix, hedgeOrigin, tradeId) 
                                           : StringFormat("%s%s", CommentPrefix, hedgeOrigin);
            request.type      = (ENUM_ORDER_TYPE)hedgeOrderType;
            request.price     = SymbolInfoDouble(_Symbol, request.type == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID);
            
            if(OrderSend(request, result))
            {
                  Print("DEBUG: New hedge order placed successfully. Ticket: ", result.order);
                  SendTradeResult(request.volume, result.order, false, tradeId);
            }
            else
            {
                  Print("ERROR: Failed to place new hedge order. Error: ", GetLastError());
                  break;
            }
            Sleep(500);
            currentHedgeCount = CountHedgePositions(hedgeOrigin);
            Print("DEBUG: Updated hedge count after placement: ", currentHedgeCount);
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function - Not used in this EA                       |
//+------------------------------------------------------------------+
void OnTick()
{
   // Trading logic is handled in OnTimer instead
}

// Send trade execution result back to bridge
bool SendTradeResult(double volume, ulong ticket, bool is_close, string tradeId="")
{
   // Format result as JSON
   string result;
   if(tradeId != "")
      result = StringFormat("{\"status\":\"success\",\"ticket\":%I64u,\"volume\":%.2f,\"is_close\":%s,\"id\":\"%s\"}",
                           ticket, volume, is_close ? "true" : "false", tradeId);
   else
      result = StringFormat("{\"status\":\"success\",\"ticket\":%I64u,\"volume\":%.2f,\"is_close\":%s}",
                           ticket, volume, is_close ? "true" : "false");
   
   Print("Preparing to send result: ", result);
   
   // Prepare data for web request
   char result_data[];
   StringToCharArray(result, result_data);
   
   string headers = "Content-Type: application/json\r\n";
   char response_data[];
   string response_headers;
   
   // Send result to bridge
   int res = WebRequest("POST", BridgeURL + "/mt5/trade_result", headers, 0, result_data, response_data, response_headers);
   
   if(res == -1)
   {
      Print("Error in WebRequest. Error code: ", GetLastError());
      return false;
   }
   
   Print("Result sent to bridge successfully");
   return true;
}

// Get pending trades from bridge server
string GetTradeFromBridge()
{
   // Initialize request variables
   char response_data[];
   string headers = "";
   string response_headers;
   
   // Send request to bridge
   int web_result = WebRequest("GET", BridgeURL + "/mt5/get_trade", headers, 0, response_data, response_data, response_headers);
   
   if(web_result == -1)
   {
      int error = GetLastError();
      Print("Error in WebRequest. Error code: ", error);
      if(error == ERR_WEBREQUEST_INVALID_ADDRESS) Print("Invalid URL. Check BridgeURL setting.");
      if(error == ERR_WEBREQUEST_CONNECT_FAILED) Print("Connection failed. Check if Bridge server is running.");
      return "";
   }
   
   // Convert response to string
   string response_str = CharArrayToString(response_data);
   
   // Only print response if it's not "no_trade" or if verbose mode is on
   if(VerboseMode || StringFind(response_str, "no_trade") < 0)
   {
      Print("Response: ", response_str);
   }
   
   // Check if response is HTML (indicates error page)
   if(StringFind(response_str, "<!doctype html>") >= 0 || StringFind(response_str, "<html") >= 0)
   {
      Print("Received HTML error page instead of JSON");
      return "";
   }
   
   // Check for no trades
   if(StringFind(response_str, "no_trade") >= 0)
   {
      return "";
   }
   
   // Validate JSON response
   if(StringFind(response_str, "{") < 0 || StringFind(response_str, "}") < 0)
   {
      Print("Invalid JSON response");
      return "";
   }
   
   return response_str;
}

// Helper function to close a hedge position matching the provided hedge origin.
// Returns true if a hedge position is closed successfully.
bool CloseHedgePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
   {
      Print("ERROR: Hedge position not found for ticket ", ticket);
      return false;
   }
   string sym = PositionGetString(POSITION_SYMBOL);
   double volume = PositionGetDouble(POSITION_VOLUME);
   long pos_type = PositionGetInteger(POSITION_TYPE); // POSITION_TYPE_BUY or POSITION_TYPE_SELL
   ENUM_ORDER_TYPE closing_order_type;
   if(pos_type == POSITION_TYPE_BUY)
       closing_order_type = ORDER_TYPE_SELL;
   else if(pos_type == POSITION_TYPE_SELL)
       closing_order_type = ORDER_TYPE_BUY;
   else
   {
      Print("ERROR: Unknown position type for hedge ticket ", ticket);
      return false;
   }
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   request.action    = TRADE_ACTION_DEAL;
   request.symbol    = sym;
   request.volume    = volume;
   request.magic     = MagicNumber;
   request.deviation = Slippage;
   request.comment   = "NT_Hedge_Close";
   request.type      = closing_order_type;
   request.price     = SymbolInfoDouble(sym, (request.type == ORDER_TYPE_BUY ? SYMBOL_ASK : SYMBOL_BID));
   
   Print(StringFormat("DEBUG: Closing hedge position - Ticket: %I64u, Volume: %.2f", ticket, volume));
   if(OrderSend(request, result))
   {
      Print("DEBUG: Hedge position closed successfully. Ticket: ", result.order);
      SendTradeResult(volume, result.order, true);
      return true;
   }
   else
   {
      Print("ERROR: Failed to close hedge position. Error: ", GetLastError());
      return false;
   }
}