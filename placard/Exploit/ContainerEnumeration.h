#ifndef PlacardContainerEnumeration_h
#define PlacardContainerEnumeration_h
#import <Foundation/Foundation.h>
// Visits each candidate synchronously; returning YES stops the scan.
// Result: 1 = stopped by visitor, 0 = exhausted/timed out, -1 = setup failed.
int placard_visit_containers(BOOL (^ _Nonnull visitor)(NSString * _Nonnull path));
NSString * _Nullable placard_container_identifier(NSString * _Nonnull path);
#endif
