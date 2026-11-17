#ifndef ARX_SECTION_GATES_H
#define ARX_SECTION_GATES_H
#include <stdbool.h>
#include <stddef.h>
static inline bool local_sources_only(const long *types, size_t count) {
    if (count == 0 || count > 32) return false;
    for (size_t i = 0; i < count; ++i) if (types[i] != 0) return false;
    return true;
}
static inline bool may_create_section(bool local, bool list_saved, bool exact_id,
                                      bool marker, bool methods, bool uncertain) {
    return local && list_saved && exact_id && marker && methods && !uncertain;
}
static inline bool may_clean_list(bool saved, bool exact_id, bool marker,
                                  bool local, bool uncertain) {
    return saved && exact_id && marker && local && !uncertain;
}
#endif
