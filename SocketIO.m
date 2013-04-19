//
//  SocketIO.m
//  v0.3.2 ARC
//
//  based on 
//  socketio-cocoa https://github.com/fpotter/socketio-cocoa
//  by Fred Potter <fpotter@pieceable.com>
//
//  using
//  https://github.com/square/SocketRocket
//  https://github.com/stig/json-framework/
//
//  reusing some parts of
//  /socket.io/socket.io.js
//
//  Created by Philipp Kyeck http://beta-interactive.de
//
//  Updated by 
//    samlown   https://github.com/samlown
//    kayleg    https://github.com/kayleg
//    taiyangc  https://github.com/taiyangc
//

#import "SocketIO.h"
#import "SocketIOPacket.h"
#import "SocketIOJSONSerialization.h"

#import "SocketIOTransportWebsocket.h"

#define DEBUG_LOGS 1
#define DEBUG_CERTIFICATE 1

#if DEBUG_LOGS
#define DEBUGLOG(...) NSLog(__VA_ARGS__)
#else
#define DEBUGLOG(...)
#endif

static NSString* kInsecureHandshakeURL = @"http://%@/socket.io/1/?t=%d%@";
static NSString* kInsecureHandshakePortURL = @"http://%@:%d/socket.io/1/?t=%d%@";
static NSString* kSecureHandshakePortURL = @"https://%@:%d/socket.io/1/?t=%d%@";
static NSString* kSecureHandshakeURL = @"https://%@/socket.io/1/?t=%d%@";

NSString* const SocketIOError     = @"SocketIOError";
NSString* const SocketIOException = @"SocketIOException";

# pragma mark -
# pragma mark SocketIO's private interface

@interface SocketIO ()

@property(nonatomic,strong) NSMutableArray *queue;
@property(nonatomic,strong) NSMutableDictionary *acks;
@property(nonatomic,copy,readwrite) NSString *host;
@property (nonatomic, readwrite) NSInteger port;
@property(nonatomic,copy,readwrite) NSString *sid;
@property(nonatomic,copy,readwrite) NSString *endpoint;
@property(nonatomic,strong) NSURLConnection *handshake;
@property(nonatomic,strong) NSMutableData *httpRequestData;
@property(nonatomic) NSUInteger ackCount;
@property(nonatomic,strong) NSDictionary *params;
@property(nonatomic,strong) NSTimer *timeout;
@property(nonatomic,strong) NSObject<SocketIOTransport> *transport;
@property (nonatomic, readwrite) BOOL isConnected, isConnecting;

- (void) setTimeout;
- (void) onTimeout;

- (void) onConnect:(SocketIOPacket *)packet;
- (void) onDisconnect:(NSError *)error;

- (void) sendDisconnect;
- (void) send:(SocketIOPacket *)packet;

- (NSString *) addAcknowledge:(SocketIOCallback)function;
- (void) removeAcknowledgeForKey:(NSString *)key;
- (NSMutableArray*) getMatchesFrom:(NSString*)data with:(NSString*)regex;

@end

# pragma mark -
# pragma mark SocketIO implementation

@implementation SocketIO

