#include "gates.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    long local[] = {0, 0};
    assert(local_sources_only(local, 2));
    assert(!local_sources_only(local, 0));
    assert(!local_sources_only(local, 33));
    for (long type = -1; type < 12; ++type) {
        long types[] = {0, type};
        assert(local_sources_only(types, 2) == (type == 0));
    }
    unsigned sectionAllowed = 0, cleanupAllowed = 0;
    for (unsigned mask = 0; mask < 64; ++mask) {
        bool a = mask & 1, b = mask & 2, c = mask & 4;
        bool d = mask & 8, e = mask & 16, f = mask & 32;
        bool allowed = may_create_section(a, b, c, d, e, f);
        assert(allowed == (mask == 31));
        sectionAllowed += allowed;
        bool clean = may_clean_list(a, b, c, d, e);
        assert(clean == ((mask & 31) == 15));
        cleanupAllowed += clean;
    }
    assert(sectionAllowed == 1 && cleanupAllowed == 2);
    puts("All local-source and 64-case creation/cleanup gates passed");
    return 0;
}
