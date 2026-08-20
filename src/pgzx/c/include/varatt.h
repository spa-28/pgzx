/*
 * PG15 compatibility shim.
 *
 * varatt.h was split out of postgres.h in PG16. On PG15 this shim stays
 * empty (postgres.h, included first, still provides the varatt definitions);
 * on PG16+ it transparently picks up the real header via include_next.
 */
#if PG_VERSION_NUM >= 160000
#include_next <varatt.h>
#endif
