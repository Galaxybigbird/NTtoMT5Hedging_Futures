import unittest
from Bridge import app, map_symbol, format_trade_for_mt5, trade_queue
import json
from datetime import datetime

class TestBridge(unittest.TestCase):
    def setUp(self):
        app.config['TESTING'] = True
        self.client = app.test_client()
        
    def tearDown(self):
        # Clear the trade queue between tests
        trade_queue.clear()

    def test_symbol_mapping(self):
        """Test symbol mapping functionality"""
        test_cases = [
            ("NQ", "USTECH"),
            ("ES", "US500"),
            ("YM", "US30"),
            ("GC", "XAUUSD"),
            ("NQ MAR24", "NQ MAR24"),  # Contract month symbols should be preserved
            ("ES JUN24", "ES JUN24"),  # Contract month symbols should be preserved
            ("NQ MAR25", "NQ MAR25"),  # Contract month symbols should be preserved
            ("NQ@E-MINI", "USTECH"),
            ("NQ@E-MINI@TEST", "USTECH"),
            ("USTECH", "USTECH"),
            ("US500", "US500"),
            ("", ""),
            ("UNKNOWN", "UNKNOWN"),
            ("NQ@", "USTECH"),
            ("NQ DEC23@E-MINI", "NQ DEC23")  # Contract month with suffix
        ]
        
        for input_symbol, expected_output in test_cases:
            with self.subTest(input_symbol=input_symbol):
                result = map_symbol(input_symbol)
                self.assertEqual(result, expected_output)

    def test_trade_formatting(self):
        """Test trade formatting from NT to MT5"""
        test_cases = [
            {
                "input": {
                    "time": "2025-01-23T19:31:21.4370000",
                    "instrument": "NQ",
                    "action": "Buy",
                    "quantity": 1,
                    "price": 22015.25,
                    "account": "TestAccount",
                    "is_exit": False
                },
                "expected": {
                    "time": "2025-01-23T19:31:21.4370000",
                    "symbol": "USTECH",
                    "type": "Sell",
                    "volume": 1.0,
                    "price": 22015.25,
                    "comment": "Hedge_TestAccount",
                    "is_close": False
                }
            },
            {
                "input": {
                    "time": "2025-01-23T19:31:21.4370000",
                    "instrument": "NQ MAR24",
                    "action": "Buy",
                    "quantity": 1,
                    "price": 22015.25,
                    "account": "TestAccount",
                    "is_exit": False
                },
                "expected": {
                    "time": "2025-01-23T19:31:21.4370000",
                    "symbol": "NQ MAR24",
                    "type": "Sell",
                    "volume": 1.0,
                    "price": 22015.25,
                    "comment": "Hedge_TestAccount",
                    "is_close": False
                }
            }
        ]
        
        for test_case in test_cases:
            with self.subTest(input=test_case["input"]):
                result = format_trade_for_mt5(test_case["input"])
                self.assertEqual(result, test_case["expected"])

    def test_trade_formatting_edge_cases(self):
        """Test trade formatting edge cases and error handling"""
        test_cases = [
            # Missing required fields
            {
                "input": {"instrument": "NQ", "action": "Buy", "quantity": 1, "price": 22015.25},
                "error": ValueError,
                "error_msg": "Missing required fields"
            },
            # Invalid action
            {
                "input": {
                    "time": "2025-01-23T19:31:21.4370000",
                    "instrument": "NQ",
                    "action": "INVALID",
                    "quantity": 1,
                    "price": 22015.25,
                    "account": "TestAccount",
                    "is_exit": False
                },
                "error": ValueError,
                "error_msg": "Invalid action"
            },
            # Zero quantity
            {
                "input": {
                    "time": "2025-01-23T19:31:21.4370000",
                    "instrument": "NQ",
                    "action": "Buy",
                    "quantity": 0,
                    "price": 22015.25,
                    "account": "TestAccount",
                    "is_exit": False
                },
                "error": ValueError,
                "error_msg": "Invalid quantity"
            }
        ]
        
        for test_case in test_cases:
            with self.subTest(input=test_case["input"]):
                with self.assertRaises(test_case["error"]) as context:
                    format_trade_for_mt5(test_case["input"])
                self.assertIn(test_case["error_msg"], str(context.exception))

    def test_log_trade_endpoint(self):
        """Test the /log_trade endpoint"""
        # Valid trade
        test_data = {
            "time": "2025-01-23T19:31:21.4370000",
            "instrument": "NQ",
            "action": "Buy",
            "quantity": 1,
            "price": 22015.25,
            "account": "TestAccount",
            "is_exit": False
        }
        response = self.client.post('/log_trade',
                                data=json.dumps(test_data),
                                content_type='application/json')
        self.assertEqual(response.status_code, 200)
        
        # Invalid JSON
        response = self.client.post('/log_trade',
                                data="invalid json",
                                content_type='application/json')
        self.assertEqual(response.status_code, 400)
        
        # Missing required fields
        invalid_data = {
            "instrument": "NQ",
            "action": "Buy"
        }
        response = self.client.post('/log_trade',
                                data=json.dumps(invalid_data),
                                content_type='application/json')
        self.assertEqual(response.status_code, 400)
        response_data = json.loads(response.data)
        self.assertIn("Missing required fields", response_data["message"])

    def test_mt5_get_trade_endpoint(self):
        """Test the /mt5/get_trade endpoint"""
        # Send both trades first
        trade1 = {
            "time": "2025-01-23T19:31:21.4370000",
            "instrument": "NQ",
            "action": "Buy",
            "quantity": 1,
            "price": 22015.25,
            "account": "TestAccount",
            "is_exit": False
        }
        trade2 = {
            "time": "2025-01-23T19:31:22.4370000",
            "instrument": "ES",
            "action": "Sell",
            "quantity": 2,
            "price": 4800.25,
            "account": "TestAccount",
            "is_exit": True
        }
        
        # Send trades
        response = self.client.post('/log_trade',
                                data=json.dumps(trade1),
                                content_type='application/json')
        self.assertEqual(response.status_code, 200)
        
        response = self.client.post('/log_trade',
                                data=json.dumps(trade2),
                                content_type='application/json')
        self.assertEqual(response.status_code, 200)
        
        # Get first trade - should be NQ since it was sent first
        response = self.client.get('/mt5/get_trade')
        self.assertEqual(response.status_code, 200)
        response_data = json.loads(response.data)
        self.assertEqual(response_data["symbol"], "USTECH")
        self.assertEqual(response_data["type"], "Sell")
        self.assertEqual(response_data["volume"], 1.0)
        
        # Get second trade - should be ES
        response = self.client.get('/mt5/get_trade')
        self.assertEqual(response.status_code, 200)
        response_data = json.loads(response.data)
        self.assertEqual(response_data["symbol"], "US500")
        self.assertEqual(response_data["type"], "Buy")
        self.assertEqual(response_data["volume"], 2.0)
        
        # No more trades
        response = self.client.get('/mt5/get_trade')
        self.assertEqual(response.status_code, 200)
        response_data = json.loads(response.data)
        self.assertEqual(response_data["status"], "no_trade")

    def test_health_check(self):
        """Test the health check endpoint"""
        response = self.client.get('/health')
        self.assertEqual(response.status_code, 200)
        response_data = json.loads(response.data)
        self.assertEqual(response_data["status"], "healthy")

    def test_concurrent_trades(self):
        """Test handling of concurrent trades"""
        trades = [
            {
                "time": "2025-01-23T19:31:01.4370000",
                "instrument": "NQ",
                "action": "Buy",
                "quantity": 1,
                "price": 22016.25,
                "account": "TestAccount1",
                "is_exit": False
            },
            {
                "time": "2025-01-23T19:31:02.4370000",
                "instrument": "NQ",
                "action": "Buy",
                "quantity": 2,
                "price": 22017.25,
                "account": "TestAccount2",
                "is_exit": False
            },
            {
                "time": "2025-01-23T19:31:03.4370000",
                "instrument": "NQ",
                "action": "Buy",
                "quantity": 3,
                "price": 22018.25,
                "account": "TestAccount3",
                "is_exit": False
            }
        ]
        
        # Send trades concurrently (simulated)
        for trade in trades:
            response = self.client.post('/log_trade',
                                    data=json.dumps(trade),
                                    content_type='application/json')
            self.assertEqual(response.status_code, 200)
            
        # Verify trades can be retrieved in order
        received_trades = []
        for _ in range(len(trades)):
            response = self.client.get('/mt5/get_trade')
            self.assertEqual(response.status_code, 200)
            trade_data = json.loads(response.data)
            if "status" not in trade_data:  # Skip "no_trade" responses
                received_trades.append(trade_data)
        
        self.assertEqual(len(received_trades), len(trades))
        for i, trade in enumerate(received_trades):
            self.assertEqual(trade["symbol"], "USTECH")
            self.assertEqual(trade["volume"], float(trades[i]["quantity"]))

    def test_integration_trade_flow(self):
        """Test complete trade flow from NT to MT5"""
        # 1. Create test trade
        nt_trade = {
            "time": "2025-01-23T19:31:21.4370000",
            "instrument": "NQ",
            "action": "Buy",
            "quantity": 1,
            "price": 22015.25,
            "account": "TestAccount",
            "is_exit": False
        }
        
        # 2. Send trade to bridge
        response = self.client.post('/log_trade',
                                data=json.dumps(nt_trade),
                                content_type='application/json')
        self.assertEqual(response.status_code, 200)
        
        # 3. Simulate MT5 requesting the trade
        response = self.client.get('/mt5/get_trade')
        self.assertEqual(response.status_code, 200)
        mt5_trade = json.loads(response.data)
        
        # 4. Verify trade format
        self.assertEqual(mt5_trade["symbol"], "USTECH")
        self.assertEqual(mt5_trade["type"], "Sell")
        self.assertEqual(mt5_trade["volume"], 1.0)
        self.assertEqual(mt5_trade["is_close"], False)
        
        # 5. Verify trade was consumed (next request should return no_trade)
        response = self.client.get('/mt5/get_trade')
        self.assertEqual(response.status_code, 200)
        no_trade_response = json.loads(response.data)
        self.assertEqual(no_trade_response["status"], "no_trade")

if __name__ == '__main__':
    unittest.main() 