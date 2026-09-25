#import <Foundation/Foundation.h>

// Called only on the daemon's serial worker queue; unchanged PID/config is left active.
void MCCPUGuardUpdate(NSDictionary *configs, NSDictionary *pidSnapshot, BOOL enabled,
                      void (^log)(NSString *));
