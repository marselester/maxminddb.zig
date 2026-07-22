/* C ABI
 *
 * Lifetime and concurrency:
 * - mmdb_reader_t is read-only after open, so it can be shared across threads freely.
 *   It's alive until mmdb_close.
 * - mmdb_entry_t (a find result) is valid while its reader is open.
 * - mmdb_record_t is an arena-owning handle with single-threaded access,
 *   alive until mmdb_record_close.
 * - mmdb_value_t is a decoded value (scalar, array, or map).
 *   It lives in its owning mmdb_record_t's arena, or for a scan result,
 *   in the mmdb_scan_iter_t that yielded it.
 *   Values are immutable after decode, so they may be read concurrently.
 * - mmdb_scan_iter_t is single-threaded, one per worker, alive until mmdb_scan_iter_close.
 *   Each result value it yields is valid only until the next mmdb_scan_iter_next
 *   on that iterator because its backing cache may evict it,
 *   so you must copy what you need to keep.
 *
 * Borrowed pointers: string/bytes values read out of the database are borrowed,
 * length-delimited, NOT NUL-terminated.
 * Copy them out to keep them.
 */
#ifndef MAXMINDDB_ZIG_H
#define MAXMINDDB_ZIG_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MMDB_VERSION_MAJOR 0
#define MMDB_VERSION_MINOR 1
#define MMDB_VERSION_PATCH 0
// MMDB_VERSION_NUMBER is a single comparable value for feature tests.
#define MMDB_VERSION_NUMBER \
    (MMDB_VERSION_MAJOR * 100 * 100 + MMDB_VERSION_MINOR * 100 + MMDB_VERSION_PATCH)

// mmdb_version_string returns the library version as a static NUL-terminated string, e.g. "0.1.0".
const char* mmdb_version_string(void);

typedef int32_t mmdb_status_t;
#define MMDB_OK                    0
#define MMDB_ERR_IO               -1
#define MMDB_ERR_INVALID_DB       -2
#define MMDB_ERR_CORRUPTED_TREE   -3
#define MMDB_ERR_INVALID_IP       -4
#define MMDB_ERR_IPV6_ON_IPV4_DB  -5
#define MMDB_ERR_INVALID_PREFIX   -6
#define MMDB_ERR_OUT_OF_MEMORY    -7
#define MMDB_ERR_WRONG_TYPE       -8
#define MMDB_ERR_INVALID_ARGUMENT -9
// Sentinel for a status value that is not one of the codes above.
#define MMDB_STATUS_UNKNOWN       -0x7FFFFFFF

// mmdb_status_name returns the code's identifier, e.g. "MMDB_OK" (static, never NULL).
const char* mmdb_status_name(mmdb_status_t s);

// mmdb_status_message returns a human-readable description, e.g. "success" (static, never NULL).
const char* mmdb_status_message(mmdb_status_t s);

// Network (CIDR).
typedef struct {
    uint8_t bytes[16];
    uint8_t version;
    uint8_t prefix_len;
    uint8_t _reserved[6];
} mmdb_network_t;
_Static_assert(sizeof(mmdb_network_t) == 24, "mmdb_network_t ABI");
_Static_assert(_Alignof(mmdb_network_t) == 1, "mmdb_network_t alignment");

#define MMDB_NETWORK_ALL_V4 ((mmdb_network_t){ .version = 4 })
#define MMDB_NETWORK_ALL_V6 ((mmdb_network_t){ .version = 6 })
#define MMDB_NETWORK_STRING_MAX 46

/* Formats a network as a CIDR string into buf.
 * Pass a buffer of at least MMDB_NETWORK_STRING_MAX bytes.
 * The out_len (nullable) receives the length excluding the NUL.
 * Returns MMDB_ERR_INVALID_ARGUMENT on a bad network or a buffer that is too small.
 */
mmdb_status_t mmdb_network_to_string(
    const mmdb_network_t* network,
    char* buf,
    size_t buf_len,
    size_t* out_len
);

