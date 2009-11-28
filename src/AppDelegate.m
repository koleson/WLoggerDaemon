

#import "AppDelegate.h"
#import "KeyChainHandler.h"
#import "DataKeys.h"
//#import <Growl/GrowlApplicationBridge.h>

@implementation AppDelegate


static BOOL gDebugPrint;


+ (void)initialize
{
	gDebugPrint = NO;
}


+ (BOOL) debugPrint {
	return gDebugPrint;
}


- (id) init {
	if ((self = [super init]))
	{
		ra = [[ReadingAssembler alloc] init];
		wmr100n = [[WMR100NDeviceController alloc] init];	
		weatherReport = [[SBCouchDocument alloc] init];
		
		// Get the settings. If no exist, create a default set save it.
		NSDictionary *settings = [self getSettings];
		if (!settings || [settings count] == 0) {
			// Set up default settings
			NSMutableDictionary *new = [[NSMutableDictionary alloc] initWithCapacity:6];
			[new setObject:@"localhost" forKey:@"couchDBURL"];
			[new setObject:[NSNumber numberWithInt:5984] forKey:@"couchDBPort"];
			[new setObject:@"" forKey:@"couchDBUser"];
			[new setObject:@"wdata" forKey:@"couchDBDBName"];
			[new setObject:@"2" forKey:@"couchDBUpdateInterval"];
			[new setObject:[NSNumber numberWithBool:YES] forKey:@"useComputersClock"];
			[new setObject:[NSNumber numberWithBool:NO] forKey:@"useTwitter"];
			[new setObject:@"" forKey:@"twitterUser"];
			[self saveSettings:new];
			settings = new;
		}
		
		[self setupTwitter:settings];
		[self setupCouchDB:settings];
		[self setupNotificationSubscription];
		[self setupConnection];
		
		// Set up the tick timer
		myTickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick:) userInfo:NULL repeats:YES];
		
		// Set up self as Growl delegate.
//		[GrowlApplicationBridge setGrowlDelegate:self];
		
		return self;
	}
	return nil;
}


#pragma mark Remote Objects methods BEGIN

- (void) setupConnection {
	serverConnection=[[NSConnection new] autorelease];
    [serverConnection setRootObject:self];
    [serverConnection registerName:@"se.ejeklint.WLoggerDaemonConnection"];
}


- (BOOL) setDebug: (NSNumber*) debug {
	NSLog(@"Changed Debug setting to %d", [debug boolValue]);
	gDebugPrint = [debug boolValue];
	return gDebugPrint;
}


