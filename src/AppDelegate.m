

#import "AppDelegate.h"
#import "DataKeys.h"
#import "RemoteProtocol.h"

//#import <Growl/GrowlApplicationBridge.h>


@implementation AppDelegate


static BOOL gDebugPrint;


+ (BOOL) debugPrint {
	return gDebugPrint;
}


- (id) init {
	if ((self = [super init]))
	{
		CFBooleanRef temp = (CFBooleanRef) CFPreferencesCopyValue(CFSTR("useDebugLogging"), APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
		gDebugPrint = (temp) ? CFBooleanGetValue(temp) : NO;
		
		// Postpone the setup a few seconds to make sure other stuff is up and running
		[self performSelector:@selector(setup:) withObject:self afterDelay:5.0];
		
		return self;
	}
	return nil;
}


- (void) setup: (id) anObject {
	(void) anObject;

	ra = [[ReadingAssembler alloc] init];
	wmr100n = [[WMR100NDeviceController alloc] init];	
	weatherReport = [[SBCouchDocument alloc] init];
	
	self.currentStatus = [NSMutableDictionary dictionaryWithCapacity:5];
	
	// Get the settings. If no exist, create a default set save it.
	NSDictionary *settings = [self getSettings];
	if (!settings || [settings count] == 0) {
		// Set up default settings
		NSMutableDictionary *new = [[NSMutableDictionary alloc] initWithCapacity:6];
		[new setObject:@"localhost" forKey:@"couchDBURL"];
		[new setObject:[NSNumber numberWithInt:5984] forKey:@"couchDBPort"];
		[new setObject:@"weatheruser" forKey:@"couchDBUser"];
        [new setObject:@"weatheruser" forKey:@"couchDBPassword"];
		[new setObject:@"wdata" forKey:@"couchDBDBName"];
		[new setObject:@"1" forKey:@"couchDBUpdateInterval"];
		[new setObject:[NSNumber numberWithBool:YES] forKey:@"useComputersClock"];
		[new setObject:[NSNumber numberWithBool:NO] forKey:@"useTwitter"];
		[new setObject:[NSNumber numberWithBool:YES] forKey:@"useDebugLogging"];
		[new setObject:@"" forKey:@"twitterUser"];
		[self saveSettings:new];
		settings = new;
	}
	
	// Set up remote objects connection
	serverConnection=[[NSConnection new] autorelease];
    [serverConnection setRootObject:self];
    [serverConnection registerName:KEY_REMOTE_CONNECTION_NAME];

	// Set up notifications
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];	
	[nc addObserver:self selector:@selector(readingListener:) name:@"Reading" object:nil];
	[nc addObserver:self selector:@selector(minuteReportListener:) name:@"MinuteReport" object:nil];
	[nc addObserver:self selector:@selector(statusReportListener:) name:@"StatusReport" object:nil];
	[nc addObserver:self selector:@selector(deviceAddedListener:) name:@"DeviceAdded" object:nil];
	[nc addObserver:self selector:@selector(deviceRemovedListener:) name:@"DeviceRemoved" object:nil];	
	
	// Hour chime timer. Shoot every hour, start at next whole hour
	NSTimeInterval since2001 = [[NSDate date] timeIntervalSinceReferenceDate];
	NSDate *nextHour = [NSDate dateWithTimeIntervalSinceReferenceDate: (int)(since2001 / 3600) * 3600 + 3600]; 
	
	myTickTimer = [[NSTimer alloc] initWithFireDate:nextHour interval:3600 target:self selector:@selector(hourChime:) userInfo:NULL repeats:YES];
	[[NSRunLoop currentRunLoop] addTimer:myTickTimer forMode:NSDefaultRunLoopMode];
	
	// Set up self as Growl delegate.
	//		[GrowlApplicationBridge setGrowlDelegate:self];
}


#pragma mark Remote Objects methods BEGIN

