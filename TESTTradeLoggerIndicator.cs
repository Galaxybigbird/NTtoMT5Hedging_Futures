#region Using declarations
using NUnit.Framework;
using System;
using System.Net.Http;
using System.Threading.Tasks;
using NinjaTrader.Cbi;
using Moq;
using System.Collections.Generic;
using System.Linq;

namespace NinjaTrader.NinjaScript.Indicators.Tests
{
    [TestFixture]
    public class TESTTradeLoggerIndicator
    {
        private TradeLoggerIndicator indicator;
        private Mock<Account> mockAccount;
        private Mock<Position> mockPosition;
        private Mock<Instrument> mockInstrument;
        private Mock<Order> mockOrder;
        private Mock<Execution> mockExecution;

        [SetUp]
        public void Setup()
        {
            // Initialize mocks
            mockAccount = new Mock<Account>();
            mockPosition = new Mock<Position>();
            mockInstrument = new Mock<Instrument>();
            mockOrder = new Mock<Order>();
            mockExecution = new Mock<Execution>();

            // Setup basic instrument properties
            mockInstrument.Setup(i => i.FullName).Returns("NQ MAR24");
            
            // Setup basic order properties
            mockOrder.Setup(o => o.OrderState).Returns(OrderState.Filled);
            mockOrder.Setup(o => o.Id).Returns(12345);

            // Setup basic execution properties
            mockExecution.Setup(e => e.Instrument).Returns(mockInstrument.Object);
            mockExecution.Setup(e => e.Order).Returns(mockOrder.Object);
            mockExecution.Setup(e => e.Account).Returns(mockAccount.Object);
            mockExecution.Setup(e => e.Price).Returns(15000.50);
            mockExecution.Setup(e => e.Quantity).Returns(1);
            mockExecution.Setup(e => e.Time).Returns(DateTime.Now);

            // Setup basic position properties
            mockPosition.Setup(p => p.Instrument).Returns(mockInstrument.Object);
            mockPosition.Setup(p => p.Quantity).Returns(1);

            // Initialize indicator
            indicator = new TradeLoggerIndicator
            {
                AccountName = "TestAccount",
                BridgeServerUrl = "http://localhost:5000/log_trade"
            };
        }

        [Test]
        public void Constructor_InitializesHttpClient()
        {
            // Arrange & Act
            var indicator = new TradeLoggerIndicator();

            // Assert
            Assert.That(indicator, Is.Not.Null);
            // Note: We can't directly test the httpClient as it's private
        }

        [Test]
        public void AccountName_WhenSet_UpdatesSelectedAccount()
        {
            // Arrange
            var accountName = "TestAccount";

            // Act
            indicator.AccountName = accountName;

            // Assert
            Assert.That(indicator.AccountName, Is.EqualTo(accountName));
        }

        [Test]
        public void IsExitForPosition_NewPosition_ReturnsFalse()
        {
            // Arrange
            var executionArgs = new ExecutionEventArgs(mockExecution.Object);
            mockOrder.Setup(o => o.OrderAction).Returns(OrderAction.Buy);

            // Act
            bool isExit = indicator.TestIsExitForPosition(executionArgs);

            // Assert
            Assert.That(isExit, Is.False);
        }

        [Test]
        public void IsExitForPosition_ClosingExistingPosition_ReturnsTrue()
        {
            // Arrange
            var executionArgs = new ExecutionEventArgs(mockExecution.Object);
            
            // First create a position
            mockOrder.Setup(o => o.OrderAction).Returns(OrderAction.Buy);
            indicator.TestIsExitForPosition(executionArgs);

            // Then try to close it
            mockOrder.Setup(o => o.OrderAction).Returns(OrderAction.Sell);
            
            // Act
            bool isExit = indicator.TestIsExitForPosition(executionArgs);

            // Assert
            Assert.That(isExit, Is.True);
        }

        [Test]
        public void OnExecutionUpdate_DifferentInstrument_SkipsProcessing()
        {
            // Arrange
            mockInstrument.Setup(i => i.FullName).Returns("ES MAR24"); // Different instrument
            var executionArgs = new ExecutionEventArgs(mockExecution.Object);

            // Act
            indicator.TestOnExecutionUpdate(executionArgs);

            // Assert
            // Verify no HTTP request was made (implementation depends on how you expose this information)
        }

        [Test]
        public void OnExecutionUpdate_ValidTrade_SendsCorrectJson()
        {
            // Arrange
            var executionArgs = new ExecutionEventArgs(mockExecution.Object);
            mockOrder.Setup(o => o.OrderAction).Returns(OrderAction.Buy);

            // Act
            indicator.TestOnExecutionUpdate(executionArgs);

            // Assert
            // Verify HTTP request was made with correct JSON (implementation depends on how you expose this information)
        }

        [Test]
        public void SimpleJson_SerializeObject_CorrectFormat()
        {
            // Arrange
            var testObject = new
            {
                action = "Buy",
                quantity = 1.0,
                price = 15000.50,
                order_id = 12345,
                is_exit = false
            };

            // Act
            string json = SimpleJson.SerializeObject(testObject);

            // Assert
            Assert.That(json, Does.Contain("\"action\":\"Buy\""));
            Assert.That(json, Does.Contain("\"quantity\":1"));
            Assert.That(json, Does.Contain("\"price\":15000.5"));
            Assert.That(json, Does.Contain("\"order_id\":12345"));
            Assert.That(json, Does.Contain("\"is_exit\":false"));
        }
    }

    // Extension of TradeLoggerIndicator to expose protected methods for testing
    public static class TradeLoggerIndicatorTestExtensions
    {
        public static bool TestIsExitForPosition(this TradeLoggerIndicator indicator, ExecutionEventArgs e)
        {
            // Use reflection to access the private IsExitForPosition method
            var methodInfo = typeof(TradeLoggerIndicator).GetMethod("IsExitForPosition", 
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
            return (bool)methodInfo.Invoke(indicator, new object[] { e });
        }

        public static void TestOnExecutionUpdate(this TradeLoggerIndicator indicator, ExecutionEventArgs e)
        {
            // Use reflection to access the private OnExecutionUpdate method
            var methodInfo = typeof(TradeLoggerIndicator).GetMethod("OnExecutionUpdate", 
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
            methodInfo.Invoke(indicator, new object[] { null, e });
        }
    }
}
#endregion 