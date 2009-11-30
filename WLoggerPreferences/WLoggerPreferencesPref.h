//
//  WLoggerPreferencesPref.h
//
//  Created by Per Ejeklint on 2009-11-16.
//  Copyright 2009 Heimore Group AB. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <PreferencePanes/PreferencePanes.h>
#import <CoreFoundation/CoreFoundation.h>

@interface WLoggerPreferencesPref : NSPreferencePane {
	NSMutableDictionary *settings;

	IBOutlet NSTextField *rainLabel;
	IBOutlet NSLevelIndicator *rainBatteryIndicator;
	IBOutlet NSTextField *windLabel;
	IBOutlet NSLevelIndicator *windBatteryIndicator;
	IBOutlet NSTextField *outdoorLabel;
	IBOutlet NSLevelIndicator *outdoorTempBatteryIndicator;
	IBOutlet NSTextField *indoorLabel;
	IBOutlet NSLevelIndicator *indoorTempBatteryIndicator;
	IBOutlet NSTextField *uvLabel;
	IBOutlet NSLevelIndicator *uvBatteryIndicator;
	IBOutlet NSProgressIndicator *spinner;


	NSConnection *connection;
	id proxy;
}

- (IBAction)debugClicked:(id)sender;
- (IBAction)validateClicked:(id)sender;

@end
