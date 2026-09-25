#import <Foundation/Foundation.h>

// Called only on the daemon's serial worker queue.
void MCCPUGuardUpdate(NSDictionary *configs, NSDictionary *pidSnapshot, BOOL enabled,
                      void (^log)(NSString *));
void MCCPUGuardSetFrontmostHash(uint64_t hash);
uint64_t MCCPUGuardNextDelay(void);
void MCCPUGuardSample(void (^log)(NSString *));
