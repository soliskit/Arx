#include "gates.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    assert(arx_uuid("11111111-1111-4111-8111-111111111111"));
    assert(arx_uuid("ABCDEF01-abcd-ABCD-1234-0123456789ab"));
    assert(!arx_uuid(NULL));
    assert(!arx_uuid(""));
    assert(!arx_uuid("11111111-1111-4111-8111-11111111111g"));
    assert(!arx_uuid("11111111_1111-4111-8111-111111111111"));
    assert(!arx_uuid("11111111-1111-4111-8111-111111111111/"));
    unsigned allowed = 0, bound = 0, section = 0;
    for (unsigned mask = 0; mask < 32; ++mask) {
        bool a = mask & 1, b = mask & 2, c = mask & 4;
        bool d = mask & 8, e = mask & 16;
        bool permitted = arx_read_allowed(a, b, c, d);
        assert(permitted == ((mask & 15) == 15));
        allowed += permitted;
        bool identity = arx_identity_bound(a, b, c, d, e);
        assert(identity == (mask == 31));
        bound += identity;
        bool membership = arx_section_bound(a, b, c);
        assert(membership == ((mask & 7) == 7));
        section += membership;
    }
    assert(allowed == 2 && bound == 1 && section == 4);
    puts("PASS strict UUID and exhaustive read/identity/membership guards");
    return 0;
}