// Disables the IPv4 index (pass 0 to ipv4_index_first_n_bits).
#define MMDB_IPV4_INDEX_DISABLED 0
// Recommended value for the IPv4 index: fits L2 cache on most CPUs.
#define MMDB_IPV4_INDEX_RECOMMENDED 16
// Largest valid ipv4_index_first_n_bits.
#define MMDB_IPV4_INDEX_MAX 24

typedef struct {
    /* Pre-compute the first N bits of IPv4 addresses into a flat array
     * so lookups skip the first N tree levels.
     * 0 disables the index, valid values are 1..24.
    */
    uint8_t ipv4_index_first_n_bits;
    uint8_t _reserved[7];
} mmdb_open_options_t;
_Static_assert(sizeof(mmdb_open_options_t) == 8, "mmdb_open_options_t ABI");
_Static_assert(_Alignof(mmdb_open_options_t) == 1, "mmdb_open_options_t alignment");

typedef struct mmdb_reader mmdb_reader_t;

/* mmdb_open opens a mmdb file.
 *
 * Pass NULL for opts to accept defaults (no IPv4 index).
 */
mmdb_status_t mmdb_open(
    const char* path,
    size_t path_len,
    const mmdb_open_options_t* opts,
    mmdb_reader_t** out_reader
);

/* mmdb_open_bytes opens a reader over caller-owned bytes.
 * The reader borrows the slice, so the bytes must stay valid and stable until mmdb_close.
 */
mmdb_status_t mmdb_open_bytes(
    const uint8_t* bytes,
    size_t bytes_len,
    const mmdb_open_options_t* opts,
    mmdb_reader_t** out_reader
);

void mmdb_close(mmdb_reader_t* r);

/* mmdb_metadata_t holds the fixed metadata fields.
 * For variable-shape fields (description, languages) and any non-spec keys,
 * use mmdb_metadata_decode.
 */
typedef struct {
    uint16_t binary_format_major_version;
    uint16_t binary_format_minor_version;
    uint16_t ip_version;
    uint16_t record_size;
    uint32_t node_count;
    uint32_t _reserved0;
    uint64_t build_epoch;
    const char* database_type;
    size_t database_type_len;
    uint8_t _reserved1[16];
} mmdb_metadata_t;
_Static_assert(sizeof(mmdb_metadata_t) == 56, "mmdb_metadata_t ABI");
_Static_assert(_Alignof(mmdb_metadata_t) == 8, "mmdb_metadata_t alignment");

/* mmdb_metadata returns the fixed metadata fields by value (no status).
 * Assumes a valid reader.
 */
mmdb_metadata_t mmdb_metadata(const mmdb_reader_t* r);

// mmdb_type_t is the value's type tag.
typedef uint32_t mmdb_type_t;
#define MMDB_V_NONE    0
#define MMDB_V_STRING  1
#define MMDB_V_BYTES   2
#define MMDB_V_U16     3
#define MMDB_V_U32     4
#define MMDB_V_I32     5
#define MMDB_V_U64     6
#define MMDB_V_U128    7
#define MMDB_V_F32     8
#define MMDB_V_F64     9
#define MMDB_V_BOOL    10
#define MMDB_V_ARRAY   11
#define MMDB_V_MAP     12
#define MMDB_V_UNKNOWN 0x7FFFFFFF

/* mmdb_extracted_t is a type tag and a scalar payload.
 * Read the union member named by type, e.g., as.str for type == MMDB_V_STRING.
 * For MMDB_V_MAP / MMDB_V_ARRAY / MMDB_V_NONE the union is unspecified because
 * these are leaf extractors.
 * Navigate containers via the mmdb_value_* family instead.
 */
typedef struct {
    mmdb_type_t type;
    uint32_t _reserved;
    union {
        struct {
            const char* ptr;
            size_t len;
        } str;
        struct {
            const uint8_t* ptr;
            size_t len;
        } bytes;
        uint16_t u16;
        uint32_t u32;
        int32_t i32;
        uint64_t u64;
        uint8_t u128_be[16];
        float f32;
        double f64;
        bool b;
    } as;
} mmdb_extracted_t;
_Static_assert(sizeof(mmdb_extracted_t) == 24, "mmdb_extracted_t ABI");
_Static_assert(_Alignof(mmdb_extracted_t) == 8, "mmdb_extracted_t alignment");

