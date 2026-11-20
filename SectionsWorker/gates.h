#ifndef ARX_SECTION_READER_GATES_H
#define ARX_SECTION_READER_GATES_H
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

static inline bool arx_uuid(const char *s) {
    if (!s || strlen(s) != 36) return false;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (s[i] != '-') return false;
        } else if (!((s[i] >= '0' && s[i] <= '9') ||
                     (s[i] >= 'a' && s[i] <= 'f') ||
                     (s[i] >= 'A' && s[i] <= 'F'))) return false;
    }
    return true;
}

static inline bool arx_read_allowed(bool read, bool granted_list,
                                    bool list_id_valid, bool reminder_id_valid) {
    return read && granted_list && list_id_valid && reminder_id_valid;
}

static inline bool arx_identity_bound(bool list_id, bool list_name,
                                      bool reminder_id, bool reminder_title,
                                      bool reminder_parent) {
    return list_id && list_name && reminder_id && reminder_title && reminder_parent;
}

static inline bool arx_section_bound(bool section_id, bool parent_id,
                                     bool expected_parent) {
    return section_id && parent_id && expected_parent;
}
#endif