- (NSDictionary *) getSettings {
	CFArrayRef aref = CFPreferencesCopyKeyList(APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	CFDictionaryRef dref = CFPreferencesCopyMultiple(aref, APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	return (NSDictionary*) dref;
}


- (BOOL) saveSettings: (NSDictionary *) settings {
	for (id key in settings) {
		CFPreferencesSetValue((CFStringRef)key, [settings objectForKey:key], APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	}
	// Set absent user to empty string
	if (![settings objectForKey:@"couchDBUser"]) {
		CFPreferencesSetValue(CFSTR("couchDBUser"), CFSTR(""), APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	}
	if (![settings objectForKey:@"twitterUser"]) {
		CFPreferencesSetValue(CFSTR("twitterUser"), CFSTR(""), APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	}
	
	int interval = [[settings objectForKey:@"couchDBUpdateInterval"] integerValue];
	if (interval < 1 || interval > 1000)
		interval = 2; // Reasonable default value if it should be missing
	[ra setInterval: interval]; 
	if (DEBUGALOT)
		NSLog(@"Setting update interval to %d", interval);
	
	// Save to disk
	CFPreferencesSynchronize(APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	return YES;
}


- (BOOL) setupTwitter: (NSDictionary*) settings {
	if (!twitterEngine)
		twitterEngine = [[MGTwitterEngine alloc] initWithDelegate:self];
	else
		[twitterEngine closeAllConnections];
	
	NSString *username = [settings objectForKey:@"twitterUser"];
	if ([username length] > 0) {
		EMGenericKeychainItem *keychainItem = [KeyChainHandler getTwitterKeychainItemForUser: username];
		[twitterEngine setUsername:username password:[keychainItem password]];
//		[twitterEngine checkUserCredentials];
	} else {
		return NO;
	}

	[self saveSettings: settings];
	return YES;
}


- (BOOL) setupCouchDB: (NSDictionary*) settings {	
	NSNumber *port = [settings valueForKey:@"couchDBPort"];	
	NSString *couchDBDBName = [settings valueForKey:@"couchDBDBName"];
	NSString *username = [settings valueForKey:@"couchDBUser"];
	
	NSString *hoststring;
	if ([username length] > 0) {
		EMGenericKeychainItem *keychainItem = [KeyChainHandler getCouchDBKeychainItemForUser: username]; 
		hoststring = [NSString stringWithFormat:@"%@:%@@%@",
					  [settings valueForKey:@"couchDBUser"],
					  [keychainItem password],
					  [settings valueForKey:@"couchDBURL"]];
	} else {
		hoststring = [settings valueForKey:@"couchDBURL"];
	}
	
	if (DEBUGALOT)
		NSLog(@"Calling CouchDB with: %@:%d/%@", hoststring, [port integerValue], couchDBDBName);
	
	SBCouchServer *tmpCouch = [[SBCouchServer alloc] initWithHost:hoststring port:[port integerValue]];
	
	// Test if connection is ok
	if ([tmpCouch version] == nil) {
		NSLog(@"Error connecting to CouchDB at %@", [couch serverURLAsString]);
		return NO;
	}
	
	NSString *updateIntervalString = [settings objectForKey:@"couchDBUpdateInterval"];
	
	// All OK. Save settings and ref to couchdb server.
	[self saveSettings:settings];
	couch = tmpCouch;
	[couch createDatabase:couchDBDBName];
	db = [[couch database:couchDBDBName] retain];
	return YES;
}

#pragma mark Remote Objects methods END

//
// Update twitter with current readings
//
- (void) updateTwitter {
	NSMutableString *s = [NSMutableString stringWithCapacity:140];
	NSString *key = [NSString stringWithFormat:@"%@%d", KEY_TEMP_AND_HUM_READING_SENSOR_, 1];
	NSDictionary *tempOut = [weatherReport objectForKey:key];
	if (tempOut) {
		NSDictionary *d = [tempOut objectForKey:KEY_READINGS];
		[s appendFormat:@"Out: %.1f�C/%d%% ",
		 [[d objectForKey:KEY_TEMP_OUTDOOR] doubleValue],
		 [[d objectForKey:KEY_HUMIDITY_OUTDOOR] intValue]
		];
	}
	
	tempOut = [weatherReport objectForKey:KEY_WIND_READING];
	if (tempOut) {
		NSDictionary *d = [tempOut objectForKey:KEY_READINGS];
		[s appendFormat:@"Wind: %d�, gust %.1f m/s, avg %.1f\n",
		 [[d objectForKey:KEY_WIND_DIRECTION] intValue],
		 [[d objectForKey:KEY_WIND_AVERAGE] doubleValue],
		 [[d objectForKey:KEY_WIND_GUST] doubleValue]
		];
	}
	
	tempOut = [weatherReport objectForKey:KEY_UV_READING];
	if (tempOut) {
		NSDictionary *d = [tempOut objectForKey:KEY_READINGS];
		[s appendFormat:@"UV Index: %d ",
		 [[d objectForKey:KEY_UV_INDEX] intValue]
		];
	}
	
	tempOut = [weatherReport objectForKey:KEY_RAIN_READING];
	if (tempOut) {
		NSDictionary *d = [tempOut objectForKey:KEY_READINGS];
		[s appendFormat:@"Rain 24h: %d ",
		 [[d objectForKey:KEY_RAIN_24H] intValue]
		];
	}
	
	tempOut = [weatherReport objectForKey:KEY_BAROMETER_READING];
	if (tempOut) {
		NSDictionary *d = [tempOut objectForKey:KEY_READINGS];
		[s appendFormat:@"Baro: %d mbar Forecast: %@\n",
		 [[d objectForKey:KEY_BAROMETER_RELATIVE] intValue],
		 [d objectForKey:KEY_BAROMETER_ABSOLUTE_FORECAST_STRING]
		];
	}
	
	key = [NSString stringWithFormat:@"%@%d", KEY_TEMP_AND_HUM_READING_SENSOR_, 0];
	tempOut = [weatherReport objectForKey:key];
	if (tempOut) {
		NSDictionary *d = [tempOut objectForKey:KEY_READINGS];
		[s appendFormat:@"In: %.1f�C/%d%% ",
		 [[d objectForKey:KEY_TEMP_INDOOR] doubleValue],
		 [[d objectForKey:KEY_HUMIDITY_INDOOR] intValue]
		];
	}
	
	if (DEBUGALOT)
		NSLog(@"Twitter string with %d chars:\n%@", [s length], s);

	[twitterEngine sendUpdate:s];
}


- (void) tick:(NSTimer*) timer {	
	NSDate *now = [NSDate date];
	unsigned unitFlags = NSMinuteCalendarUnit | NSSecondCalendarUnit | NSHourCalendarUnit;
	NSDateComponents *dc = [[NSCalendar currentCalendar] components:unitFlags fromDate: now];

	// Tweet update every 60 minutes @ 00 seconds
	if ([dc second] == 0
		&& [dc minute] == 0
		&& CFPreferencesCopyValue(CFSTR("useTwitter"), APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost)) {
		[self updateTwitter];
	}
}


- (void)dealloc {
	[super dealloc];
}


- (void)setupNotificationSubscription {
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	
	// Notifications from ReadAssembler
	[nc addObserver:self selector:@selector(readingListener:) name:@"Reading" object:nil];
	[nc addObserver:self selector:@selector(minuteReportListener:) name:@"MinuteReport" object:nil];
	
	// Notifications from DeviceController
	[nc addObserver:self selector:@selector(deviceAddedListener:) name:@"DeviceAdded" object:nil];
	[nc addObserver:self selector:@selector(deviceRemovedListener:) name:@"DeviceRemoved" object:nil];	
}


- (void)readingListener:(NSNotification *)notification {	
	NSDictionary *userInfo = [notification userInfo];
//	NSLog(@"****** Got reading: %@", userInfo);
	
	// Add a timestamp so we can sort out too old readings
	NSDate *now = [NSDate date];
	NSMutableDictionary *readingWithTimeStamp = [NSMutableDictionary dictionaryWithCapacity:2];
	[readingWithTimeStamp setObject:now forKey:KEY_TIMESTAMP];
	[readingWithTimeStamp setObject:[userInfo objectForKey:KEY_READINGS] forKey:KEY_READINGS];
	
	if (!weatherReport) {
		weatherReport = [NSMutableDictionary dictionaryWithCapacity:5];
	}
	[weatherReport setObject:readingWithTimeStamp forKey:[userInfo objectForKey:KEY_READING_TYPE]];
}

	
- (void)minuteReportListener:(NSNotification *)notification {
	NSDictionary *userInfo = [notification userInfo];

	// Store report
	SBCouchDocument *storedReport = [[SBCouchDocument alloc] initWithNSDictionary:userInfo couchDatabase:db];
	[storedReport setObject:KEY_DOC_READINGS forKey:KEY_DOC_DOCTYPE];
	
	// Store all nested values in weatherReport
	for (id key in weatherReport) {
		// Check if not too old (should be younger than 120 seconds)
		NSDictionary *dict = [weatherReport objectForKey:key];
		NSDate *timestamp = (NSDate*) [dict objectForKey:KEY_TIMESTAMP];
		if ([timestamp timeIntervalSinceNow] < -120.0) {
			if (DEBUGALOT)
				NSLog(@"Discarding old report: %@", dict);
			continue;
		}
		[storedReport addEntriesFromDictionary:[dict objectForKey:KEY_READINGS]];
	}

	[storedReport put];
}


- (void)deviceAddedListener:(NSNotification *)notification {
	(void) notification;
	
	NSLog(@"WMR100 plugged in");
/*	
	[GrowlApplicationBridge
	 notifyWithTitle:@"Base unit connected"
	 description:@"The weather station has been connected. Weather reporting will start."
	 notificationName:@"Base unit connected"
	 iconData:nil
	 priority:0
	 isSticky:NO
	 clickContext:nil]; */
}


- (void) deviceRemovedListener: (NSNotification *)notification {
	(void) notification;
	
	NSLog(@"WMR100 removed");

	// Remove ongoing report and reset minute cycle count
	if (weatherReport) {
		[weatherReport release];
		weatherReport = nil;
	}
	
/*	[GrowlApplicationBridge
	 notifyWithTitle:@"Base unit disconnected"
	 description:@"The weather station has been disconnected. Weather reporting will suspend until it is connected again."
	 notificationName:@"Base unit disconnected"
	 iconData:nil
	 priority:2
	 isSticky:NO
	 clickContext:nil]; */
}


#pragma mark MGTwitterEngineDelegate methods


- (void)requestSucceeded:(NSString *)connectionIdentifier
{
	// TODO: Indicate that Twitter is updated
//    NSLog(@"Request succeeded for connectionIdentifier = %@", connectionIdentifier);
}


- (void)requestFailed:(NSString *)connectionIdentifier withError:(NSError *)error
{
    NSLog(@"Request failed for connectionIdentifier = %@, error = %@ (%@)", 
          connectionIdentifier, 
          [error localizedDescription], 
          [error userInfo]);
}


// Growl delegate methods
/*
- (NSDictionary*) registrationDictionaryForGrowl {
	NSMutableDictionary *d = [[NSMutableDictionary alloc] init];
	NSArray *a = [[NSArray alloc] initWithObjects: @"Battery warning", @"Base unit disconnected", @"Base unit connected", @"Power loss", @"Notification", @"Internal error", nil];
	[d setObject:a forKey:GROWL_NOTIFICATIONS_ALL];
	[d setObject:a forKey:GROWL_NOTIFICATIONS_DEFAULT];
	[d setObject:@"WLogger" forKey:GROWL_APP_ID];
	return d;
}

- (NSString *) applicationNameForGrowl {
	return @"WLogger";
}
*/

@end
