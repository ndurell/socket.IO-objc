//
//  SocketIOPacket.h
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

#import "SocketIOPacket.h"
#import "SocketIOJSONSerialization.h"

@implementation SocketIOPacket


- (id) initWithType:(SocketIOPacketType)packetType
{
    self = [self init];
    if (self) {
        self.type = packetType;
    }
    return self;
}

- (id) dataAsJSON
{
    if (self.data) {
        NSData *utf8Data = [self.data dataUsingEncoding:NSUTF8StringEncoding];
        return [SocketIOJSONSerialization objectFromJSONData:utf8Data error:nil];
    }
    else {
        return nil;
    }
}

- (NSString *)stringType {
    switch(self.type) {
        case SocketIOPacketTypeAck:
            return @"ack";
        case SocketIOPacketTypeDisconnect:
            return @"disconnect";
        case SocketIOPacketTypeConnect:
            return @"connect";
        case SocketIOPacketTypeMessage:
            return @"message";
        case SocketIOPacketTypeJson:
            return @"json";
        case SocketIOPacketTypeEvent:
            return @"event";
        case SocketIOPacketTypeError:
            return @"error";
        case SocketIOPacketTypeNoOp:
            return @"noop";
        case SocketIOPacketTypeHeartbeat:
            return @"heartbeat";
    }
    return nil;
}


@end

