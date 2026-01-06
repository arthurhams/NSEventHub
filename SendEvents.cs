using Azure.Messaging.EventHubs;
using Azure.Messaging.EventHubs.Producer;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace SendEvents;

public class SendEvents
{
    private readonly ILogger<SendEvents> _logger;

    public SendEvents(ILogger<SendEvents> logger)
    {
        _logger = logger;
    }

    [Function("SendEvents")]
    public async Task<IActionResult> Run([HttpTrigger(AuthorizationLevel.Function, "get", "post")] HttpRequest req)
    {
        _logger.LogInformation("C# HTTP trigger function processed a request.");

        try
        {
            // Get EventHub connection string from environment variables
            var connectionString = Environment.GetEnvironmentVariable("EventHubConnectionString");
            var eventHubName = Environment.GetEnvironmentVariable("EventHubName");

            if (string.IsNullOrEmpty(connectionString) || string.IsNullOrEmpty(eventHubName))
            {
                return new BadRequestObjectResult("EventHub configuration is missing. Please set EventHubConnectionString and EventHubName in local.settings.json");
            }

            // Create a producer client to send events to EventHub
            await using var producerClient = new EventHubProducerClient(connectionString, eventHubName);

            // Read message from request body or use default
            string requestBody = await new StreamReader(req.Body).ReadToEndAsync();
            var message = string.IsNullOrEmpty(requestBody) ? "Hello EventHub!" : requestBody;

            // Create a batch of events
            using EventDataBatch eventBatch = await producerClient.CreateBatchAsync();

            // Add the message to the batch
            if (!eventBatch.TryAdd(new EventData(message)))
            {
                throw new Exception($"Event is too large for the batch");
            }

            // Send the batch of events to EventHub
            await producerClient.SendAsync(eventBatch);

            _logger.LogInformation($"Successfully sent message to EventHub: {message}");
            
            return new OkObjectResult(new { 
                status = "success", 
                message = "Event sent to EventHub successfully",
                eventData = message
            });
        }
        catch (Exception ex)
        {
            _logger.LogError($"Error sending message to EventHub: {ex.Message}");
            return new StatusCodeResult(StatusCodes.Status500InternalServerError);
        }
    }
}