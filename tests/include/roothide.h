#import <Foundation/Foundation.h>
/* Host tests redirect all device paths to one temporary test directory. */
static inline NSString *jbroot(NSString *path) {
    return [[NSString stringWithUTF8String:getenv("PG_TEST_ROOT")] stringByAppendingPathComponent:path];
}