- (id) initWithDelegate:(id<SocketIODelegate>)delegate
{
    self = [super init];
    if (self) {
        self.delegate = delegate;
        self.queue = [[NSMutableArray alloc] init];
        self.ackCount = 0;
        self.acks = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (void) connectToHost:(NSString *)host onPort:(NSInteger)port
{
    [self connectToHost:host onPort:port withParams:nil withNamespace:@""];
}

- (void) connectToHost:(NSString *)host onPort:(NSInteger)port withParams:(NSDictionary *)params
{
    [self connectToHost:host onPort:port withParams:params withNamespace:@""];
}

- (void) connectToHost:(NSString *)host onPort:(NSInteger)port withParams:(NSDictionary *)params withNamespace:(NSString *)endpoint
{
    if (!self.isConnected && !self.isConnecting) {
        self.isConnecting = YES;
        
        self.host = host;
        self.port = port;
        self.params = params;
        self.endpoint = endpoint;
        
        // create a query parameters string
        NSMutableString *query = [[NSMutableString alloc] initWithString:@""];
        [params enumerateKeysAndObjectsUsingBlock: ^(id key, id value, BOOL *stop) {
            [query appendFormat:@"&%@=%@", key, value];
        }];
        
        // do handshake via HTTP request
        NSString *s;
        NSString *format;
        if (self.port) {
            format = _useSecure ? kSecureHandshakePortURL : kInsecureHandshakePortURL;
            s = [NSString stringWithFormat:format, self.host, self.port, rand(), query];
        }
        else {
            format = _useSecure ? kSecureHandshakeURL : kInsecureHandshakeURL;
            s = [NSString stringWithFormat:format, self.host, rand(), query];
        }
        DEBUGLOG(@"Connecting to socket with URL: %@", s);
        NSURL *url = [NSURL URLWithString:s];
        query = nil;
                
        
        // make a request
        NSURLRequest *request = [NSURLRequest requestWithURL:url
                                                 cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData 
                                             timeoutInterval:10.0];
        
        self.handshake = [NSURLConnection connectionWithRequest:request 
                                                   delegate:self];
        if (self.handshake) {
            self.httpRequestData = [NSMutableData data];
        }
        else {
            // connection failed
            [self connection:self.handshake didFailWithError:nil];
        }
    }
}

- (void) disconnect
{
    if (self.isConnected) {
        [self sendDisconnect];
    }
    else if (self.isConnecting) {
        [self.handshake cancel];
    }
}

- (void) sendMessage:(NSString *)data
{
    [self sendMessage:data withAcknowledge:nil];
}

- (void) sendMessage:(NSString *)data withAcknowledge:(SocketIOCallback)function
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:SocketIOPacketTypeMessage];
    packet.data = data;
    packet.pId = [self addAcknowledge:function];
    [self send:packet];
}

- (void) sendJSON:(NSDictionary *)data
{
    [self sendJSON:data withAcknowledge:nil];
}

- (void) sendJSON:(NSDictionary *)data withAcknowledge:(SocketIOCallback)function
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:SocketIOPacketTypeJson];
    packet.data = [SocketIOJSONSerialization JSONStringFromObject:data error:nil];
    packet.pId = [self addAcknowledge:function];
    [self send:packet];
}

- (void) sendEvent:(NSString *)eventName withData:(id)data
{
    [self sendEvent:eventName withData:data andAcknowledge:nil];
}

- (void) sendEvent:(NSString *)eventName withData:(id)data andAcknowledge:(SocketIOCallback)function
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObject:eventName forKey:@"name"];

    // do not require arguments
    if (data != nil) {
        [dict setObject:[NSArray arrayWithObject:data] forKey:@"args"];
    }
    
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:SocketIOPacketTypeEvent];
    packet.data = [SocketIOJSONSerialization JSONStringFromObject:dict error:nil];
    packet.pId = [self addAcknowledge:function];
    if (function) {
        packet.ack = @"data";
    }
    [self send:packet];
}

- (void) sendAcknowledgement:(NSString *)pId withArgs:(NSArray *)data 
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:SocketIOPacketTypeAck];
    packet.data = [SocketIOJSONSerialization JSONStringFromObject:data error:nil];
    packet.pId = pId;
    packet.ack = @"data";

    [self send:packet];
}

# pragma mark -
# pragma mark private methods

- (void) sendDisconnect
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:SocketIOPacketTypeDisconnect];
    [self send:packet];
}

- (void) sendConnect
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:SocketIOPacketTypeConnect];
    [self send:packet];
}

- (void) sendHeartbeat
{
    SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:SocketIOPacketTypeHeartbeat];
    [self send:packet];
}

