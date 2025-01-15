import json
from flask import Flask, request, jsonify
import csv
from datetime import datetime

app = Flask(__name__)

# Store trades in CSV for backup
TRADES_FILE = "trades.csv"
# Store the latest trade for MT5 to pick up
latest_trade = None

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
    
    # Extract just the base symbol (NQ, ES, YM, GC) by taking only the letters
    # This will remove any contract months (MAR24, DEC23, etc.)
    base_symbol = ''.join(c for c in clean_symbol if c.isalpha())
    
    print(f"Symbol mapping: {nt_symbol} -> {clean_symbol} -> {base_symbol} -> {SYMBOL_MAP.get(base_symbol, base_symbol)}")
    return SYMBOL_MAP.get(base_symbol, base_symbol)

def format_trade_for_mt5(trade_data):
    # Convert NinjaTrader trade data to MT5 format
    mt5_symbol = map_symbol(trade_data.get("instrument", ""))
    print(f"Mapping symbol from {trade_data.get('instrument')} to {mt5_symbol}")
    
    # Determine if this is a closing trade based on the action
    is_closing = trade_data.get("is_exit", False)  # Add support for explicit exit flag
    action = trade_data.get("action")
    
    # Debug the incoming trade data
    print(f"Raw trade data: {trade_data}")
    print(f"Is closing trade: {is_closing}")
    
    formatted_trade = {
        "time": trade_data.get("time"),
        "symbol": mt5_symbol,
        "type": "Sell" if action == "Buy" else "Buy",  # Reverse the direction
        "volume": float(trade_data.get("quantity", 0.1)),
        "price": float(trade_data.get("price", 0)),
        "comment": f"Hedge_{trade_data.get('account')}",
        "is_close": is_closing  # Add flag to indicate if this is a closing trade
    }
    print(f"Formatted trade for MT5: {formatted_trade}")
    return formatted_trade

def save_trade_to_csv(trade_data):
    try:
        with open(TRADES_FILE, 'a', newline='') as f:
            writer = csv.writer(f)
            writer.writerow([
                datetime.now().isoformat(),
                trade_data['instrument'],
                trade_data['action'],
                trade_data['quantity'],
                trade_data['price'],
                trade_data['account']
            ])
        print(f"Trade saved to CSV: {trade_data}")
    except Exception as e:
        print(f"Error saving to CSV: {e}")

@app.route('/log_trade', methods=['POST'])
def log_trade():
    global latest_trade
    try:
        print("\n=== Received POST to /log_trade ===")
        trade_data = request.json
        print(f"Received trade from NT8: {trade_data}")
        
        # Save trade to CSV as backup
        save_trade_to_csv(trade_data)
        
        # Format and store trade for MT5
        latest_trade = format_trade_for_mt5(trade_data)
        print(f"Stored trade for MT5 to pick up: {latest_trade}")
        
        return jsonify({"status": "success", "message": "Trade logged successfully"}), 200
            
    except Exception as e:
        print(f"Error handling trade: {e}")
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/mt5/get_trade', methods=['GET'])
def get_trade():
    global latest_trade
    try:
        print("\n=== Received GET to /mt5/get_trade ===")
        if latest_trade:
            print(f"Sending trade to MT5: {latest_trade}")
            response = latest_trade
            latest_trade = None  # Clear the trade after sending
            return jsonify(response), 200
        else:
            print("No trade waiting")
            return jsonify({"status": "no_trade"}), 200
    except Exception as e:
        print(f"Error in get_trade: {e}")
        return jsonify({"status": "error", "message": str(e)}), 500

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
    return jsonify({"status": "healthy"}), 200

if __name__ == '__main__':
    print("\nStarting Bridge Server...")
    print("1. NinjaTrader endpoint: http://localhost.com:5000/log_trade")
    print("2. MT5 endpoints:")
    print("   - GET  http://localhost.com:5000/mt5/get_trade")
    print("   - POST http://localhost.com:5000/mt5/trade_result")
    print("\nWaiting for trades...")
    
    app.run(host='localhost.com', port=5000, use_reloader=False)
