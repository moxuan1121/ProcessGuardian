#import <Foundation/Foundation.h>

// Called on SpringBoard's main thread after a front display change.
void MCCPUGuardFrontmostChanged(NSString *bundleIdentifier);
// Retry attaching to a newly started foreground process without periodic polling.
void MCCPUGuardProcessStarted(void);