- (void) send:(SocketIOPacket *)packet
{   
    DEBUGLOG(@"send()");
    NSMutableArray *encoded = [NSMutableArray arrayWithObject:[NSNumber numberWithInt:packet.type]];
    
    NSString *pId = packet.pId != nil ? packet.pId : @"";
    if ([packet.ack isEqualToString:@"data"]) {
        pId = [pId stringByAppendingString:@"+"];
    }
    
    // Do not write pid for acknowledgements
    if (packet.type != SocketIOPacketTypeAck) {
        [encoded addObject:pId];
    }
    
    // Add the end point for the namespace to be used, as long as it is not
    // an ACK, heartbeat, or disconnect packet
    if (packet.type != SocketIOPacketTypeAck && packet.type != SocketIOPacketTypeHeartbeat && packet.type != SocketIOPacketTypeDisconnect) {
        [encoded addObject:self.endpoint];
    } 
    else {
        [encoded addObject:@""];
    }
    
    if (packet.data != nil) {
        NSString *ackpId = @"";
        // This is an acknowledgement packet, so, prepend the ack pid to the data
        if (packet.type == SocketIOPacketTypeAck) {
            ackpId = [NSString stringWithFormat:@":%@%@", packet.pId, @"+"];
        }
        [encoded addObject:[NSString stringWithFormat:@"%@%@", ackpId, packet.data]];
    }
    
    NSString *req = [encoded componentsJoinedByString:@":"];
    if (![self.transport isReady]) {
        DEBUGLOG(@"queue >>> %@", req);
        [self.queue addObject:packet];
    } 
    else {
        DEBUGLOG(@"send() >>> %@", req);
        [self.transport send:req];
        
        if ([self.delegate respondsToSelector:@selector(socketIO:didSendMessage:)]) {
            [self.delegate socketIO:self didSendMessage:packet];
        }
    }
}

- (void) doQueue 
{
    DEBUGLOG(@"doQueue() >> %lu", (unsigned long)[self.queue count]);
    
    // TODO send all packets at once ... not as seperate packets
    while ([self.queue count] > 0) {
        SocketIOPacket *packet = [self.queue objectAtIndex:0];
        [self send:packet];
        [self.queue removeObject:packet];
    }
}

- (void) onConnect:(SocketIOPacket *)packet
{
    DEBUGLOG(@"onConnect()");
    
    self.isConnected = YES;

    // Send the connected packet so the server knows what it's dealing with.
    // Only required when endpoint/namespace is present
    if ([self.endpoint length] > 0) {
        // Make sure the packet we received has an endpoint, otherwise send it again
        if (![packet.endpoint isEqualToString:self.endpoint]) {
            DEBUGLOG(@"onConnect() >> End points do not match, resending connect packet");
            [self sendConnect];
            return;
        }
    }
    
    self.isConnecting = NO;
    
    if ([self.delegate respondsToSelector:@selector(socketIODidConnect:)]) {
        [self.delegate socketIODidConnect:self];
    }
    
    // send any queued packets
    [self doQueue];
    
    [self setTimeout];
}

# pragma mark -
# pragma mark Acknowledge methods

- (NSString *) addAcknowledge:(SocketIOCallback)function
{
    if (function) {
        ++_ackCount;
        NSString *ac = [NSString stringWithFormat:@"%ld", (long)_ackCount];
        [self.acks setObject:[function copy] forKey:ac];
        return ac;
    }
    return nil;
}

- (void) removeAcknowledgeForKey:(NSString *)key
{
    [self.acks removeObjectForKey:key];
}

# pragma mark -
# pragma mark Heartbeat methods

- (void) onTimeout 
{
    DEBUGLOG(@"Timed out waiting for heartbeat.");
    [self onDisconnect:[NSError errorWithDomain:SocketIOError
                                           code:SocketIOHeartbeatTimeout
                                       userInfo:nil]];
}

- (void) setTimeout 
{
    DEBUGLOG(@"start/reset timeout");
    if (self.timeout != nil) {
        [self.timeout invalidate];
    }
    
    self.timeout = [NSTimer scheduledTimerWithTimeInterval:_heartbeatTimeout
                                                target:self 
                                              selector:@selector(onTimeout) 
                                              userInfo:nil 
                                               repeats:NO];
}