// mmdb_extracted_as_uint widens any unsigned integer value (u16/u32/u64), WRONG_TYPE otherwise.
static inline mmdb_status_t mmdb_extracted_as_uint(
    const mmdb_extracted_t* x,
    uint64_t* out
) {
    switch (x->type) {
        case MMDB_V_U16:
            *out = x->as.u16;
            return MMDB_OK;
        case MMDB_V_U32:
            *out = x->as.u32;
            return MMDB_OK;
        case MMDB_V_U64:
            *out = x->as.u64;
            return MMDB_OK;
        default:
            return MMDB_ERR_WRONG_TYPE;
    }
}

// mmdb_extracted_as_double widens any float value (f32/f64), WRONG_TYPE otherwise.
static inline mmdb_status_t mmdb_extracted_as_double(
    const mmdb_extracted_t* x,
    double* out
) {
    switch (x->type) {
        case MMDB_V_F32:
            *out = (double)x->as.f32;
            return MMDB_OK;
        case MMDB_V_F64:
            *out = x->as.f64;
            return MMDB_OK;
        default:
            return MMDB_ERR_WRONG_TYPE;
    }
}

/* mmdb_entry_t is a located but undecoded record from a find.
 * After a successful find, network holds the matched CIDR.
 */
typedef struct {
    mmdb_network_t network;
    uint64_t _opaque[2];
} mmdb_entry_t;
_Static_assert(sizeof(mmdb_entry_t) == 40, "mmdb_entry_t ABI");
_Static_assert(_Alignof(mmdb_entry_t) == 8, "mmdb_entry_t alignment");

/* mmdb_find_string looks up an entry by IP address string.
 * On not found, out_found is set to false and out_entry is left unspecified,
 * so check out_found before reading out_entry.
 */
mmdb_status_t mmdb_find_string(
    const mmdb_reader_t* r,
    const char* ipstr,
    size_t ipstr_len,
    mmdb_entry_t* out_entry,
    bool* out_found
);

/* mmdb_find_v4 looks up an entry by IPv4 address in network byte order, e.g.,
 * sockaddr_in.sin_addr.s_addr or inet_addr().
 */
mmdb_status_t mmdb_find_v4(
    const mmdb_reader_t* r,
    uint32_t s_addr,
    mmdb_entry_t* out_entry,
    bool* out_found
);

/* mmdb_find_v6 looks up an entry by IPv6 address as 16 big-endian bytes, e.g.,
 * sockaddr_in6.sin6_addr.
 */
mmdb_status_t mmdb_find_v6(
    const mmdb_reader_t* r,
    const uint8_t bytes[16],
    mmdb_entry_t* out_entry,
    bool* out_found
);

/* mmdb_get_many_string extracts paths_n key-paths as inline values in one call, for example:
 *
 *     const char* keys[] = { "country","iso_code",  "city","names","en" };
 *     size_t lens[] = { 2, 3 };
 *     mmdb_extracted_t vals[2];
 *     mmdb_network_t net;
 *     bool found = false;
 *     mmdb_get_many_string(r, "89.160.20.128", 13, keys, lens, 2, &net, vals, &found);
 *     if (found) { ... }
 */
mmdb_status_t mmdb_get_many_string(
    const mmdb_reader_t* r,
    const char* ipstr,
    size_t ipstr_len,
    const char* const* paths_keys,
    const size_t* paths_lens,
    size_t paths_n,
    mmdb_network_t* out_network,
    mmdb_extracted_t* out_values,
    bool* out_found
);

mmdb_status_t mmdb_get_many_v4(
    const mmdb_reader_t* r,
    uint32_t s_addr,
    const char* const* paths_keys,
    const size_t* paths_lens,
    size_t paths_n,
    mmdb_network_t* out_network,
    mmdb_extracted_t* out_values,
    bool* out_found
);

