import ballerina/http;
import ballerina/io;
import ballerina/lang.regexp;
import ballerina/log;

configurable HttpRoute[] httpRoutes = ?;
configurable TcpRoute[] tcpRoutes = ?;

// Map to store HTTP clients for each target service
isolated map<http:Client> httpClients = {};

public function initHttpClients() returns error? {
    // create HttpClients for incoming http messages
    foreach var route in httpRoutes {
        lock {
            if httpClients[route.target] is http:Client {
                continue;
            }
            http:Client _client = check createHttpClient(route);
            httpClients[route.target] = _client;
        }
    }

    // create HttpClients for incoming tcp messages
    foreach var route in tcpRoutes {
        lock {
            if httpClients[route.target] is http:Client {
                continue;
            }
            http:Client _client = check createHttpClient(route);
            httpClients[route.target] = _client;
        }
    }
    log:printInfo("HTTP clients initialized successfully.");
}

isolated function getHTTPClient(HttpRoute|TcpRoute route) returns http:Client|error {
    lock {
        http:Client? _client = httpClients[route.target];
        if _client is () {
            return error("No HTTP client found for the target service: " + route.target);
        }
        return _client;
    }
}

public isolated function routeHttp(http:Request req, http:RequestContext ctx) returns http:Response|error {
    // Find the target route for the incoming HTTP request
    HttpRoute? targetRoute = check findRouteForHttpReq(req.rawPath, req.method);
    if targetRoute is () {
        return createErrorResponse(400, "Path not found: " + req.rawPath + " " + req.method);
    }

    // Print the matched route for debugging purposes
    io:println(targetRoute);

    // Create a new HTTP client for forwarding the request
    http:Client _client = check createHttpClient(targetRoute);
    // Create a custom HTTP request from the original request
    http:Request customReq = check createCustomRequest(req, targetRoute);

    check audit_request(targetRoute.workflow, ctx.get("username").toString(), ctx.get("patientID").toString(), systemInfo.SYSNAME);

    // Forward the request to the target service
    http:Response|error response = _client->forward(customReq.rawPath, customReq);

    if response is error {
        return createErrorResponse(502, string `Failed to forward the request to the Upstream Service: ${response.message()}`);
    }

    return response;
}

// TCP Routing
public isolated function routeTCP(TcpRequestContext reqCtx) returns TcpResponseContext|error {
    TcpRoute? route = check findRouteForTcpReq(reqCtx);
    if route is () {
        return error("No route found for the given message type");
    }
    io:println(route);

    // Create an HTTP client and request for forwarding
    http:Client _client = check getHTTPClient(route);
    http:Request _req = createHTTPRequest(check extractPatientResource(reqCtx.fhirMessage), route.target, route.method);
    io:println("payload: ", _req.getJsonPayload());

    // TODO: get user data from tcp message
    check audit_request(route.workflow, "test-username", reqCtx.patientId, systemInfo.SYSNAME);
    http:Response response = check _client->forward("/", _req);
    TcpResponseContext responseContext = {
        httpResponse: response,
        workflow: route.workflow
    };
    return responseContext;
}

isolated function findRouteForHttpReq(string rawPath, string method) returns HttpRoute|error? {
    // Iterate through the configured routes to find a match
    foreach var route in httpRoutes {
        if route.methods.indexOf(method) != () {
            regexp:RegExp pathRegex = check regexp:fromString(route.path);
            boolean foundPath = rawPath.matches(pathRegex);
            if foundPath {
                return route;
            }
        }
    }
    return ();
}

isolated function createHttpClient(HttpRoute|TcpRoute route) returns http:Client|error {
    http:ClientConfiguration clientConfig = {
        auth: route.auth
    };
    return new http:Client(route.target, clientConfig);
}

isolated function createCustomRequest(http:Request req, HttpRoute route) returns http:Request|error {
    // Copy the original request and modify as needed
    http:Request customReq = req;
    customReq.rawPath = "/"; //TODO: change this to the actual path
    check customReq.setContentType(route.contentType ?: "application/json");
    return customReq;
}

isolated function createErrorResponse(int statusCode, string message) returns http:Response {
    http:Response response = new;
    response.statusCode = statusCode;
    response.setPayload({message: message});
    return response;
}

isolated function findRouteForTcpReq(TcpRequestContext reqCtx) returns TcpRoute|error? {
    io:println("Checking route for TCP...");

    // Match the route based on the HL7 message type (event code)
    foreach var route in tcpRoutes
    {
        if route.HL7Code == reqCtx.eventCode {
            return route;
        }
    }
    return ();

}

isolated function createHTTPRequest(json payload, string target, string method) returns http:Request {
    // Create a new HTTP request with payload, target, and method
    http:Request req = new;
    req.setPayload(payload, "application/json");
    req.rawPath = target;
    req.method = method;
    return req;
}

isolated function extractPatientResource(json convertedFhirMessage) returns json|error {
    // Extract the patient resource from the FHIR message
    map<json> fhirMessage = check convertedFhirMessage.ensureType();
    json[] entries = check fhirMessage["entry"].ensureType();
    json entry = check entries[2].ensureType();
    map<json> resource_ = check entry.ensureType();
    json patientResource = check resource_["resource"].ensureType();
    return patientResource;
}
