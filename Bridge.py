import json
from flask import Flask, request, jsonify
from datetime import datetime
from collections import deque

app = Flask(__name__)

# Initialize trade queue as a global variable
trade_queue = deque()

# Symbol mapping from NinjaTrader to MT5
SYMBOL_MAP = {
    "NQ": "USTECH",
    "ES": "US500",
    "YM": "US30",
    "USTECH": "USTECH",
    "US500": "US500",
    "US30": "US30",
    "GC": "XAUUSD",     # Gold futures
    "XAUUSD": "XAUUSD"  # In case it's already in MT5 format
}

def map_symbol(nt_symbol):
    # First, clean any suffixes like '@E-MINI'
    clean_symbol = nt_symbol.split('@')[0].strip()
    
    # If the symbol is already in MT5 format, return it as is
    if clean_symbol in SYMBOL_MAP.values():
        print(f"Symbol mapping: {nt_symbol} -> {clean_symbol} -> {clean_symbol} -> {clean_symbol}")
        return clean_symbol
    
    # Check if this is a contract month symbol
    if any(month in clean_symbol for month in ["MAR", "JUN", "SEP", "DEC"]):
        # For contract months, keep the original symbol
        print(f"Symbol mapping: {nt_symbol} -> {clean_symbol} -> {clean_symbol} -> {clean_symbol}")
        return clean_symbol
    
    # Extract just the base symbol (NQ, ES, YM, GC)
    base_symbol = ''.join(c for c in clean_symbol if c.isalpha())
    
    # Get the mapped symbol or return the base symbol if no mapping exists
    mapped_symbol = SYMBOL_MAP.get(base_symbol, base_symbol)
    print(f"Symbol mapping: {nt_symbol} -> {clean_symbol} -> {base_symbol} -> {mapped_symbol}")
    return mapped_symbol

def format_trade_for_mt5(trade_data):
    # Validate required fields
    required_fields = ["instrument", "action", "quantity", "price", "time", "account"]
    missing_fields = [field for field in required_fields if field not in trade_data]
    if missing_fields:
        raise ValueError(f"Missing required fields: {missing_fields}")
    
    # Validate action type
    valid_actions = ["Buy", "Sell"]
    if trade_data["action"] not in valid_actions:
        raise ValueError(f"Invalid action: {trade_data['action']}. Must be one of {valid_actions}")
    
    # Validate quantity
    quantity = float(trade_data["quantity"])
    if quantity <= 0:
        raise ValueError(f"Invalid quantity: {quantity}. Must be greater than 0")
    
    # Convert NinjaTrader trade data to MT5 format
    mt5_symbol = map_symbol(trade_data["instrument"])
    print(f"Mapping symbol from {trade_data['instrument']} to {mt5_symbol}")
    
    # Determine if this is a closing trade based on the action
    is_closing = trade_data.get("is_exit", False)
    action = trade_data["action"]
    
    # Debug the incoming trade data
    print(f"Raw trade data: {trade_data}")
    print(f"Is closing trade: {is_closing}")
    
    formatted_trade = {
        "time": trade_data["time"],
        "symbol": mt5_symbol,
        "type": "Sell" if action == "Buy" else "Buy",  # Reverse the direction
        "volume": quantity,
        "price": float(trade_data["price"]),
        "comment": f"Hedge_{trade_data['account']}",
        "is_close": is_closing
    }
    print(f"Formatted trade for MT5: {formatted_trade}")
    return formatted_trade

@app.route('/log_trade', methods=['POST'])
def log_trade():
    try:
        print("\n=== Received POST to /log_trade ===")
        
        # Check for valid JSON
        if not request.is_json:
            error_msg = "Request must be JSON"
            print(f"Error: {error_msg}")
            return jsonify({"status": "error", "message": error_msg}), 400
            
        try:
            trade_data = request.json
            print(f"Received trade from NT8: {trade_data}")
        except Exception as e:
            error_msg = f"Invalid JSON: {str(e)}"
            print(f"Error: {error_msg}")
            return jsonify({"status": "error", "message": error_msg}), 400
        
        # Validate required fields
        required_fields = ["time", "instrument", "action", "quantity", "price", "account"]
        missing_fields = [field for field in required_fields if field not in trade_data]
        if missing_fields:
            error_msg = f"Missing required fields: {missing_fields}"
            print(f"Error: {error_msg}")
            return jsonify({"status": "error", "message": error_msg}), 400
        
        # Format and store trade for MT5
        try:
            formatted_trade = format_trade_for_mt5(trade_data)
            trade_queue.append(formatted_trade)
            print(f"Stored trade for MT5 to pick up: {formatted_trade}")
            return jsonify({"status": "success", "message": "Trade logged successfully"}), 200
        except ValueError as e:
            error_msg = str(e)
            print(f"Validation error: {error_msg}")
            return jsonify({"status": "error", "message": error_msg}), 400
        except Exception as e:
            error_msg = f"Error formatting trade: {str(e)}"
            print(error_msg)
            return jsonify({"status": "error", "message": error_msg}), 500
            
    except Exception as e:
        error_msg = f"Error handling trade: {str(e)}"
        print(error_msg)
        return jsonify({"status": "error", "message": error_msg}), 500

@app.route('/mt5/get_trade', methods=['GET'])
def get_trade():
    try:
        print("\n=== Received GET to /mt5/get_trade ===")
        print(f"Current queue size: {len(trade_queue)}")
        
        if len(trade_queue) == 0:
            print("No trades in queue")
            return jsonify({"status": "no_trade"}), 200
            
        try:
            trade = trade_queue.popleft()
            print(f"Sending trade to MT5: {trade}")
            return jsonify(trade), 200
        except Exception as e:
            print(f"Error getting trade from queue: {str(e)}")
            return jsonify({"status": "error", "message": f"Queue error: {str(e)}"}), 500
            
    except Exception as e:
        error_msg = f"Error in get_trade: {str(e)}"
        print(f"Critical error: {error_msg}")
        print(f"Exception type: {type(e)}")
        print(f"Exception args: {e.args}")
        return jsonify({"status": "error", "message": error_msg}), 500

@app.route('/mt5/trade_result', methods=['POST'])
def trade_result():
    try:
        print("\n=== Received POST to /mt5/trade_result ===")
        if not request.is_json:
            print("Warning: Received non-JSON data")
            data = request.get_data()
            try:
                result = json.loads(data.decode('utf-8'))
            except:
                print(f"Raw data received: {data}")
                return jsonify({"status": "error", "message": "Invalid JSON"}), 400
        else:
            result = request.json
            
        print(f"Received trade result from MT5: {result}")
        return jsonify({"status": "success"}), 200
    except Exception as e:
        print(f"Error in trade_result: {e}")
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/health', methods=['GET'])
def health_check():
    try:
        return jsonify({"status": "healthy", "queue_size": len(trade_queue)}), 200
    except Exception as e:
        return jsonify({"status": "unhealthy", "error": str(e)}), 500

if __name__ == '__main__':
    print("\nStarting Bridge Server...")
    print("1. NinjaTrader endpoint: http://localhost.com:5000/log_trade")
    print("2. MT5 endpoints:")
    print("   - GET  http://localhost.com:5000/mt5/get_trade")
    print("   - POST http://localhost.com:5000/mt5/trade_result")
    print("\nWaiting for trades...")
    
    app.run(host='localhost.com', port=5000, use_reloader=False)