mmdb_status_t mmdb_get_many_v6(
    const mmdb_reader_t* r,
    const uint8_t bytes[16],
    const char* const* paths_keys,
    const size_t* paths_lens,
    size_t paths_n,
    mmdb_network_t* out_network,
    mmdb_extracted_t* out_values,
    bool* out_found
);

/* mmdb_entry_extract extracts one key-path from an already-found entry.
 *
 *     mmdb_entry_t e;
 *     bool found;
 *     mmdb_find_string(r, "89.160.20.128", 13, &e, &found);
 *     if (found) {
 *         const char* path[] = { "country", "iso_code" };
 *         mmdb_extracted_t x;
 *         mmdb_entry_extract(r, &e, path, 2, &x);
 *     }
 */
mmdb_status_t mmdb_entry_extract(
    const mmdb_reader_t* r,
    const mmdb_entry_t* entry,
    const char* const* path,
    size_t path_n,
    mmdb_extracted_t* out
);

typedef struct {
    // Decode only top-level map entries whose key matches one of these keys.
    const char* const* only;
    size_t only_n;
    uint8_t _reserved[16];
} mmdb_decode_options_t;
_Static_assert(sizeof(mmdb_decode_options_t) == 32, "mmdb_decode_options_t ABI");
_Static_assert(_Alignof(mmdb_decode_options_t) == 8, "mmdb_decode_options_t alignment");

// mmdb_value_t is a fully-decoded value: a scalar, array, or map.
typedef struct {
    uint64_t _opaque[4];
} mmdb_value_t;
_Static_assert(sizeof(mmdb_value_t) == 32, "mmdb_value_t ABI");
_Static_assert(_Alignof(mmdb_value_t) == 8, "mmdb_value_t alignment");

// mmdb_record_t is an opaque handle owning the arena that backs every value in one decode.
typedef struct mmdb_record mmdb_record_t;

// mmdb_entry_decode decodes the entry into a fresh record.
mmdb_status_t mmdb_entry_decode(
    const mmdb_reader_t* r,
    const mmdb_entry_t* entry,
    const mmdb_decode_options_t* opts,
    mmdb_record_t** out_record,
    mmdb_value_t* out_value
);

void mmdb_record_close(mmdb_record_t* record);

/* mmdb_metadata_decode decodes the whole metadata map.
 * For the fixed common fields, use mmdb_metadata instead.
 * Enumerate with mmdb_value_map_entry.
 * Close the returned record with mmdb_record_close.
 */
mmdb_status_t mmdb_metadata_decode(
    const mmdb_reader_t* r,
    mmdb_record_t** out_record,
    mmdb_value_t* out_value
);

// mmdb_value_type returns the value's type tag (MMDB_V_NONE for an absent value).
mmdb_type_t mmdb_value_type(const mmdb_value_t* v);

mmdb_status_t mmdb_value_as_string(const mmdb_value_t* v, const char** out, size_t* out_len);

mmdb_status_t mmdb_value_as_bytes(const mmdb_value_t* v, const char** out, size_t* out_len);

mmdb_status_t mmdb_value_as_u16(const mmdb_value_t* v, uint16_t* out);

mmdb_status_t mmdb_value_as_u32(const mmdb_value_t* v, uint32_t* out);

mmdb_status_t mmdb_value_as_i32(const mmdb_value_t* v, int32_t* out);

mmdb_status_t mmdb_value_as_u64(const mmdb_value_t* v, uint64_t* out);

// out receives the 16 bytes of the u128 in big-endian order.
mmdb_status_t mmdb_value_as_u128(const mmdb_value_t* v, uint8_t out[16]);

mmdb_status_t mmdb_value_as_f32(const mmdb_value_t* v, float* out);

mmdb_status_t mmdb_value_as_f64(const mmdb_value_t* v, double* out);

mmdb_status_t mmdb_value_as_bool(const mmdb_value_t* v, bool* out);

// mmdb_value_extract reads the type tag and scalar payload in one call, see mmdb_extracted_t.
mmdb_status_t mmdb_value_extract(const mmdb_value_t* v, mmdb_extracted_t* out);

