#include "RXNativeReaction.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    unsigned int kind;
    for (kind = 0; kind <= RXNativeQuestion; ++kind) {
        assert(RXNativeType(kind, 0) == 2000 + (int)kind);
        assert(RXNativeType(kind, 1) == 3000 + (int)kind);
    }
    assert(RXNativeType(6, 0) == -1);
    assert(RXNativeType(UINT32_MAX, 1) == -1);
    assert(RXNativeGUIDIsValid("01234567-89ab-cdef-0123-456789ABCDEF"));
    assert(!RXNativeGUIDIsValid(NULL));
    assert(!RXNativeGUIDIsValid(""));
    assert(!RXNativeGUIDIsValid("01234567-89ab-cdef-0123-456789ABCDE"));
    assert(!RXNativeGUIDIsValid("01234567-89ab-cdef-0123-456789ABCDEFX"));
    assert(!RXNativeGUIDIsValid("01234567/89ab-cdef-0123-456789ABCDEF"));
    assert(!RXNativeGUIDIsValid("Z1234567-89ab-cdef-0123-456789ABCDEF"));
    puts("native reaction types and GUID validation passed");
    return 0;
}
