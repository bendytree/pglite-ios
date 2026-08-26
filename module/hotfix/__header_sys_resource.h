#ifndef __wasilibc___header_sys_resource_h
#define __wasilibc___header_sys_resource_h

/* Derived from wasi-libc (wasi-sdk 33), which is distributed under
 * "Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT"; see NOTICE.
 *
 * wasipg shadow of wasi-sdk 33's header (found first via the SDK's
 * `-isystem hotfix`): identical except the getrusage declaration is
 * omitted — the SDK's hotfix/patch.h maps getrusage to its own
 * sdk_getrusage stub with an (int, void *) signature, and the real
 * declaration (added to wasi-libc after the bundled wasi-sdk 25)
 * would be macro-rewritten into a conflicting redeclaration. */

#include <__struct_rusage.h>

#define RUSAGE_SELF 1
#define RUSAGE_CHILDREN 2

#endif
