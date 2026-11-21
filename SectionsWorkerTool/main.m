#import <Foundation/Foundation.h>
#import "Worker.h"

// Embedded helper entry: the same bounded worker the app once ran in process,
// now in its own executable inside the app bundle. The helper carries only the
// inherited-sandbox entitlements, and the parent speaks the fixed marker/JSON
// protocol over pipes. A missing or refused exchange fails closed, same as the
// in-process entry did.
int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    return [ARXSectionWorker run];
}
