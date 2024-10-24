import ballerina/http;
import ballerina/log;

http:InterceptableService httpService = service object {
    public function createInterceptors() returns http:Interceptor[] {
        log:printInfo("Creating http interceptors...");
        return [
            // transformers
            new MessageBuilderInterceptor(),
            new MessageFormatterIntercepter(),

            // validators
            new RequestValidatorInterceptor(),
            new ResponseValidatorInterceptor(),

            // enforcers
            new SanctionCheckEnforcerInterceptor()
        ];
    }

    isolated resource function 'default [string... path](http:Caller caller, http:Request req, http:RequestContext ctx) returns error? {
        http:Response response = check routeHttp(req, ctx);
        check caller->respond(response);
    }
};

public function startHttpListener(int port) returns error? {
    log:printInfo(string `Starting HTTP listener on port: ${port}`);
    http:Listener httpListener = check new (port);
    check httpListener.attach(httpService, "/");
    check httpListener.'start();
}
