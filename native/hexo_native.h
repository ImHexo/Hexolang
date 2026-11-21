#ifndef HEXO_NATIVE_H
#define HEXO_NATIVE_H

#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint64_t tag;
    uint64_t payload;
} HxValue;

enum {
    HX_NIL = 0, HX_BOOL = 1, HX_INT = 2, HX_FLOAT = 3,
    HX_STRING = 4, HX_ARRAY = 5, HX_FUNCTION = 6,
    HX_CLASS = 7, HX_INSTANCE = 8, HX_MODULE = 9, HX_PTR = 10
};

typedef struct {
    uint64_t length;
    uint64_t intern_id;
    char bytes[];
} HxString;

typedef struct {
    uint64_t length;
    uint64_t capacity;
    HxValue *items;
} HxArray;

/* Assembly runtime allocation/value helpers. */
extern void *hx_alloc(size_t size);
extern HxString *str_new(const char *bytes, size_t length);
extern HxArray *arr_new(uint64_t capacity);
extern void arr_push(HxArray *array, uint64_t tag, uint64_t payload);
extern void hx_raise_error(const char *message) __attribute__((noreturn));
extern HxValue hx_call_callback(uint64_t tag, uint64_t payload,
                               HxValue *args, uint64_t argc);

#define HX_VALUE(tag_, payload_) ((HxValue){ (uint64_t)(tag_), (uint64_t)(payload_) })
#define HX_NIL_VALUE HX_VALUE(HX_NIL, 0)
#define HX_BOOL_VALUE(v_) HX_VALUE(HX_BOOL, (v_) ? 1 : 0)
#define HX_INT_VALUE(v_) HX_VALUE(HX_INT, (uint64_t)(int64_t)(v_))
#define HX_FLOAT_VALUE(v_) HX_VALUE(HX_FLOAT, hx_double_bits((double)(v_)))

static inline uint64_t hx_double_bits(double d) {
    union { double d; uint64_t u; } x; x.d = d; return x.u;
}
static inline double hx_bits_double(uint64_t u) {
    union { double d; uint64_t u; } x; x.u = u; return x.d;
}

static inline HxString *hx_as_string(HxValue v) {
    return v.tag == HX_STRING ? (HxString *)(uintptr_t)v.payload : NULL;
}
static inline HxArray *hx_as_array(HxValue v) {
    return v.tag == HX_ARRAY ? (HxArray *)(uintptr_t)v.payload : NULL;
}
static inline const char *hx_string_bytes(HxValue v) {
    HxString *s = hx_as_string(v); return s ? s->bytes : NULL;
}
static inline size_t hx_string_length(HxValue v) {
    HxString *s = hx_as_string(v); return s ? (size_t)s->length : 0;
}
static inline HxValue hx_make_string_n(const char *s, size_t n) {
    HxString *v = str_new(s, n); return HX_VALUE(HX_STRING, (uintptr_t)v);
}
static inline HxValue hx_make_string(const char *s) {
    size_t n = 0; while (s[n]) ++n; return hx_make_string_n(s, n);
}
static inline HxValue hx_make_array(void) {
    return HX_VALUE(HX_ARRAY, (uintptr_t)arr_new(0));
}
static inline void hx_array_push(HxValue a, HxValue v) {
    HxArray *p = hx_as_array(a);
    if (!p) hx_raise_error("native module internal error: expected array");
    arr_push(p, v.tag, v.payload);
}
static inline HxValue hx_array_get(HxValue a, size_t i) {
    HxArray *p = hx_as_array(a);
    if (!p || i >= p->length) return HX_NIL_VALUE;
    return p->items[i];
}
static inline int hx_value_truthy(HxValue v) {
    switch (v.tag) {
        case HX_NIL: return 0;
        case HX_BOOL: return v.payload != 0;
        case HX_INT: return (int64_t)v.payload != 0;
        case HX_FLOAT: return hx_bits_double(v.payload) != 0.0;
        case HX_STRING: return hx_string_length(v) != 0;
        default: return 1;
    }
}
static inline int64_t hx_to_int(HxValue v, const char *what) {
    if (v.tag != HX_INT) hx_raise_error(what);
    return (int64_t)v.payload;
}
static inline double hx_to_number(HxValue v, const char *what) {
    if (v.tag == HX_INT) return (double)(int64_t)v.payload;
    if (v.tag == HX_FLOAT) return hx_bits_double(v.payload);
    hx_raise_error(what);
}
static inline const char *hx_to_cstr(HxValue v, const char *what) {
    const char *s = hx_string_bytes(v);
    if (!s) hx_raise_error(what);
    return s;
}

/* All exported native entry points follow the Hexo native ABI:
   HxValue f(HxValue *args, int argc, void *function_object). */
#define HX_NATIVE(name) HxValue name(HxValue *args, int argc, void *fn)

#endif
