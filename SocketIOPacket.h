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

#import <Foundation/Foundation.h>

typedef enum SocketIOPacketType {
    SocketIOPacketTypeDisconnect = 0,
    SocketIOPacketTypeConnect = 1,
    SocketIOPacketTypeHeartbeat = 2,
    SocketIOPacketTypeMessage = 3,
    SocketIOPacketTypeJson = 4,
    SocketIOPacketTypeEvent = 5,
    SocketIOPacketTypeAck = 6,
    SocketIOPacketTypeError = 7,
    SocketIOPacketTypeNoOp = 8,
} SocketIOPacketType;

@interface SocketIOPacket : NSObject {
}

@property (nonatomic, readonly) NSString *stringType;
@property (nonatomic, assign) SocketIOPacketType type;
@property (nonatomic, copy) NSString *pId;
@property (nonatomic, copy) NSString *ack;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *data;
@property (nonatomic, copy) NSString *endpoint;
@property (nonatomic, copy) NSArray *args;

- (id) initWithType:(SocketIOPacketType)packetType;
- (id) dataAsJSON;

@end