# pragma mark -
# pragma mark Regex helper method
- (NSMutableArray*) getMatchesFrom:(NSString*)data with:(NSString*)regex
{
    NSRegularExpression *nsregexTest = [NSRegularExpression regularExpressionWithPattern:regex options:0 error:nil];
    NSArray *nsmatchesTest = [nsregexTest matchesInString:data options:0 range:NSMakeRange(0, [data length])];
    NSMutableArray *arr = [NSMutableArray array];
    
    for (NSTextCheckingResult *nsmatchTest in nsmatchesTest) {
        NSMutableArray *localMatch = [NSMutableArray array];
        for (NSUInteger i = 0, l = [nsmatchTest numberOfRanges]; i < l; i++) {
            NSRange range = [nsmatchTest rangeAtIndex:i];
            NSString *nsmatchStr = nil;
            if (range.location != NSNotFound && NSMaxRange(range) <= [data length]) {
                nsmatchStr = [data substringWithRange:[nsmatchTest rangeAtIndex:i]];
            } 
            else {
                nsmatchStr = @"";
            }
            [localMatch addObject:nsmatchStr];
        }
        [arr addObject:localMatch];
    }
    
    return arr;
}


#pragma mark -
#pragma mark SocketIOTransport callbacks

- (void) onData:(NSString *)data
{
    DEBUGLOG(@"onData %@", data);
    
    // data arrived -> reset timeout
    [self setTimeout];
    
    // check if data is valid (from socket.io.js)
    NSString *regex = @"^([^:]+):([0-9]+)?(\\+)?:([^:]+)?:?(.*)?$";
    NSString *regexPieces = @"^([0-9]+)(\\+)?(.*)";
    
    // create regex result
    NSMutableArray *test = [self getMatchesFrom:data with:regex];
    
    // valid data-string arrived
    if ([test count] > 0) {
        NSArray *result = [test objectAtIndex:0];
        
        int idx = [[result objectAtIndex:1] intValue];
        SocketIOPacket *packet = [[SocketIOPacket alloc] initWithType:idx];
        
        packet.pId = [result objectAtIndex:2];
        
        packet.ack = [result objectAtIndex:3];
        packet.endpoint = [result objectAtIndex:4];
        packet.data = [result objectAtIndex:5];
        
        //
        switch (packet.type) {
            case SocketIOPacketTypeDisconnect: {
                DEBUGLOG(@"disconnect");
                [self onDisconnect:[NSError errorWithDomain:SocketIOError
                                                       code:SocketIOServerRespondedWithDisconnect
                                                   userInfo:nil]];
                break;
            }
            case SocketIOPacketTypeConnect: {
                DEBUGLOG(@"connected");
                // from socket.io.js ... not sure when data will contain sth?!
                // packet.qs = data || '';
                [self onConnect:packet];
                break;
            }
            case SocketIOPacketTypeHeartbeat: {
                DEBUGLOG(@"heartbeat");
                [self sendHeartbeat];
                break;
            }
            case SocketIOPacketTypeMessage: {
                DEBUGLOG(@"message");
                if (packet.data && ![packet.data isEqualToString:@""]) {
                    if ([self.delegate respondsToSelector:@selector(socketIO:didReceiveMessage:)]) {
                        [self.delegate socketIO:self didReceiveMessage:packet];
                    }
                }
                break;
            }
            case SocketIOPacketTypeJson: {
                DEBUGLOG(@"json");
                if (packet.data && ![packet.data isEqualToString:@""]) {
                    if ([self.delegate respondsToSelector:@selector(socketIO:didReceiveJSON:)]) {
                        [self.delegate socketIO:self didReceiveJSON:packet];
                    }
                }
                break;
            }
            case SocketIOPacketTypeEvent: {
                DEBUGLOG(@"event");
                if (packet.data && ![packet.data isEqualToString:@""]) {
                    NSDictionary *json = [packet dataAsJSON];
                    packet.name = [json objectForKey:@"name"];
                    packet.args = [json objectForKey:@"args"];
                    if ([self.delegate respondsToSelector:@selector(socketIO:didReceiveEvent:)]) {
                        [self.delegate socketIO:self didReceiveEvent:packet];
                    }
                }
                break;
            }
            case SocketIOPacketTypeAck: {
                DEBUGLOG(@"ack");
                
                // create regex result
                NSMutableArray *pieces = [self getMatchesFrom:packet.data with:regexPieces];
                
                if ([pieces count] > 0) {
                    NSArray *piece = [pieces objectAtIndex:0];
                    int ackId = [[piece objectAtIndex:1] intValue];
                    DEBUGLOG(@"ack id found: %d", ackId);
                    
                    NSString *argsStr = [piece objectAtIndex:3];
                    id argsData = nil;
                    if (argsStr && ![argsStr isEqualToString:@""]) {
                        argsData = [SocketIOJSONSerialization objectFromJSONData:[argsStr dataUsingEncoding:NSUTF8StringEncoding] error:nil];
                        if ([argsData count] > 0) {
                            argsData = [argsData objectAtIndex:0];
                        }
                    }
                    
                    // get selector for ackId
                    NSString *key = [NSString stringWithFormat:@"%d", ackId];
                    SocketIOCallback callbackFunction = [self.acks objectForKey:key];
                    if (callbackFunction != nil) {
                        callbackFunction(argsData);
                        [self removeAcknowledgeForKey:key];
                    }
                }
                
                break;
            }
            case SocketIOPacketTypeError: {
                DEBUGLOG(@"error");
                break;
            }
            case SocketIOPacketTypeNoOp: {
                DEBUGLOG(@"noop");
                break;
            }
            default: {
                DEBUGLOG(@"command not found or not yet supported");
                break;
            }
        }
        
        packet = nil;
    }
    else {
        DEBUGLOG(@"ERROR: data that has arrived wasn't valid");
    }
}

