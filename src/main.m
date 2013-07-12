//
//  main.m
//

#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, char *argv[])
{
	NSLog(@"Starting up");
	AppDelegate *ad = [[AppDelegate alloc] init];

	[[NSRunLoop currentRunLoop] run];
}
