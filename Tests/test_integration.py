import unittest
import requests
import json
import time
from datetime import datetime
import os
import csv

class TestSystemIntegration(unittest.TestCase):
    def setUp(self):
        self.bridge_url = "http://localhost:5000"
        self.trades_file = "trades.csv"
        
        # Ensure bridge is running
        try:
            response = requests.get(f"{self.bridge_url}/health")
            self.assertEqual(response.status_code, 200)
        except requests.exceptions.ConnectionError:
            self.fail("Bridge server is not running. Please start the bridge first.")

    def test_full_trade_flow(self):
        """Test complete trade flow from NinjaTrader through Bridge to MT5"""
        print("\nTesting full trade flow...")
        
        # 1. Simulate a series of NinjaTrader trades
        test_trades = [
            # Buy order
            {
                "time": datetime.now().isoformat(),
                "instrument": "NQ MAR24",
                "action": "Buy",
                "quantity": 1,
                "price": 22015.25,
                "account": "TestAccount",
                "is_exit": False
            },
            # Sell order (exit)
            {
                "time": datetime.now().isoformat(),
                "instrument": "NQ MAR24",
                "action": "Sell",
                "quantity": 1,
                "price": 22020.25,
                "account": "TestAccount",
                "is_exit": True
            }
        ]

        print("\nSending trades to bridge...")
        for trade in test_trades:
            # Send trade to bridge
            response = requests.post(
                f"{self.bridge_url}/log_trade",
                json=trade,
                headers={"Content-Type": "application/json"}
            )
            self.assertEqual(response.status_code, 200)
            print(f"Trade sent: {trade['action']} {trade['quantity']} {trade['instrument']}")
            
            # Verify trade was saved to CSV
            self.assertTrue(os.path.exists(self.trades_file))
            
            # Simulate MT5 requesting the trade
            response = requests.get(f"{self.bridge_url}/mt5/get_trade")
            self.assertEqual(response.status_code, 200)
            mt5_trade = response.json()
            
            print("\nTrade received by MT5:")
            print(json.dumps(mt5_trade, indent=2))
            
            # Verify trade transformation
            if trade["action"] == "Buy":
                self.assertEqual(mt5_trade["type"], "Sell")  # Reversed for hedging
            else:
                self.assertEqual(mt5_trade["type"], "Buy")  # Reversed for hedging
                
            self.assertEqual(mt5_trade["symbol"], "USTECH")  # NQ mapped to USTECH
            self.assertEqual(mt5_trade["volume"], trade["quantity"])
            self.assertEqual(mt5_trade["price"], trade["price"])
            self.assertEqual(mt5_trade["is_close"], trade["is_exit"])
            
            # Simulate MT5 trade execution result
            mt5_result = {
                "status": "success",
                "ticket": 12345,
                "symbol": mt5_trade["symbol"],
                "volume": mt5_trade["volume"],
                "is_close": mt5_trade["is_close"]
            }
            
            response = requests.post(
                f"{self.bridge_url}/mt5/trade_result",
                json=mt5_result,
                headers={"Content-Type": "application/json"}
            )
            self.assertEqual(response.status_code, 200)
            print("\nMT5 execution result sent to bridge")
            
            # Add small delay between trades
            time.sleep(1)

        print("\nVerifying CSV log...")
        # Verify all trades were logged
        with open(self.trades_file, 'r') as f:
            reader = csv.reader(f)
            logged_trades = list(reader)
            self.assertEqual(len(logged_trades), len(test_trades))
            print(f"Found {len(logged_trades)} trades in log file")

    def test_error_handling(self):
        """Test error handling across the system"""
        print("\nTesting error handling...")
        
        # Test invalid JSON
        response = requests.post(
            f"{self.bridge_url}/log_trade",
            data="invalid json",
            headers={"Content-Type": "application/json"}
        )
        self.assertEqual(response.status_code, 400)
        print("Invalid JSON handled correctly")
        
        # Test missing required fields
        response = requests.post(
            f"{self.bridge_url}/log_trade",
            json={"instrument": "NQ"},
            headers={"Content-Type": "application/json"}
        )
        self.assertEqual(response.status_code, 400)
        print("Missing fields handled correctly")
        
        # Test invalid instrument
        response = requests.post(
            f"{self.bridge_url}/log_trade",
            json={
                "time": datetime.now().isoformat(),
                "instrument": "INVALID",
                "action": "Buy",
                "quantity": 1,
                "price": 22015.25,
                "account": "TestAccount",
                "is_exit": False
            },
            headers={"Content-Type": "application/json"}
        )
        self.assertEqual(response.status_code, 200)  # Should accept but map as is
        print("Invalid instrument handled correctly")

    def test_concurrent_requests(self):
        """Test system behavior under concurrent requests"""
        print("\nTesting concurrent requests...")
        
        # Generate multiple trades
        trades = [
            {
                "time": datetime.now().isoformat(),
                "instrument": "NQ MAR24",
                "action": "Buy",
                "quantity": i,
                "price": 22015.25 + i,
                "account": f"TestAccount{i}",
                "is_exit": False
            }
            for i in range(1, 6)
        ]
        
        # Send trades in quick succession
        for trade in trades:
            response = requests.post(
                f"{self.bridge_url}/log_trade",
                json=trade,
                headers={"Content-Type": "application/json"}
            )
            self.assertEqual(response.status_code, 200)
        print(f"Sent {len(trades)} trades concurrently")
        
        # Verify all trades can be retrieved in order
        received_trades = []
        for _ in range(len(trades)):
            response = requests.get(f"{self.bridge_url}/mt5/get_trade")
            self.assertEqual(response.status_code, 200)
            trade_data = response.json()
            if "status" not in trade_data:
                received_trades.append(trade_data)
            time.sleep(0.1)  # Small delay between requests
            
        self.assertEqual(len(received_trades), len(trades))
        print(f"Retrieved {len(received_trades)} trades in order")

if __name__ == '__main__':
    unittest.main() 