- (void) onDisconnect:(NSError *)error
{
    DEBUGLOG(@"onDisconnect()");
    BOOL wasConnected = self.isConnected;
    BOOL wasConnecting = self.isConnecting;
    
    self.isConnected = NO;
    self.isConnecting = NO;
    self.sid = nil;
    
    [self.queue removeAllObjects];
    
    // Kill the heartbeat timer
    if (self.timeout) {
        [self.timeout invalidate];
        self.timeout = nil;
    }
    
    // Disconnect the websocket, just in case
    if (self.transport) {
        // clear websocket's delegate - otherwise crashes
        self.transport.delegate = nil;
        [self.transport close];
    }
    
    if ((wasConnected || wasConnecting)) {
        if ([self.delegate respondsToSelector:@selector(socketIODidDisconnect:disconnectedWithError:)]) {
            [self.delegate socketIODidDisconnect:self disconnectedWithError:error];
        }
    }
}

- (void) onError:(NSError *)error
{
    if ([self.delegate respondsToSelector:@selector(socketIO:onError:)]) {
        [self.delegate socketIO:self onError:error];
    }
}


# pragma mark -
# pragma mark Handshake callbacks (NSURLConnectionDataDelegate)
- (void) connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response 
{
    // check for server status code (http://gigliwood.com/weblog/Cocoa/Q__When_is_an_conne.html)
    if ([response respondsToSelector:@selector(statusCode)]) {
        NSInteger statusCode = [((NSHTTPURLResponse *)response) statusCode];
        DEBUGLOG(@"didReceiveResponse() %i", statusCode);
        
        if (statusCode >= 400) {
            // stop connecting; no more delegate messages
            [connection cancel];
            
            NSString *error = [NSString stringWithFormat:NSLocalizedString(@"Server returned status code %d", @""), statusCode];
            NSDictionary *errorInfo = [NSDictionary dictionaryWithObject:error forKey:NSLocalizedDescriptionKey];
            NSError *statusError = [NSError errorWithDomain:SocketIOError
                                                       code:statusCode
                                                   userInfo:errorInfo];
            // call error callback manually
            [self connection:connection didFailWithError:statusError];
        }
    }
    
    [self.httpRequestData setLength:0];
}

- (void) connection:(NSURLConnection *)connection didReceiveData:(NSData *)data 
{
    [self.httpRequestData appendData:data]; 
}

- (void) connection:(NSURLConnection *)connection didFailWithError:(NSError *)error 
{
    NSLog(@"ERROR: handshake failed ... %@", [error localizedDescription]);
    
    self.isConnected = NO;
    self.isConnecting = NO;
    
    if ([self.delegate respondsToSelector:@selector(socketIO:onError:)]) {
        NSMutableDictionary *errorInfo = [NSDictionary dictionaryWithObject:error forKey:NSLocalizedDescriptionKey];
        
        NSError *err = [NSError errorWithDomain:SocketIOError
                                           code:SocketIOHandshakeFailed
                                       userInfo:errorInfo];
        
        [self.delegate socketIO:self onError:err];
    }
}

