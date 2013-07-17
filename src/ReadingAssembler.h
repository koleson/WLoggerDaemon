//
//  ReadingAssembler.h
//  USBWeatherStationReader
//
//  Created by Per Ejeklint on 2009-04-28.
//  Copyright 2009 Heimore Group AB. All rights reserved.
//

#import <Cocoa/Cocoa.h>


@interface ReadingAssembler : NSObject {
	NSUInteger interval;
	BOOL useComputersClock;
}

@property NSUInteger interval;
@property BOOL useComputersClock;

@end