- (BOOL) setDebug: (NSNumber*) debug {
		
	gDebugPrint = [debug boolValue];
	CFPreferencesSetValue(CFSTR("useDebugLogging"), (__bridge CFPropertyListRef)(debug), APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	CFPreferencesSynchronize(APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	return gDebugPrint;
}


- (NSDictionary *) getSettings {
	CFArrayRef aref = CFPreferencesCopyKeyList(APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	CFDictionaryRef dref = CFPreferencesCopyMultiple(aref, APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	return (__bridge NSDictionary*) dref;
}

- (NSDictionary *) getLevels {
	NSLog(@"Returning current status %@", self.currentStatus);
	return [NSDictionary dictionaryWithDictionary:self.currentStatus];
}


- (BOOL) saveSettings: (NSDictionary *) settings {
	for (id key in settings) {
		CFPreferencesSetValue((__bridge CFStringRef)key, [settings objectForKey:key], APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	}
	// Set absent user to empty string
	if (![settings objectForKey:@"couchDBUser"]) {
		CFPreferencesSetValue(CFSTR("couchDBUser"), CFSTR(""), APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	}
	if (![settings objectForKey:@"twitterUser"]) {
		CFPreferencesSetValue(CFSTR("twitterUser"), CFSTR(""), APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	}
	// Save to disk
	CFPreferencesSynchronize(APP_ID, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
	
	// Sync globals
	NSInteger interval = [[settings objectForKey:@"couchDBUpdateInterval"] integerValue];
	if (interval < 1 || interval > 1000)
		interval = 2; // Reasonable default value if it should be missing
	[ra setInterval: interval];
	
	gDebugPrint = [[settings objectForKey:@"useDebugLogging"] boolValue];

	// Re-do the couchdb setup in case settings have changed
	[self setupCouchDB:settings];
	
	return YES;
}

#pragma mark Remote Objects methods END

- (BOOL) setupCouchDB: (NSDictionary*) settings {	
	NSNumber *port = [settings valueForKey:@"couchDBPort"];	
	NSString *couchDBDBName = [settings valueForKey:@"couchDBDBName"];
	NSString *username = [settings valueForKey:@"couchDBUser"];
	NSString *password = [settings valueForKey:@"couchDBPassword"];
	
	NSString *hoststring;
	if ([username length] > 0) {
//		EMGenericKeychainItem *keychainItem = [KeyChainHandler getCouchDBKeychainItemForUser: username]; 
		hoststring = [NSString stringWithFormat:@"%@:%@@%@",
					  username,
//					  [keychainItem password],
					  password, // This one - instead of above
					  [settings valueForKey:@"couchDBURL"]];
	} else {
		hoststring = [settings valueForKey:@"couchDBURL"];
	}
	
	SBCouchServer *tmpCouch = [[SBCouchServer alloc] initWithHost:hoststring port:[port integerValue]];
	
	// Test if connection is ok
	if ([tmpCouch version] == nil) {
		NSLog(@"Error connecting to CouchDB at %@", [couch serverURLAsString]);
		return NO;
	}
	
	couch = tmpCouch;
	[couch createDatabase:couchDBDBName];
	db = [[couch database:couchDBDBName] retain];
	return YES;
}


#pragma mark Remote Objects methods END


- (void) hourChime: (NSTimer*) timer {
	// Store status in db
	SBCouchDocument *storedReport = [db getDocument:KEY_DOC_STATUS withRevisionCount:NO andInfo:NO revision:nil];
	if (!storedReport) {
		storedReport = [[SBCouchDocument alloc] initWithNSDictionary:self.currentStatus couchDatabase:db];
		[storedReport setObject:KEY_DOC_STATUS forKey:KEY_COUCH_ID];
	} else {
		[storedReport addEntriesFromDictionary:self.currentStatus];
	}
	[storedReport setObject:KEY_DOC_STATUS forKey:KEY_DOC_DOCTYPE];
	[db putDocument:storedReport named:KEY_DOC_STATUS];
}


- (void) dealloc {
	[super dealloc];
}


//
// Notification listeners
//

- (void) readingListener:(NSNotification *)notification {	
	NSDictionary *userInfo = [notification userInfo];
	
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

	
- (void) minuteReportListener:(NSNotification *)notification {
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


- (void) statusReportListener:(NSNotification *)notification {
	NSDictionary *userInfo = [notification userInfo];
	
	[self.currentStatus addEntriesFromDictionary:userInfo];
}


- (void)deviceAddedListener:(NSNotification *)notification {
	(void) notification;
	
	NSLog(@"Weather station plugged in. WLoggerDaemon build 3");
	
	NSDictionary *settings = [self getSettings];

	[self setupCouchDB:settings];
	
	
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
	
	NSLog(@"Weather station removed");

	// Stop twittering if it's on
	if (myTickTimer) {
		[myTickTimer invalidate];
		[myTickTimer release];
		myTickTimer = NULL;
	}
	
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