// Returns the child or a MMDB_V_NONE value if key is absent or parent is not a map.
mmdb_value_t mmdb_value_map_get(const mmdb_value_t* parent, const char* key);

// Returns the element or a MMDB_V_NONE value if i is out of range or parent is not an array.
mmdb_value_t mmdb_value_array_at(const mmdb_value_t* parent, size_t i);

// Returns the entry count or 0 if v is not a map.
size_t mmdb_value_map_size(const mmdb_value_t* v);

// Returns the element count or 0 if v is not an array.
size_t mmdb_value_array_size(const mmdb_value_t* v);

// mmdb_str_t is a UTF-8 string (pointer, length).
// Pointer is never NULL.
typedef struct {
    const char* ptr;
    size_t len;
} mmdb_str_t;

// mmdb_map_entry_t is a key/value pair from a map.
typedef struct {
    mmdb_str_t key;
    mmdb_value_t value;
} mmdb_map_entry_t;
_Static_assert(sizeof(mmdb_map_entry_t) == 48, "mmdb_map_entry_t ABI");
_Static_assert(_Alignof(mmdb_map_entry_t) == 8, "mmdb_map_entry_t alignment");

/* mmdb_value_map_entry fetches the i-th map entry.
 * On out-of-range or non-map, the value has type MMDB_V_NONE.
 * Bound the loop with mmdb_value_map_size.
 */
mmdb_map_entry_t mmdb_value_map_entry(const mmdb_value_t* parent, size_t i);

// mmdb_value_as_uint widens any unsigned integer value (u16/u32/u64) into out,
// WRONG_TYPE otherwise.
static inline mmdb_status_t mmdb_value_as_uint(const mmdb_value_t* v, uint64_t* out) {
    mmdb_extracted_t x;
    mmdb_status_t s = mmdb_value_extract(v, &x);
    return s != MMDB_OK ? s : mmdb_extracted_as_uint(&x, out);
}

// mmdb_value_as_double widens any float value (f32/f64) into out, WRONG_TYPE otherwise.
static inline mmdb_status_t mmdb_value_as_double(const mmdb_value_t* v, double* out) {
    mmdb_extracted_t x;
    mmdb_status_t s = mmdb_value_extract(v, &x);
    return s != MMDB_OK ? s : mmdb_extracted_as_double(&x, out);
}

/* mmdb_value_get_path follows a key path from a decoded value, for example:
 *
 *     const char* keys[] = { "country", "iso_code" };
 *     mmdb_value_t v = mmdb_value_get_path(&value, keys, 2);
 */
static inline mmdb_value_t mmdb_value_get_path(
    const mmdb_value_t* value,
    const char* const* path,
    size_t path_n
) {
    mmdb_value_t cur = *value;
    for (size_t i = 0; i < path_n; i++) {
        cur = mmdb_value_map_get(&cur, path[i]);
    }

    return cur;
}

// mmdb_scan_iter_t yields fully-decoded records over a CIDR network range.
typedef struct mmdb_scan_iter mmdb_scan_iter_t;

// mmdb_scan_result_t is one scan result: a network and its decoded value.
typedef struct {
    mmdb_network_t network;
    mmdb_value_t value;
} mmdb_scan_result_t;
_Static_assert(sizeof(mmdb_scan_result_t) == 56, "mmdb_scan_result_t ABI");
_Static_assert(_Alignof(mmdb_scan_result_t) == 8, "mmdb_scan_result_t alignment");

mmdb_status_t mmdb_scan_iter_open(
    const mmdb_reader_t* r,
    const mmdb_network_t* network,
    const mmdb_decode_options_t* opts,
    mmdb_scan_iter_t** out_iter
);

void mmdb_scan_iter_close(mmdb_scan_iter_t* iter);

// When out_exhausted is set to true, out is left unspecified,
// so check the flag before reading the result.
mmdb_status_t mmdb_scan_iter_next(
    mmdb_scan_iter_t* iter,
    mmdb_scan_result_t* out,
    bool* out_exhausted
);

#ifdef __cplusplus
}
#endif

#endif