- (void) connectionDidFinishLoading:(NSURLConnection *)connection 
{ 	
 	NSString *responseString = [[NSString alloc] initWithData:self.httpRequestData encoding:NSASCIIStringEncoding];

    DEBUGLOG(@"connectionDidFinishLoading() %@", responseString);
    NSArray *data = [responseString componentsSeparatedByString:@":"];
    // should be SID : heartbeat timeout : connection timeout : supported transports
    
    // check each returned value (thanks for the input https://github.com/taiyangc)
    BOOL connectionFailed = false;
    NSError* error;
    
    self.sid = [data objectAtIndex:0];
    if ([self.sid length] < 1 || [data count] < 4) {
        // did not receive valid data, possibly missing a useSecure?
        connectionFailed = true;
    }
    else {
        // check SID
        DEBUGLOG(@"sid: %@", self.sid);
        NSString *regex = @"[^0-9]";
        NSPredicate *regexTest = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", regex];
        if ([self.sid rangeOfString:@"error"].location != NSNotFound || [regexTest evaluateWithObject:self.sid]) {
            [self connectToHost:self.host onPort:self.port withParams:self.params withNamespace:self.endpoint];
            return;
        }
        
        // check heartbeat timeout
        _heartbeatTimeout = [[data objectAtIndex:1] floatValue];
        if (_heartbeatTimeout == 0.0) {
            // couldn't find float value -> fail
            connectionFailed = true;
        }
        else {
            // add small buffer of 7sec (magic xD)
            _heartbeatTimeout += 7.0;
        }
        DEBUGLOG(@"heartbeatTimeout: %f", _heartbeatTimeout);
        
        // index 2 => connection timeout
        
        // get transports
        NSString *t = [data objectAtIndex:3];
        NSArray *transports = [t componentsSeparatedByString:@","];
        DEBUGLOG(@"transports: %@", transports);
        
        if ([transports indexOfObject:@"websocket"] != NSNotFound) {
            DEBUGLOG(@"websocket supported -> using it now");
            self.transport = [[SocketIOTransportWebsocket alloc] initWithDelegate:self];
        }
        else {
            DEBUGLOG(@"no transport found that is supported :( -> fail");
            connectionFailed = true;
            error = [NSError errorWithDomain:SocketIOError
                                        code:SocketIOTransportsNotSupported
                                    userInfo:nil];
        }
    }
    
    // if connection didn't return the values we need -> fail
    if (connectionFailed) {
        // error already set!?
        if (error == nil) {
            error = [NSError errorWithDomain:SocketIOError
                                        code:SocketIOServerRespondedWithInvalidConnectionData
                                    userInfo:nil];
        }

        if ([self.delegate respondsToSelector:@selector(socketIO:onError:)]) {
            [self.delegate socketIO:self onError:error];
        }
        // TODO: deprecated - to be removed
        else if ([self.delegate respondsToSelector:@selector(socketIO:failedToConnectWithError:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [self.delegate socketIO:self failedToConnectWithError:error];
#pragma clang diagnostic pop
        }
        
        // make sure to do call all cleanup code
        [self onDisconnect:error];
        
        return;
    }
    
    [self.transport open];
}

#if DEBUG_CERTIFICATE

// to deal with self-signed certificates
- (BOOL) connection:(NSURLConnection *)connection
canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)protectionSpace
{
    return [protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust];
}

- (void) connection:(NSURLConnection *)connection
didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{
    if ([challenge.protectionSpace.authenticationMethod
         isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        // we only trust our own domain
        if ([challenge.protectionSpace.host isEqualToString:self.host]) {
            SecTrustRef trust = challenge.protectionSpace.serverTrust;
            NSURLCredential *credential = [NSURLCredential credentialForTrust:trust];
            [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
        }
    }
    
    [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
}
#endif



@end
