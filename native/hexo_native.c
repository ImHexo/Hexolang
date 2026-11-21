#define _POSIX_C_SOURCE 200809L
#include "hexo_native.h"

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <sys/stat.h>
#if !defined(_WIN32)
#include <dirent.h>
#include <unistd.h>
#else
#include <direct.h>
#include <process.h>
#include <windows.h>
#endif

#ifndef HX_MAX_TEXT
#define HX_MAX_TEXT (64u * 1024u * 1024u)
#endif
#define HX_JSON_OBJECT_MARKER "\001HXO_JSON_OBJECT"
#define HX_TABLE_MARKER "\001HXO_TABULAR_TABLE"

typedef struct { char *data; size_t length, capacity; } HxBuffer;

static void buffer_reserve(HxBuffer *b, size_t extra) {
    if (extra > HX_MAX_TEXT || b->length > HX_MAX_TEXT - extra)
        hx_raise_error("native text result exceeds the 64 MiB limit");
    size_t need = b->length + extra + 1;
    if (need <= b->capacity) return;
    size_t cap = b->capacity ? b->capacity : 256;
    while (cap < need) {
        if (cap > HX_MAX_TEXT / 2) { cap = HX_MAX_TEXT + 1; break; }
        cap *= 2;
    }
    char *p = (char *)realloc(b->data, cap);
    if (!p) hx_raise_error("out of memory in native module");
    b->data = p; b->capacity = cap;
}
static void buffer_bytes(HxBuffer *b, const char *s, size_t n) {
    buffer_reserve(b, n);
    if (n) memcpy(b->data + b->length, s, n);
    b->length += n; b->data[b->length] = '\0';
}
static void buffer_cstr(HxBuffer *b, const char *s) { buffer_bytes(b, s, strlen(s)); }
static HxValue buffer_value(HxBuffer *b) {
    HxValue v = hx_make_string_n(b->data ? b->data : "", b->length);
    free(b->data); b->data = NULL; b->length = b->capacity = 0;
    return v;
}
static HxValue json_object_new(void) {
    HxValue obj = hx_make_array();
    hx_array_push(obj, hx_make_string(HX_JSON_OBJECT_MARKER));
    return obj;
}
static int json_is_object(HxValue v) {
    HxArray *a = hx_as_array(v);
    if (!a || a->length == 0 || a->items[0].tag != HX_STRING) return 0;
    HxString *s = (HxString *)(uintptr_t)a->items[0].payload;
    return s->length == sizeof(HX_JSON_OBJECT_MARKER) - 1 &&
           memcmp(s->bytes, HX_JSON_OBJECT_MARKER, s->length) == 0;
}
static HxValue table_new(HxValue columns, HxValue rows) {
    HxValue table = hx_make_array();
    hx_array_push(table, hx_make_string(HX_TABLE_MARKER));
    hx_array_push(table, columns);
    hx_array_push(table, rows);
    return table;
}
static int table_valid(HxValue v) {
    HxArray *a = hx_as_array(v);
    if (!a || a->length != 3 || a->items[0].tag != HX_STRING) return 0;
    HxString *s = (HxString *)(uintptr_t)a->items[0].payload;
    return s->length == sizeof(HX_TABLE_MARKER) - 1 &&
           memcmp(s->bytes, HX_TABLE_MARKER, s->length) == 0;
}
static HxValue table_columns(HxValue table) { return hx_array_get(table, 1); }
static HxValue table_rows(HxValue table) { return hx_array_get(table, 2); }
static int value_string_equal(HxValue a, const char *s) {
    if (a.tag != HX_STRING) return 0;
    HxString *v = (HxString *)(uintptr_t)a.payload;
    size_t n = strlen(s);
    return v->length == n && memcmp(v->bytes, s, n) == 0;
}
static int value_string_compare(HxValue a, HxValue b) {
    if (a.tag != HX_STRING || b.tag != HX_STRING) return 0;
    HxString *x = (HxString *)(uintptr_t)a.payload;
    HxString *y = (HxString *)(uintptr_t)b.payload;
    size_t n = x->length < y->length ? x->length : y->length;
    int c = memcmp(x->bytes, y->bytes, n);
    if (c) return c;
    return (x->length > y->length) - (x->length < y->length);
}
static HxValue json_object_get(HxValue object, HxValue key, int *found) {
    HxArray *a = hx_as_array(object);
    if (!json_is_object(object) || !a) hx_raise_error("json operation expects a JSON object");
    HxValue result = HX_NIL_VALUE;
    *found = 0;
    for (size_t i = 1; i < a->length; ++i) {
        HxArray *pair = hx_as_array(a->items[i]);
        if (pair && pair->length >= 2 && value_string_compare(pair->items[0], key) == 0) {
            result = pair->items[1]; *found = 1;
        }
    }
    return result;
}
static void json_object_set(HxValue object, HxValue key, HxValue value) {
    HxArray *a = hx_as_array(object);
    if (!json_is_object(object) || !a) hx_raise_error("json.set expects a JSON object");
    for (size_t i = 1; i < a->length; ++i) {
        HxArray *pair = hx_as_array(a->items[i]);
        if (pair && pair->length >= 2 && value_string_compare(pair->items[0], key) == 0) {
            pair->items[1] = value; return;
        }
    }
    HxValue pair = hx_make_array();
    hx_array_push(pair, key); hx_array_push(pair, value); hx_array_push(object, pair);
}

/* ---------------------------------------------------- extended system / OS */
HX_NATIVE(nat_os_file_size) {
    (void)fn;
    if (argc != 1) hx_raise_error("os.fileSize expects one path");
    const char *path = hx_to_cstr(args[0], "os.fileSize path must be a string");
    struct stat st;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) return HX_INT_VALUE(-1);
    return HX_INT_VALUE((int64_t)st.st_size);
}
HX_NATIVE(nat_os_is_directory) {
    (void)fn;
    if (argc != 1) hx_raise_error("os.isDirectory expects one path");
    const char *path = hx_to_cstr(args[0], "os.isDirectory path must be a string");
    struct stat st;
    return HX_BOOL_VALUE(stat(path, &st) == 0 && S_ISDIR(st.st_mode));
}
HX_NATIVE(nat_os_create_directory) {
    (void)fn;
    if (argc != 1) hx_raise_error("os.createDirectory expects one path");
    const char *path = hx_to_cstr(args[0], "os.createDirectory path must be a string");
#if defined(_WIN32)
    int rc = _mkdir(path);
#else
    int rc = mkdir(path, 0755);
#endif
    if (rc == 0) return HX_BOOL_VALUE(1);
    struct stat st;
    return HX_BOOL_VALUE(errno == EEXIST && stat(path, &st) == 0 && S_ISDIR(st.st_mode));
}
HX_NATIVE(nat_os_remove_directory) {
    (void)fn;
    if (argc != 1) hx_raise_error("os.removeDirectory expects one path");
    const char *path = hx_to_cstr(args[0], "os.removeDirectory path must be a string");
#if defined(_WIN32)
    return HX_BOOL_VALUE(_rmdir(path) == 0);
#else
    return HX_BOOL_VALUE(rmdir(path) == 0);
#endif
}
HX_NATIVE(nat_os_list_directory) {
    (void)fn;
    if (argc != 1) hx_raise_error("os.listDirectory expects one path");
    const char *path = hx_to_cstr(args[0], "os.listDirectory path must be a string");
#if defined(_WIN32)
    (void)path;
    hx_raise_error("os.listDirectory is not available in this Windows build");
#else
    DIR *dir = opendir(path);
    if (!dir) { char msg[512]; snprintf(msg, sizeof(msg), "os.listDirectory: %s", strerror(errno)); hx_raise_error(msg); }
    HxValue entries = hx_make_array();
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        hx_array_push(entries, hx_make_string(entry->d_name));
    }
    closedir(dir);
    return entries;
#endif
}
HX_NATIVE(nat_os_env_set) {
    (void)fn;
    if (argc != 2) hx_raise_error("os.envSet expects name and value");
    const char *name = hx_to_cstr(args[0], "os.envSet name must be a string");
    const char *value = hx_to_cstr(args[1], "os.envSet value must be a string");
    if (!*name || strchr(name, '=')) hx_raise_error("os.envSet variable name is invalid");
#if defined(_WIN32)
    return HX_BOOL_VALUE(_putenv_s(name, value) == 0);
#else
    return HX_BOOL_VALUE(setenv(name, value, 1) == 0);
#endif
}
HX_NATIVE(nat_os_env_unset) {
    (void)fn;
    if (argc != 1) hx_raise_error("os.envUnset expects one name");
    const char *name = hx_to_cstr(args[0], "os.envUnset name must be a string");
    if (!*name || strchr(name, '=')) hx_raise_error("os.envUnset variable name is invalid");
#if defined(_WIN32)
    return HX_BOOL_VALUE(_putenv_s(name, "") == 0);
#else
    return HX_BOOL_VALUE(unsetenv(name) == 0);
#endif
}
HX_NATIVE(nat_os_sleep_ms) {
    (void)fn;
    if (argc != 1) hx_raise_error("os.sleepMs expects milliseconds");
    int64_t ms = hx_to_int(args[0], "os.sleepMs expects an integer");
    if (ms < 0 || ms > 86400000) hx_raise_error("os.sleepMs must be between 0 and 86400000");
#if defined(_WIN32)
    Sleep((DWORD)ms);
#else
    struct timespec request = { (time_t)(ms / 1000), (long)((ms % 1000) * 1000000) };
    while (nanosleep(&request, &request) != 0 && errno == EINTR) {}
#endif
    return HX_NIL_VALUE;
}
HX_NATIVE(nat_os_process_id) {
    (void)args; (void)fn;
    if (argc) hx_raise_error("os.processId expects no arguments");
#if defined(_WIN32)
    return HX_INT_VALUE(_getpid());
#else
    return HX_INT_VALUE(getpid());
#endif
}

/* ------------------------------- JSON RFC 8259 parser and serializer ----- */
typedef struct { const char *s; size_t n, p; unsigned depth; } JsonParser;
static void json_ws(JsonParser *p) {
    while (p->p < p->n && (p->s[p->p] == ' ' || p->s[p->p] == '\t' ||
           p->s[p->p] == '\r' || p->s[p->p] == '\n')) ++p->p;
}
static void json_error(JsonParser *p, const char *why) {
    char msg[256]; snprintf(msg, sizeof(msg), "json.parse: %s at byte %zu", why, p->p);
    hx_raise_error(msg);
}
static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}
static uint32_t json_u16(JsonParser *p) {
    if (p->n - p->p < 4) json_error(p, "incomplete Unicode escape");
    uint32_t v = 0;
    for (int i = 0; i < 4; ++i) {
        int h = hex_digit(p->s[p->p++]);
        if (h < 0) json_error(p, "invalid Unicode escape");
        v = (v << 4) | (uint32_t)h;
    }
    return v;
}
static void utf8_append(HxBuffer *b, uint32_t cp) {
    char out[4]; size_t n;
    if (cp <= 0x7f) { out[0] = (char)cp; n = 1; }
    else if (cp <= 0x7ff) { out[0] = (char)(0xc0 | (cp >> 6)); out[1] = (char)(0x80 | (cp & 0x3f)); n = 2; }
    else if (cp <= 0xffff) { out[0] = (char)(0xe0 | (cp >> 12)); out[1] = (char)(0x80 | ((cp >> 6) & 0x3f)); out[2] = (char)(0x80 | (cp & 0x3f)); n = 3; }
    else { out[0] = (char)(0xf0 | (cp >> 18)); out[1] = (char)(0x80 | ((cp >> 12) & 0x3f)); out[2] = (char)(0x80 | ((cp >> 6) & 0x3f)); out[3] = (char)(0x80 | (cp & 0x3f)); n = 4; }
    buffer_bytes(b, out, n);
}
static HxValue json_parse_string(JsonParser *p) {
    if (p->p >= p->n || p->s[p->p++] != '"') json_error(p, "expected string");
    HxBuffer b = {0};
    while (p->p < p->n) {
        unsigned char c = (unsigned char)p->s[p->p++];
        if (c == '"') return buffer_value(&b);
        if (c < 0x20) json_error(p, "unescaped control character in string");
        if (c != '\\') { buffer_bytes(&b, (const char *)&c, 1); continue; }
        if (p->p >= p->n) json_error(p, "incomplete escape sequence");
        char e = p->s[p->p++];
        switch (e) {
            case '"': buffer_cstr(&b, "\""); break;
            case '\\': buffer_cstr(&b, "\\"); break;
            case '/': buffer_cstr(&b, "/"); break;
            case 'b': buffer_bytes(&b, "\b", 1); break;
            case 'f': buffer_bytes(&b, "\f", 1); break;
            case 'n': buffer_bytes(&b, "\n", 1); break;
            case 'r': buffer_bytes(&b, "\r", 1); break;
            case 't': buffer_bytes(&b, "\t", 1); break;
            case 'u': {
                uint32_t cp = json_u16(p);
                if (cp >= 0xd800 && cp <= 0xdbff) {
                    if (p->n - p->p < 6 || p->s[p->p] != '\\' || p->s[p->p + 1] != 'u')
                        json_error(p, "high surrogate without low surrogate");
                    p->p += 2;
                    uint32_t lo = json_u16(p);
                    if (lo < 0xdc00 || lo > 0xdfff) json_error(p, "invalid low surrogate");
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                } else if (cp >= 0xdc00 && cp <= 0xdfff) json_error(p, "unexpected low surrogate");
                utf8_append(&b, cp); break;
            }
            default: json_error(p, "unknown escape sequence");
        }
    }
    json_error(p, "unterminated string");
    return HX_NIL_VALUE;
}
static HxValue json_parse_value(JsonParser *p);
static HxValue json_parse_array(JsonParser *p) {
    ++p->p; ++p->depth;
    if (p->depth > 128) json_error(p, "maximum nesting depth (128) exceeded");
    HxValue a = hx_make_array(); json_ws(p);
    if (p->p < p->n && p->s[p->p] == ']') { ++p->p; --p->depth; return a; }
    for (;;) {
        json_ws(p); hx_array_push(a, json_parse_value(p)); json_ws(p);
        if (p->p >= p->n) json_error(p, "unterminated array");
        char c = p->s[p->p++];
        if (c == ']') break;
        if (c != ',') json_error(p, "expected ',' or ']' in array");
    }
    --p->depth; return a;
}
static HxValue json_parse_object(JsonParser *p) {
    ++p->p; ++p->depth;
    if (p->depth > 128) json_error(p, "maximum nesting depth (128) exceeded");
    HxValue o = json_object_new(); json_ws(p);
    if (p->p < p->n && p->s[p->p] == '}') { ++p->p; --p->depth; return o; }
    for (;;) {
        json_ws(p);
        if (p->p >= p->n || p->s[p->p] != '"') json_error(p, "object keys must be strings");
        HxValue key = json_parse_string(p); json_ws(p);
        if (p->p >= p->n || p->s[p->p++] != ':') json_error(p, "expected ':' after object key");
        json_ws(p); HxValue value = json_parse_value(p); json_object_set(o, key, value); json_ws(p);
        if (p->p >= p->n) json_error(p, "unterminated object");
        char c = p->s[p->p++];
        if (c == '}') break;
        if (c != ',') json_error(p, "expected ',' or '}' in object");
    }
    --p->depth; return o;
}
static HxValue json_parse_number(JsonParser *p) {
    size_t start = p->p;
    if (p->s[p->p] == '-') ++p->p;
    if (p->p >= p->n) json_error(p, "incomplete number");
    if (p->s[p->p] == '0') ++p->p;
    else {
        if (!isdigit((unsigned char)p->s[p->p])) json_error(p, "invalid number");
        while (p->p < p->n && isdigit((unsigned char)p->s[p->p])) ++p->p;
    }
    int is_float = 0;
    if (p->p < p->n && p->s[p->p] == '.') {
        is_float = 1; ++p->p;
        if (p->p >= p->n || !isdigit((unsigned char)p->s[p->p])) json_error(p, "fraction requires digits");
        while (p->p < p->n && isdigit((unsigned char)p->s[p->p])) ++p->p;
    }
    if (p->p < p->n && (p->s[p->p] == 'e' || p->s[p->p] == 'E')) {
        is_float = 1; ++p->p;
        if (p->p < p->n && (p->s[p->p] == '+' || p->s[p->p] == '-')) ++p->p;
        if (p->p >= p->n || !isdigit((unsigned char)p->s[p->p])) json_error(p, "exponent requires digits");
        while (p->p < p->n && isdigit((unsigned char)p->s[p->p])) ++p->p;
    }
    size_t n = p->p - start;
    char tmp[128]; char *buf = tmp;
    if (n >= sizeof(tmp)) { buf = (char *)malloc(n + 1); if (!buf) hx_raise_error("out of memory parsing JSON number"); }
    memcpy(buf, p->s + start, n); buf[n] = 0;
    char *end = NULL; errno = 0;
    if (!is_float) {
        long long val = strtoll(buf, &end, 10);
        if (errno != ERANGE && end == buf + n) {
            if (buf != tmp) free(buf);
            return HX_INT_VALUE(val);
        }
    }
    double d = strtod(buf, &end);
    int parse_ok = (errno != ERANGE && end == buf + n);
    if (buf != tmp) free(buf);
    if (!parse_ok || !isfinite(d)) json_error(p, "number is outside finite range");
    return HX_FLOAT_VALUE(d);
}
static HxValue json_parse_value(JsonParser *p) {
    json_ws(p);
    if (p->p >= p->n) json_error(p, "expected a value");
    char c = p->s[p->p];
    if (c == '"') return json_parse_string(p);
    if (c == '[') return json_parse_array(p);
    if (c == '{') return json_parse_object(p);
    if (c == '-' || isdigit((unsigned char)c)) return json_parse_number(p);
    if (p->n - p->p >= 4 && memcmp(p->s + p->p, "true", 4) == 0) { p->p += 4; return HX_BOOL_VALUE(1); }
    if (p->n - p->p >= 5 && memcmp(p->s + p->p, "false", 5) == 0) { p->p += 5; return HX_BOOL_VALUE(0); }
    if (p->n - p->p >= 4 && memcmp(p->s + p->p, "null", 4) == 0) { p->p += 4; return HX_NIL_VALUE; }
    json_error(p, "unexpected token"); return HX_NIL_VALUE;
}
static void json_write_string(HxBuffer *b, const char *s, size_t n) {
    buffer_cstr(b, "\"");
    for (size_t i = 0; i < n; ++i) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
            case '"': buffer_cstr(b, "\\\""); break;
            case '\\': buffer_cstr(b, "\\\\"); break;
            case '\b': buffer_cstr(b, "\\b"); break;
            case '\f': buffer_cstr(b, "\\f"); break;
            case '\n': buffer_cstr(b, "\\n"); break;
            case '\r': buffer_cstr(b, "\\r"); break;
            case '\t': buffer_cstr(b, "\\t"); break;
            default:
                if (c < 0x20) { char tmp[7]; snprintf(tmp, sizeof(tmp), "\\u%04x", c); buffer_cstr(b, tmp); }
                else buffer_bytes(b, (const char *)&s[i], 1);
        }
    }
    buffer_cstr(b, "\"");
}
static void json_write_value(HxBuffer *b, HxValue v, unsigned depth);
static void json_write_value(HxBuffer *b, HxValue v, unsigned depth) {
    if (depth > 128) hx_raise_error("json.stringify: maximum nesting depth exceeded");
    char tmp[96];
    switch (v.tag) {
        case HX_NIL: buffer_cstr(b, "null"); return;
        case HX_BOOL: buffer_cstr(b, v.payload ? "true" : "false"); return;
        case HX_INT: snprintf(tmp, sizeof(tmp), "%" PRId64, (int64_t)v.payload); buffer_cstr(b, tmp); return;
        case HX_FLOAT: {
            double d = hx_bits_double(v.payload);
            if (!isfinite(d)) hx_raise_error("json.stringify: NaN and Infinity are not valid JSON numbers");
            snprintf(tmp, sizeof(tmp), "%.17g", d); buffer_cstr(b, tmp); return;
        }
        case HX_STRING: {
            HxString *s = (HxString *)(uintptr_t)v.payload;
            json_write_string(b, s->bytes, (size_t)s->length); return;
        }
        case HX_ARRAY: {
            HxArray *a = (HxArray *)(uintptr_t)v.payload;
            if (json_is_object(v)) {
                buffer_cstr(b, "{");
                for (size_t i = 1; i < a->length; ++i) {
                    HxArray *pair = hx_as_array(a->items[i]);
                    if (!pair || pair->length < 2 || pair->items[0].tag != HX_STRING)
                        hx_raise_error("json.stringify: malformed internal JSON object");
                    if (i > 1) buffer_cstr(b, ",");
                    HxString *key = (HxString *)(uintptr_t)pair->items[0].payload;
                    json_write_string(b, key->bytes, (size_t)key->length);
                    buffer_cstr(b, ":"); json_write_value(b, pair->items[1], depth + 1);
                }
                buffer_cstr(b, "}");
            } else {
                buffer_cstr(b, "[");
                for (size_t i = 0; i < a->length; ++i) {
                    if (i) buffer_cstr(b, ",");
                    json_write_value(b, a->items[i], depth + 1);
                }
                buffer_cstr(b, "]");
            }
            return;
        }
        default: hx_raise_error("json.stringify: unsupported Hexo value type");
    }
}

HX_NATIVE(nat_json_parse) {
    (void)fn;
    if (argc != 1) hx_raise_error("json.parse expects one string argument");
    HxString *s = hx_as_string(args[0]);
    if (!s) hx_raise_error("json.parse expects a string");
    if (s->length > HX_MAX_TEXT) hx_raise_error("json.parse input exceeds 64 MiB");
    JsonParser p = { s->bytes, (size_t)s->length, 0, 0 };
    HxValue value = json_parse_value(&p); json_ws(&p);
    if (p.p != p.n) json_error(&p, "trailing characters after JSON value");
    return value;
}
HX_NATIVE(nat_json_stringify) {
    (void)fn;
    if (argc != 1) hx_raise_error("json.stringify expects one value");
    HxBuffer b = {0}; json_write_value(&b, args[0], 0); return buffer_value(&b);
}
HX_NATIVE(nat_json_object) { (void)args; (void)fn; if (argc) hx_raise_error("json.object expects no arguments"); return json_object_new(); }
HX_NATIVE(nat_json_array) { (void)args; (void)fn; if (argc) hx_raise_error("json.array expects no arguments"); return hx_make_array(); }
HX_NATIVE(nat_json_get) {
    (void)fn; if (argc < 2 || argc > 3) hx_raise_error("json.get expects object, key and optional default");
    if (args[1].tag != HX_STRING) hx_raise_error("json.get key must be a string");
    int found = 0; HxValue value = json_object_get(args[0], args[1], &found);
    return found ? value : (argc == 3 ? args[2] : HX_NIL_VALUE);
}
HX_NATIVE(nat_json_set) {
    (void)fn; if (argc != 3) hx_raise_error("json.set expects object, key, value");
    if (args[1].tag != HX_STRING) hx_raise_error("json.set key must be a string");
    json_object_set(args[0], args[1], args[2]); return args[2];
}
HX_NATIVE(nat_json_has) {
    (void)fn; if (argc != 2) hx_raise_error("json.has expects object and key");
    if (args[1].tag != HX_STRING) hx_raise_error("json.has key must be a string");
    int found = 0; (void)json_object_get(args[0], args[1], &found); return HX_BOOL_VALUE(found);
}
HX_NATIVE(nat_json_keys) {
    (void)fn; if (argc != 1) hx_raise_error("json.keys expects one object");
    HxArray *a = hx_as_array(args[0]); if (!json_is_object(args[0]) || !a) hx_raise_error("json.keys expects a JSON object");
    HxValue keys = hx_make_array();
    for (size_t i = 1; i < a->length; ++i) { HxArray *pair = hx_as_array(a->items[i]); if (pair && pair->length) hx_array_push(keys, pair->items[0]); }
    return keys;
}
HX_NATIVE(nat_json_is_object) { (void)fn; if (argc != 1) hx_raise_error("json.isObject expects one value"); return HX_BOOL_VALUE(json_is_object(args[0])); }
HX_NATIVE(nat_json_remove) {
    (void)fn; if (argc != 2) hx_raise_error("json.remove expects object and key");
    HxArray *a = hx_as_array(args[0]); if (!json_is_object(args[0]) || !a) hx_raise_error("json.remove expects a JSON object");
    if (args[1].tag != HX_STRING) hx_raise_error("json.remove key must be a string");
    for (size_t i = 1; i < a->length; ++i) { HxArray *pair = hx_as_array(a->items[i]); if (pair && pair->length && value_string_compare(pair->items[0], args[1]) == 0) { memmove(&a->items[i], &a->items[i+1], (a->length - i - 1) * sizeof(HxValue)); --a->length; return HX_BOOL_VALUE(1); } }
    return HX_BOOL_VALUE(0);
}

/* ------------------------------------ RFC 4180 CSV and Tabular data ----- */
static HxValue csv_parse_text(const char *s, size_t n) {
    HxValue rows = hx_make_array(), row = hx_make_array();
    HxBuffer field = {0}; int quoted = 0, after_quote = 0, field_started = 0;
    size_t i = 0; int row_has_any = 0;
    while (i < n) {
        char c = s[i++];
        if (quoted) {
            if (c == '"') {
                if (i < n && s[i] == '"') { buffer_cstr(&field, "\""); ++i; }
                else { quoted = 0; after_quote = 1; }
            } else buffer_bytes(&field, &c, 1);
            row_has_any = 1; continue;
        }
        if (after_quote && c != ',' && c != '\r' && c != '\n') {
            free(field.data); hx_raise_error("tabular CSV parse error: unexpected character after closing quote");
        }
        if (c == '"') {
            if (field_started || field.length) { free(field.data); hx_raise_error("tabular CSV parse error: quote inside unquoted field"); }
            quoted = 1; field_started = 1; row_has_any = 1; continue;
        }
        if (c == ',') {
            hx_array_push(row, buffer_value(&field)); field_started = after_quote = 0; row_has_any = 1; continue;
        }
        if (c == '\r' || c == '\n') {
            if (c == '\r' && i < n && s[i] == '\n') ++i;
            hx_array_push(row, buffer_value(&field)); hx_array_push(rows, row);
            row = hx_make_array(); field_started = after_quote = 0; row_has_any = 0; continue;
        }
        buffer_bytes(&field, &c, 1); field_started = 1; row_has_any = 1;
    }
    if (quoted) { free(field.data); hx_raise_error("tabular CSV parse error: unterminated quoted field"); }
    if (row_has_any || hx_as_array(row)->length || field.length || field_started || after_quote) {
        hx_array_push(row, buffer_value(&field)); hx_array_push(rows, row);
    } else free(field.data);
    return rows;
}
static HxValue table_from_rows(HxValue rows, int has_header) {
    HxArray *r = hx_as_array(rows);
    if (!r) hx_raise_error("tabular.fromRows expects an array of rows");
    HxValue columns = hx_make_array();
    size_t width = 0;
    if (r->length) { HxArray *first = hx_as_array(r->items[0]); if (!first) hx_raise_error("tabular rows must be arrays"); width = (size_t)first->length; }
    if (has_header && r->length) {
        HxArray *first = hx_as_array(r->items[0]);
        for (size_t i = 0; i < width; ++i) {
            HxValue v = first->items[i];
            if (v.tag != HX_STRING) hx_raise_error("tabular header values must be strings");
            hx_array_push(columns, v);
        }
    } else {
        char tmp[32]; for (size_t i = 0; i < width; ++i) { snprintf(tmp, sizeof(tmp), "column%zu", i + 1); hx_array_push(columns, hx_make_string(tmp)); }
    }
    HxValue data = hx_make_array();
    for (size_t i = has_header && r->length ? 1 : 0; i < r->length; ++i) {
        HxArray *row = hx_as_array(r->items[i]); if (!row) hx_raise_error("tabular rows must be arrays");
        HxValue copy = hx_make_array();
        for (size_t j = 0; j < width; ++j) hx_array_push(copy, j < row->length ? row->items[j] : HX_NIL_VALUE);
        hx_array_push(data, copy);
    }
    return table_new(columns, data);
}
static void csv_write_field(HxBuffer *b, HxValue v) {
    char num[96]; const char *s = ""; size_t n = 0; int quote = 0;
    if (v.tag == HX_NIL) { s = ""; n = 0; }
    else if (v.tag == HX_STRING) { HxString *x = (HxString *)(uintptr_t)v.payload; s = x->bytes; n = (size_t)x->length; }
    else if (v.tag == HX_BOOL) { s = v.payload ? "true" : "false"; n = strlen(s); }
    else if (v.tag == HX_INT) { snprintf(num, sizeof(num), "%" PRId64, (int64_t)v.payload); s = num; n = strlen(s); }
    else if (v.tag == HX_FLOAT) { snprintf(num, sizeof(num), "%.17g", hx_bits_double(v.payload)); s = num; n = strlen(s); }
    else hx_raise_error("tabular CSV writer encountered a non-scalar cell");
    for (size_t i = 0; i < n; ++i) if (s[i] == ',' || s[i] == '"' || s[i] == '\r' || s[i] == '\n') quote = 1;
    if (!quote) { buffer_bytes(b, s, n); return; }
    buffer_cstr(b, "\"");
    for (size_t i = 0; i < n; ++i) { if (s[i] == '"') buffer_cstr(b, "\"\""); else buffer_bytes(b, &s[i], 1); }
    buffer_cstr(b, "\"");
}
static HxValue csv_stringify_rows(HxValue rows) {
    HxArray *r = hx_as_array(rows); if (!r) hx_raise_error("tabular.toCSV expects an array of rows");
    HxBuffer b = {0};
    for (size_t i = 0; i < r->length; ++i) {
        HxArray *row = hx_as_array(r->items[i]); if (!row) hx_raise_error("tabular rows must be arrays");
        for (size_t j = 0; j < row->length; ++j) { if (j) buffer_cstr(&b, ","); csv_write_field(&b, row->items[j]); }
        buffer_cstr(&b, "\r\n");
    }
    return buffer_value(&b);
}
static HxValue read_file_string(HxValue pathv) {
    const char *path = hx_to_cstr(pathv, "file path must be a string");
    FILE *f = fopen(path, "rb"); if (!f) { char m[512]; snprintf(m, sizeof(m), "cannot open '%s': %s", path, strerror(errno)); hx_raise_error(m); }
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); hx_raise_error("file seek failed"); }
    long size = ftell(f); if (size < 0 || (unsigned long)size > HX_MAX_TEXT) { fclose(f); hx_raise_error("file is too large (maximum 64 MiB)"); }
    rewind(f); char *buf = (char *)malloc((size_t)size + 1); if (!buf) { fclose(f); hx_raise_error("out of memory reading file"); }
    size_t n = fread(buf, 1, (size_t)size, f); int err = ferror(f); fclose(f);
    if (err) { free(buf); hx_raise_error("file read failed"); }
    buf[n] = 0; HxValue out = hx_make_string_n(buf, n); free(buf); return out;
}
static size_t table_col_index(HxValue table, HxValue name) {
    if (!table_valid(table)) hx_raise_error("expected a tabular.Table value");
    HxArray *cols = hx_as_array(table_columns(table));
    for (size_t i = 0; i < cols->length; ++i) if (value_string_compare(cols->items[i], name) == 0) return i;
    hx_raise_error("tabular column not found"); return 0;
}
HX_NATIVE(nat_csv_parse) { (void)fn; if (argc != 1 || args[0].tag != HX_STRING) hx_raise_error("tabular.parseCSV expects one string"); HxString *s = (HxString *)(uintptr_t)args[0].payload; return csv_parse_text(s->bytes, (size_t)s->length); }
HX_NATIVE(nat_csv_stringify) { (void)fn; if (argc != 1) hx_raise_error("tabular.stringifyCSV expects rows"); return csv_stringify_rows(args[0]); }
HX_NATIVE(nat_tabular_from_rows) { (void)fn; if (argc < 1 || argc > 2) hx_raise_error("tabular.fromRows expects rows and optional hasHeader"); int h = argc == 1 || hx_value_truthy(args[1]); return table_from_rows(args[0], h); }
HX_NATIVE(nat_tabular_read_csv) {
    (void)fn; if (argc < 1 || argc > 2) hx_raise_error("tabular.readCSV expects path and optional hasHeader");
    HxValue content = read_file_string(args[0]); HxString *s = (HxString *)(uintptr_t)content.payload;
    HxValue rows = csv_parse_text(s->bytes, (size_t)s->length); int h = argc == 1 || hx_value_truthy(args[1]); return table_from_rows(rows, h);
}
HX_NATIVE(nat_tabular_to_csv) {
    (void)fn; if (argc != 1) hx_raise_error("tabular.toCSV expects a table");
    if (!table_valid(args[0])) hx_raise_error("tabular.toCSV expects a table");
    HxValue rows = hx_make_array(); hx_array_push(rows, table_columns(args[0])); HxArray *data = hx_as_array(table_rows(args[0]));
    for (size_t i = 0; i < data->length; ++i) {
        hx_array_push(rows, data->items[i]);
    }
    return csv_stringify_rows(rows);
}
HX_NATIVE(nat_tabular_write_csv) {
    (void)fn; if (argc != 2) hx_raise_error("tabular.writeCSV expects path and table");
    const char *path = hx_to_cstr(args[0], "tabular.writeCSV path must be a string");
    if (!table_valid(args[1])) hx_raise_error("tabular.writeCSV expects a table");
    HxValue rows = hx_make_array(); hx_array_push(rows, table_columns(args[1])); HxArray *data = hx_as_array(table_rows(args[1]));
    for (size_t i = 0; i < data->length; ++i) {
        hx_array_push(rows, data->items[i]);
    }
    HxValue csv = csv_stringify_rows(rows);
    HxString *s = (HxString *)(uintptr_t)csv.payload; FILE *f = fopen(path, "wb"); if (!f) { char m[512]; snprintf(m, sizeof(m), "cannot write '%s': %s", path, strerror(errno)); hx_raise_error(m); }
    size_t n = fwrite(s->bytes, 1, (size_t)s->length, f); int err = ferror(f); fclose(f); if (err || n != s->length) hx_raise_error("CSV file write failed"); return HX_INT_VALUE(n);
}
HX_NATIVE(nat_tabular_columns) { (void)fn; if (argc != 1 || !table_valid(args[0])) hx_raise_error("tabular.columns expects a table"); return table_columns(args[0]); }
HX_NATIVE(nat_tabular_rows) { (void)fn; if (argc != 1 || !table_valid(args[0])) hx_raise_error("tabular.rows expects a table"); return table_rows(args[0]); }
HX_NATIVE(nat_tabular_shape) {
    (void)fn; if (argc != 1 || !table_valid(args[0])) hx_raise_error("tabular.shape expects a table");
    HxValue out = hx_make_array(); HxArray *rows = hx_as_array(table_rows(args[0])); HxArray *cols = hx_as_array(table_columns(args[0]));
    hx_array_push(out, HX_INT_VALUE(rows->length)); hx_array_push(out, HX_INT_VALUE(cols->length)); return out;
}
HX_NATIVE(nat_tabular_head) {
    (void)fn; if (argc < 1 || argc > 2 || !table_valid(args[0])) hx_raise_error("tabular.head expects table and optional count");
    int64_t n = argc == 2 ? hx_to_int(args[1], "tabular.head count must be an integer") : 5; if (n < 0) n = 0;
    HxArray *rows = hx_as_array(table_rows(args[0])); if ((uint64_t)n > rows->length) n = (int64_t)rows->length;
    HxValue data = hx_make_array(); for (int64_t i = 0; i < n; ++i) hx_array_push(data, rows->items[i]); return table_new(table_columns(args[0]), data);
}
HX_NATIVE(nat_tabular_column) {
    (void)fn; if (argc != 2) hx_raise_error("tabular.column expects table and column name"); size_t col = table_col_index(args[0], args[1]);
    HxArray *rows = hx_as_array(table_rows(args[0])); HxValue out = hx_make_array();
    for (size_t i = 0; i < rows->length; ++i) { HxArray *r = hx_as_array(rows->items[i]); hx_array_push(out, r && col < r->length ? r->items[col] : HX_NIL_VALUE); }
    return out;
}
HX_NATIVE(nat_tabular_select) {
    (void)fn; if (argc != 2 || !table_valid(args[0]) || args[1].tag != HX_ARRAY) hx_raise_error("tabular.select expects table and array of column names");
    HxArray *names = hx_as_array(args[1]), *oldcols = hx_as_array(table_columns(args[0])), *rows = hx_as_array(table_rows(args[0]));
    size_t *indices = (size_t *)malloc((names->length ? names->length : 1) * sizeof(size_t)); if (!indices) hx_raise_error("out of memory");
    HxValue cols = hx_make_array(); for (size_t c = 0; c < names->length; ++c) { indices[c] = table_col_index(args[0], names->items[c]); hx_array_push(cols, oldcols->items[indices[c]]); }
    HxValue outrows = hx_make_array();
    for (size_t r = 0; r < rows->length; ++r) { HxArray *old = hx_as_array(rows->items[r]); HxValue nr = hx_make_array(); for (size_t c = 0; c < names->length; ++c) hx_array_push(nr, old && indices[c] < old->length ? old->items[indices[c]] : HX_NIL_VALUE); hx_array_push(outrows, nr); }
    free(indices); return table_new(cols, outrows);
}
static int cell_compare(HxValue a, HxValue b) {
    if (a.tag == HX_NIL && b.tag != HX_NIL) return -1;
    if (b.tag == HX_NIL && a.tag != HX_NIL) return 1;
    if ((a.tag == HX_INT || a.tag == HX_FLOAT) && (b.tag == HX_INT || b.tag == HX_FLOAT)) {
        double x = a.tag == HX_INT ? (double)(int64_t)a.payload : hx_bits_double(a.payload);
        double y = b.tag == HX_INT ? (double)(int64_t)b.payload : hx_bits_double(b.payload);
        return (x > y) - (x < y);
    }
    if (a.tag == HX_STRING && b.tag == HX_STRING) {
        HxString *sa=(HxString*)(uintptr_t)a.payload,*sb=(HxString*)(uintptr_t)b.payload;
        char *ea=NULL,*eb=NULL;errno=0;double da=strtod(sa->bytes,&ea);int oka=!errno&&ea==sa->bytes+sa->length;
        errno=0;double db=strtod(sb->bytes,&eb);int okb=!errno&&eb==sb->bytes+sb->length;
        if(oka&&okb&&isfinite(da)&&isfinite(db))return (da>db)-(da<db);
        return value_string_compare(a,b);
    }
    if (a.tag == HX_BOOL && b.tag == HX_BOOL) return (a.payload > b.payload) - (a.payload < b.payload);
    return (a.tag > b.tag) - (a.tag < b.tag);
}
HX_NATIVE(nat_tabular_sort_by) {
    (void)fn; if (argc < 2 || argc > 3 || !table_valid(args[0])) hx_raise_error("tabular.sortBy expects table, column and optional ascending");
    size_t col = table_col_index(args[0], args[1]); int asc = argc < 3 || hx_value_truthy(args[2]);
    HxArray *src = hx_as_array(table_rows(args[0])); size_t n = (size_t)src->length;
    HxValue *copy = (HxValue *)malloc((n ? n : 1) * sizeof(HxValue)); if (!copy) hx_raise_error("out of memory sorting table");
    memcpy(copy, src->items, n * sizeof(HxValue));
    for (size_t i = 1; i < n; ++i) { HxValue item = copy[i]; HxArray *ir = hx_as_array(item); HxValue iv = ir && col < ir->length ? ir->items[col] : HX_NIL_VALUE; size_t j = i;
        while (j) { HxArray *pr = hx_as_array(copy[j-1]); HxValue pv = pr && col < pr->length ? pr->items[col] : HX_NIL_VALUE; int cmp = cell_compare(pv, iv); if (asc ? cmp <= 0 : cmp >= 0) break; copy[j] = copy[j-1]; --j; } copy[j] = item; }
    HxValue out = hx_make_array(); for (size_t i = 0; i < n; ++i) hx_array_push(out, copy[i]); free(copy); return table_new(table_columns(args[0]), out);
}
HX_NATIVE(nat_tabular_filter_equals) {
    (void)fn; if (argc != 3 || !table_valid(args[0])) hx_raise_error("tabular.filterEquals expects table, column and value");
    size_t col = table_col_index(args[0], args[1]); HxArray *rows = hx_as_array(table_rows(args[0])); HxValue out = hx_make_array();
    for (size_t i = 0; i < rows->length; ++i) { HxArray *r = hx_as_array(rows->items[i]); if (r && col < r->length && cell_compare(r->items[col], args[2]) == 0) hx_array_push(out, rows->items[i]); }
    return table_new(table_columns(args[0]), out);
}
HX_NATIVE(nat_tabular_infer_types) {
    (void)fn;
    if (argc != 1 || !table_valid(args[0])) hx_raise_error("tabular.inferTypes expects a table");
    HxArray *cols = hx_as_array(table_columns(args[0])), *rows = hx_as_array(table_rows(args[0]));
    HxValue types = hx_make_array();
    for (size_t c = 0; c < cols->length; ++c) {
        int seen=0, all_int=1, all_num=1, all_bool=1;
        for (size_t r = 0; r < rows->length; ++r) {
            HxArray *row=hx_as_array(rows->items[r]);
            HxValue v=row&&c<row->length?row->items[c]:HX_NIL_VALUE;
            if(v.tag==HX_NIL||(v.tag==HX_STRING&&hx_string_length(v)==0))continue;
            seen=1;
            if(v.tag==HX_INT){all_bool=0;continue;}
            if(v.tag==HX_FLOAT){all_int=0;all_bool=0;continue;}
            if(v.tag==HX_BOOL){all_int=0;all_num=0;continue;}
            if(v.tag==HX_STRING){
                HxString *sv=(HxString*)(uintptr_t)v.payload;
                if((value_string_equal(v,"true")||value_string_equal(v,"false"))){all_int=0;all_num=0;continue;}
                char *end=NULL;errno=0;(void)strtoll(sv->bytes,&end,10);
                int isint=!errno&&end==sv->bytes+sv->length;
                errno=0;end=NULL;(void)strtod(sv->bytes,&end);
                int isnum=!errno&&end==sv->bytes+sv->length;
                if (!isint) all_int = 0;
                if (!isnum) all_num = 0;
                all_bool = 0;
                continue;
            }
            all_int=all_num=all_bool=0;
        }
        hx_array_push(types,hx_make_string(!seen?"null":all_bool?"bool":all_int?"int":all_num?"number":"string"));
    }
    return types;
}

/* --------------------------------------------------------- SQLite backend -- */
#include <sqlite3.h>
static sqlite3 *sqlite_handle(HxValue v) {
    if (v.tag != HX_INT || !v.payload) hx_raise_error("sqlite database handle is invalid or closed");
    return (sqlite3 *)(uintptr_t)v.payload;
}
static sqlite3_stmt *sqlite_stmt_handle(HxValue v) {
    if (v.tag != HX_INT || !v.payload) hx_raise_error("sqlite statement handle is invalid or finalized");
    return (sqlite3_stmt *)(uintptr_t)v.payload;
}
static void sqlite_fail(sqlite3 *db, const char *prefix) {
    char msg[1024]; snprintf(msg, sizeof(msg), "%s: %s", prefix, db ? sqlite3_errmsg(db) : "out of memory"); hx_raise_error(msg);
}
static HxValue sqlite_column_value(sqlite3_stmt *st, int i) {
    switch (sqlite3_column_type(st, i)) {
        case SQLITE_NULL: return HX_NIL_VALUE;
        case SQLITE_INTEGER: return HX_INT_VALUE(sqlite3_column_int64(st, i));
        case SQLITE_FLOAT: return HX_FLOAT_VALUE(sqlite3_column_double(st, i));
        case SQLITE_TEXT: { const void *p = sqlite3_column_text(st, i); int n = sqlite3_column_bytes(st, i); return hx_make_string_n((const char *)(p ? p : ""), (size_t)n); }
        case SQLITE_BLOB: { const void *p = sqlite3_column_blob(st, i); int n = sqlite3_column_bytes(st, i); return hx_make_string_n((const char *)(p ? p : ""), (size_t)n); }
        default: return HX_NIL_VALUE;
    }
}
HX_NATIVE(nat_sqlite_open) {
    (void)fn; if (argc != 1) hx_raise_error("sqlite.open expects a database path");
    const char *path = hx_to_cstr(args[0], "sqlite.open path must be a string"); sqlite3 *db = NULL;
    int rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
    if (rc != SQLITE_OK) { char msg[1024]; snprintf(msg,sizeof(msg),"sqlite.open: %s",db?sqlite3_errmsg(db):"cannot allocate database"); if(db)sqlite3_close(db); hx_raise_error(msg); }
    sqlite3_busy_timeout(db, 5000); return HX_INT_VALUE((uintptr_t)db);
}
HX_NATIVE(nat_sqlite_close) {
    (void)fn; if (argc != 1) hx_raise_error("sqlite.close expects a database handle"); sqlite3 *db = sqlite_handle(args[0]);
    int rc = sqlite3_close(db); if (rc != SQLITE_OK) sqlite_fail(db,"sqlite.close"); return HX_BOOL_VALUE(1);
}
HX_NATIVE(nat_sqlite_exec) {
    (void)fn; if (argc != 2) hx_raise_error("sqlite.exec expects database and SQL"); sqlite3 *db=sqlite_handle(args[0]); const char *sql=hx_to_cstr(args[1],"sqlite SQL must be a string"); char *err=NULL;
    int rc=sqlite3_exec(db,sql,NULL,NULL,&err); if(rc!=SQLITE_OK){char msg[1024];snprintf(msg,sizeof(msg),"sqlite.exec: %s",err?err:sqlite3_errmsg(db));sqlite3_free(err);hx_raise_error(msg);} return HX_INT_VALUE(sqlite3_changes(db));
}
HX_NATIVE(nat_sqlite_query) {
    (void)fn; if (argc != 2) hx_raise_error("sqlite.query expects database and SQL"); sqlite3 *db=sqlite_handle(args[0]); const char *sql=hx_to_cstr(args[1],"sqlite SQL must be a string"); sqlite3_stmt *st=NULL;
    int rc=sqlite3_prepare_v2(db,sql,-1,&st,NULL); if(rc!=SQLITE_OK)sqlite_fail(db,"sqlite.query prepare");
    int n=sqlite3_column_count(st); HxValue cols=hx_make_array(); for(int i=0;i<n;++i)hx_array_push(cols,hx_make_string(sqlite3_column_name(st,i)));
    HxValue rows=hx_make_array(); while((rc=sqlite3_step(st))==SQLITE_ROW){HxValue row=hx_make_array();for(int i=0;i<n;++i)hx_array_push(row,sqlite_column_value(st,i));hx_array_push(rows,row);}
    if(rc!=SQLITE_DONE){char msg[1024];snprintf(msg,sizeof(msg),"sqlite.query: %s",sqlite3_errmsg(db));sqlite3_finalize(st);hx_raise_error(msg);} sqlite3_finalize(st);return table_new(cols,rows);
}
HX_NATIVE(nat_sqlite_prepare) {
    (void)fn; if (argc != 2) hx_raise_error("sqlite.prepare expects database and SQL"); sqlite3 *db=sqlite_handle(args[0]); const char *sql=hx_to_cstr(args[1],"sqlite SQL must be a string"); sqlite3_stmt *st=NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) sqlite_fail(db, "sqlite.prepare");
    return HX_INT_VALUE((uintptr_t)st);
}
HX_NATIVE(nat_sqlite_bind_int) { (void)fn; if(argc!=3)hx_raise_error("sqlite.bindInt expects statement, index, value");sqlite3_stmt*st=sqlite_stmt_handle(args[0]);int i=(int)hx_to_int(args[1],"sqlite bind index must be integer");int64_t v=hx_to_int(args[2],"sqlite bind value must be integer");int rc=sqlite3_bind_int64(st,i,v);if(rc!=SQLITE_OK)hx_raise_error("sqlite.bindInt failed");return HX_BOOL_VALUE(1); }
HX_NATIVE(nat_sqlite_bind_float) { (void)fn; if(argc!=3)hx_raise_error("sqlite.bindFloat expects statement, index, value");sqlite3_stmt*st=sqlite_stmt_handle(args[0]);int i=(int)hx_to_int(args[1],"sqlite bind index must be integer");double v=hx_to_number(args[2],"sqlite bind value must be numeric");int rc=sqlite3_bind_double(st,i,v);if(rc!=SQLITE_OK)hx_raise_error("sqlite.bindFloat failed");return HX_BOOL_VALUE(1); }
HX_NATIVE(nat_sqlite_bind_text) { (void)fn; if(argc!=3)hx_raise_error("sqlite.bindText expects statement, index, value");sqlite3_stmt*st=sqlite_stmt_handle(args[0]);int i=(int)hx_to_int(args[1],"sqlite bind index must be integer");HxString*s=hx_as_string(args[2]);if(!s)hx_raise_error("sqlite.bindText value must be string");int rc=sqlite3_bind_text(st,i,s->bytes,(int)s->length,SQLITE_TRANSIENT);if(rc!=SQLITE_OK)hx_raise_error("sqlite.bindText failed");return HX_BOOL_VALUE(1); }
HX_NATIVE(nat_sqlite_bind_null) { (void)fn; if(argc!=2)hx_raise_error("sqlite.bindNull expects statement and index");sqlite3_stmt*st=sqlite_stmt_handle(args[0]);int i=(int)hx_to_int(args[1],"sqlite bind index must be integer");if(sqlite3_bind_null(st,i)!=SQLITE_OK)hx_raise_error("sqlite.bindNull failed");return HX_BOOL_VALUE(1); }
HX_NATIVE(nat_sqlite_step) { (void)fn; if(argc!=1)hx_raise_error("sqlite.step expects statement");sqlite3_stmt*st=sqlite_stmt_handle(args[0]);int rc=sqlite3_step(st);if(rc==SQLITE_ROW)return HX_BOOL_VALUE(1);if(rc==SQLITE_DONE)return HX_BOOL_VALUE(0);sqlite3*db=sqlite3_db_handle(st);sqlite_fail(db,"sqlite.step");return HX_NIL_VALUE; }
HX_NATIVE(nat_sqlite_column_count) { (void)fn; if(argc!=1)hx_raise_error("sqlite.columnCount expects statement");return HX_INT_VALUE(sqlite3_column_count(sqlite_stmt_handle(args[0]))); }
HX_NATIVE(nat_sqlite_column_name) { (void)fn; if(argc!=2)hx_raise_error("sqlite.columnName expects statement and index");const char*s=sqlite3_column_name(sqlite_stmt_handle(args[0]),(int)hx_to_int(args[1],"column index must be integer"));return hx_make_string(s?s:""); }
HX_NATIVE(nat_sqlite_column_value) { (void)fn; if(argc!=2)hx_raise_error("sqlite.column expects statement and index");return sqlite_column_value(sqlite_stmt_handle(args[0]),(int)hx_to_int(args[1],"column index must be integer")); }
HX_NATIVE(nat_sqlite_column_type) { (void)fn; if(argc!=2)hx_raise_error("sqlite.columnType expects statement and index");int t=sqlite3_column_type(sqlite_stmt_handle(args[0]),(int)hx_to_int(args[1],"column index must be integer"));const char*s=t==SQLITE_INTEGER?"integer":t==SQLITE_FLOAT?"float":t==SQLITE_TEXT?"text":t==SQLITE_BLOB?"blob":"null";return hx_make_string(s); }
HX_NATIVE(nat_sqlite_reset) { (void)fn; if(argc!=1)hx_raise_error("sqlite.reset expects statement");sqlite3_stmt*st=sqlite_stmt_handle(args[0]);if(sqlite3_reset(st)!=SQLITE_OK)sqlite_fail(sqlite3_db_handle(st),"sqlite.reset");sqlite3_clear_bindings(st);return HX_BOOL_VALUE(1); }
HX_NATIVE(nat_sqlite_finalize) { (void)fn; if(argc!=1)hx_raise_error("sqlite.finalize expects statement");sqlite3_stmt*st=sqlite_stmt_handle(args[0]);int rc=sqlite3_finalize(st);if(rc!=SQLITE_OK)hx_raise_error("sqlite.finalize failed");return HX_BOOL_VALUE(1); }
HX_NATIVE(nat_sqlite_changes) { (void)fn; if(argc!=1)hx_raise_error("sqlite.changes expects database");return HX_INT_VALUE(sqlite3_changes(sqlite_handle(args[0]))); }
HX_NATIVE(nat_sqlite_last_insert_id) { (void)fn; if(argc!=1)hx_raise_error("sqlite.lastInsertId expects database");return HX_INT_VALUE(sqlite3_last_insert_rowid(sqlite_handle(args[0]))); }

/* ------------------------------------ MariaDB / MySQL Connector-C -------- */
#ifdef HX_WITH_MARIADB
#include <mysql.h>

typedef struct {
    MYSQL *db;
    unsigned long open_statements;
    int closed;
} HxMysqlConnection;

typedef struct {
    MYSQL_STMT *stmt;
    HxMysqlConnection *owner;
    unsigned long param_count;
    MYSQL_BIND *param_binds;
    void **owned_param_buffers;
    unsigned long *param_lengths;
    my_bool *param_nulls;
    int closed;
} HxMysqlStatement;

static HxMysqlConnection *mysql_connection_handle(HxValue v) {
    if (v.tag != HX_INT || !v.payload) hx_raise_error("mysql connection handle is invalid or closed");
    HxMysqlConnection *c = (HxMysqlConnection *)(uintptr_t)v.payload;
    if (c->closed || !c->db) hx_raise_error("mysql connection is already closed");
    return c;
}
static MYSQL *mysql_handle(HxValue v) { return mysql_connection_handle(v)->db; }
static HxMysqlStatement *mysql_stmt_wrapper(HxValue v) {
    if (v.tag != HX_INT || !v.payload) hx_raise_error("mysql statement handle is invalid or closed");
    HxMysqlStatement *s = (HxMysqlStatement *)(uintptr_t)v.payload;
    if (s->closed || !s->stmt) hx_raise_error("mysql statement is already closed");
    if (!s->owner || s->owner->closed || !s->owner->db) hx_raise_error("mysql connection was closed before its statement");
    return s;
}
static void mysql_fail(MYSQL *db, const char *prefix) {
    char m[1024]; snprintf(m, sizeof(m), "%s: %s", prefix, db ? mysql_error(db) : "no connection"); hx_raise_error(m);
}
static void mysql_stmt_fail(HxMysqlStatement *s, const char *prefix) {
    char m[1024]; snprintf(m, sizeof(m), "%s: %s", prefix, s && s->stmt ? mysql_stmt_error(s->stmt) : "no statement"); hx_raise_error(m);
}
static void mysql_stmt_query_buffers_free(char **buffers, unsigned int count,
                                          MYSQL_BIND *binds, unsigned long *lengths,
                                          my_bool *nulls, my_bool *errors) {
    if (buffers) {
        for (unsigned int i = 0; i < count; ++i) free(buffers[i]);
    }
    free(binds);
    free(buffers);
    free(lengths);
    free(nulls);
    free(errors);
}
static void mysql_stmt_clear_param(HxMysqlStatement *s, unsigned long i) {
    if (s->owned_param_buffers[i]) { free(s->owned_param_buffers[i]); s->owned_param_buffers[i] = NULL; }
    memset(&s->param_binds[i], 0, sizeof(MYSQL_BIND));
    s->param_lengths[i] = 0;
    s->param_nulls[i] = 0;
}
static unsigned long mysql_param_index(HxMysqlStatement *s, HxValue value) {
    int64_t index = hx_to_int(value, "mysql parameter index must be an integer (1-based)");
    if (index < 1 || (unsigned long)index > s->param_count) hx_raise_error("mysql parameter index is out of range");
    return (unsigned long)index - 1;
}

static HxValue mysql_open_connection(const char *host, const char *user,
                                     const char *password, const char *database,
                                     unsigned int port, const char *ca,
                                     const char *cert, const char *key) {
    MYSQL *db = mysql_init(NULL);
    if (!db) hx_raise_error("mysql.open: mysql_init failed");
    unsigned int timeout = 5;
    mysql_options(db, MYSQL_OPT_CONNECT_TIMEOUT, &timeout);
    mysql_options(db, MYSQL_SET_CHARSET_NAME, "utf8mb4");
    unsigned long flags = CLIENT_MULTI_RESULTS;
    if (ca || cert || key) {
        if (mysql_ssl_set(db, key, cert, ca, NULL, NULL) != 0) {
            char m[1024]; snprintf(m, sizeof(m), "mysql.openTLS: TLS setup failed: %s", mysql_error(db)); mysql_close(db); hx_raise_error(m);
        }
        flags |= CLIENT_SSL;
    }
    if (!mysql_real_connect(db, host, user, password, database, port, NULL, flags)) {
        char m[1024]; snprintf(m, sizeof(m), "mysql.open: %s", mysql_error(db)); mysql_close(db); hx_raise_error(m);
    }
    HxMysqlConnection *connection = (HxMysqlConnection *)hx_alloc(sizeof(*connection));
    connection->db = db; connection->open_statements = 0; connection->closed = 0;
    return HX_INT_VALUE((uintptr_t)connection);
}
HX_NATIVE(nat_mysql_open) {
    (void)fn;
    if (argc < 4 || argc > 5) hx_raise_error("mysql.open expects host, user, password, database and optional port");
    const char *host = hx_to_cstr(args[0], "mysql host must be a string");
    const char *user = hx_to_cstr(args[1], "mysql user must be a string");
    const char *password = hx_to_cstr(args[2], "mysql password must be a string");
    const char *database = hx_to_cstr(args[3], "mysql database must be a string");
    int64_t port_value = argc == 5 ? hx_to_int(args[4], "mysql port must be an integer") : 3306;
    if (port_value < 1 || port_value > 65535) hx_raise_error("mysql.open port must be between 1 and 65535");
    return mysql_open_connection(host, user, password, database, (unsigned int)port_value, NULL, NULL, NULL);
}
HX_NATIVE(nat_mysql_open_tls) {
    (void)fn;
    if (argc != 8) hx_raise_error("mysql.openTLS expects host,user,password,database,port,ca,cert,key");
    const char *host = hx_to_cstr(args[0], "mysql host must be a string");
    const char *user = hx_to_cstr(args[1], "mysql user must be a string");
    const char *password = hx_to_cstr(args[2], "mysql password must be a string");
    const char *database = hx_to_cstr(args[3], "mysql database must be a string");
    int64_t port_value = hx_to_int(args[4], "mysql port must be an integer");
    if (port_value < 1 || port_value > 65535) hx_raise_error("mysql.openTLS port must be between 1 and 65535");
    const char *ca_arg = hx_to_cstr(args[5], "mysql TLS CA path must be a string");
    const char *cert_arg = hx_to_cstr(args[6], "mysql TLS certificate path must be a string");
    const char *key_arg = hx_to_cstr(args[7], "mysql TLS key path must be a string");
    const char *ca = *ca_arg ? ca_arg : NULL;
    const char *cert = *cert_arg ? cert_arg : NULL;
    const char *key = *key_arg ? key_arg : NULL;
    if (!ca && (!cert || !key)) hx_raise_error("mysql.openTLS requires a CA path or both client certificate and key");
    return mysql_open_connection(host, user, password, database, (unsigned int)port_value, ca, cert, key);
}
HX_NATIVE(nat_mysql_close) {
    (void)fn; if (argc != 1) hx_raise_error("mysql.close expects a connection");
    HxMysqlConnection *c = mysql_connection_handle(args[0]);
    if (c->open_statements != 0) hx_raise_error("mysql.close: close all prepared statements before closing the connection");
    mysql_close(c->db); c->db = NULL; c->closed = 1;
    return HX_BOOL_VALUE(1);
}
HX_NATIVE(nat_mysql_exec) {
    (void)fn; if (argc != 2) hx_raise_error("mysql.exec expects connection and SQL");
    MYSQL *db = mysql_handle(args[0]); HxString *sql = hx_as_string(args[1]);
    if (!sql) hx_raise_error("mysql SQL must be a string");
    if (mysql_real_query(db, sql->bytes, (unsigned long)sql->length)) mysql_fail(db, "mysql.exec");
    MYSQL_RES *r = mysql_store_result(db);
    if (r) mysql_free_result(r); else if (mysql_field_count(db)) mysql_fail(db, "mysql.exec result");
    return HX_INT_VALUE((int64_t)mysql_affected_rows(db));
}
HX_NATIVE(nat_mysql_query) {
    (void)fn; if (argc != 2) hx_raise_error("mysql.query expects connection and SQL");
    MYSQL *db = mysql_handle(args[0]); HxString *sql = hx_as_string(args[1]);
    if (!sql) hx_raise_error("mysql SQL must be a string");
    if (mysql_real_query(db, sql->bytes, (unsigned long)sql->length)) mysql_fail(db, "mysql.query");
    MYSQL_RES *r = mysql_store_result(db);
    if (!r) {
        if (mysql_field_count(db)) mysql_fail(db, "mysql.query result");
        return table_new(hx_make_array(), hx_make_array());
    }
    unsigned int n = mysql_num_fields(r); MYSQL_FIELD *fields = mysql_fetch_fields(r);
    HxValue cols = hx_make_array();
    for (unsigned int i = 0; i < n; ++i) hx_array_push(cols, hx_make_string(fields[i].name));
    HxValue rows = hx_make_array(); MYSQL_ROW row;
    while ((row = mysql_fetch_row(r))) {
        unsigned long *lengths = mysql_fetch_lengths(r); HxValue rr = hx_make_array();
        for (unsigned int i = 0; i < n; ++i) hx_array_push(rr, row[i] ? hx_make_string_n(row[i], lengths[i]) : HX_NIL_VALUE);
        hx_array_push(rows, rr);
    }
    mysql_free_result(r); return table_new(cols, rows);
}
HX_NATIVE(nat_mysql_error) {
    (void)fn; if (argc != 1) hx_raise_error("mysql.error expects connection");
    return hx_make_string(mysql_error(mysql_handle(args[0])));
}
HX_NATIVE(nat_mysql_prepare) {
    (void)fn; if (argc != 2) hx_raise_error("mysql.prepare expects connection and SQL");
    HxMysqlConnection *owner = mysql_connection_handle(args[0]);
    HxString *sql = hx_as_string(args[1]); if (!sql) hx_raise_error("mysql SQL must be a string");
    MYSQL_STMT *stmt = mysql_stmt_init(owner->db); if (!stmt) mysql_fail(owner->db, "mysql.prepare");
    if (mysql_stmt_prepare(stmt, sql->bytes, (unsigned long)sql->length)) {
        char m[1024]; snprintf(m, sizeof(m), "mysql.prepare: %s", mysql_stmt_error(stmt)); mysql_stmt_close(stmt); hx_raise_error(m);
    }
    HxMysqlStatement *s = (HxMysqlStatement *)hx_alloc(sizeof(*s));
    s->stmt = stmt; s->owner = owner; s->param_count = mysql_stmt_param_count(stmt); s->closed = 0;
    size_t count = s->param_count ? s->param_count : 1;
    s->param_binds = (MYSQL_BIND *)calloc(count, sizeof(MYSQL_BIND));
    s->owned_param_buffers = (void **)calloc(count, sizeof(void *));
    s->param_lengths = (unsigned long *)calloc(count, sizeof(unsigned long));
    s->param_nulls = (my_bool *)calloc(count, sizeof(my_bool));
    if (!s->param_binds || !s->owned_param_buffers || !s->param_lengths || !s->param_nulls) {
        free(s->param_binds); free(s->owned_param_buffers); free(s->param_lengths); free(s->param_nulls);
        mysql_stmt_close(stmt); s->stmt = NULL; s->closed = 1;
        hx_raise_error("mysql.prepare: out of memory allocating parameter bindings");
    }
    my_bool update_max = 1;
    mysql_stmt_attr_set(stmt, STMT_ATTR_UPDATE_MAX_LENGTH, &update_max);
    owner->open_statements++;
    return HX_INT_VALUE((uintptr_t)s);
}
HX_NATIVE(nat_mysql_stmt_bind_int) {
    (void)fn; if (argc != 3) hx_raise_error("mysql.bindInt expects statement, 1-based index, integer");
    HxMysqlStatement *s = mysql_stmt_wrapper(args[0]); unsigned long i = mysql_param_index(s, args[1]);
    int64_t value = hx_to_int(args[2], "mysql.bindInt value must be an integer"); mysql_stmt_clear_param(s, i);
    int64_t *buffer = (int64_t *)malloc(sizeof(*buffer)); if (!buffer) hx_raise_error("mysql.bindInt: out of memory"); *buffer = value;
    s->owned_param_buffers[i] = buffer; s->param_binds[i].buffer_type = MYSQL_TYPE_LONGLONG;
    s->param_binds[i].buffer = buffer; s->param_binds[i].buffer_length = sizeof(*buffer); s->param_binds[i].is_unsigned = 0;
    return HX_BOOL_VALUE(1);
}
HX_NATIVE(nat_mysql_stmt_bind_float) {
    (void)fn; if (argc != 3) hx_raise_error("mysql.bindFloat expects statement, 1-based index, number");
    HxMysqlStatement *s = mysql_stmt_wrapper(args[0]); unsigned long i = mysql_param_index(s, args[1]);
    double value = hx_to_number(args[2], "mysql.bindFloat value must be numeric"); mysql_stmt_clear_param(s, i);
    double *buffer = (double *)malloc(sizeof(*buffer)); if (!buffer) hx_raise_error("mysql.bindFloat: out of memory"); *buffer = value;
    s->owned_param_buffers[i] = buffer; s->param_binds[i].buffer_type = MYSQL_TYPE_DOUBLE;
    s->param_binds[i].buffer = buffer; s->param_binds[i].buffer_length = sizeof(*buffer);
    return HX_BOOL_VALUE(1);
}
HX_NATIVE(nat_mysql_stmt_bind_text) {
    (void)fn; if (argc != 3) hx_raise_error("mysql.bindText expects statement, 1-based index, string");
    HxMysqlStatement *s = mysql_stmt_wrapper(args[0]); unsigned long i = mysql_param_index(s, args[1]);
    HxString *value = hx_as_string(args[2]); if (!value) hx_raise_error("mysql.bindText value must be a string"); mysql_stmt_clear_param(s, i);
    s->param_lengths[i] = (unsigned long)value->length; s->param_binds[i].buffer_type = MYSQL_TYPE_STRING;
    s->param_binds[i].buffer = value->bytes; s->param_binds[i].buffer_length = s->param_lengths[i];
    s->param_binds[i].length = &s->param_lengths[i];
    return HX_BOOL_VALUE(1);
}
HX_NATIVE(nat_mysql_stmt_bind_null) {
    (void)fn; if (argc != 2) hx_raise_error("mysql.bindNull expects statement and 1-based index");
    HxMysqlStatement *s = mysql_stmt_wrapper(args[0]); unsigned long i = mysql_param_index(s, args[1]); mysql_stmt_clear_param(s, i);
    s->param_nulls[i] = 1; s->param_binds[i].buffer_type = MYSQL_TYPE_NULL; s->param_binds[i].is_null = &s->param_nulls[i];
    return HX_BOOL_VALUE(1);
}
static void mysql_stmt_execute_checked(HxMysqlStatement *s) {
    if (s->param_count && mysql_stmt_bind_param(s->stmt, s->param_binds)) mysql_stmt_fail(s, "mysql.bind parameters");
    if (mysql_stmt_execute(s->stmt)) mysql_stmt_fail(s, "mysql.execute");
}
HX_NATIVE(nat_mysql_stmt_execute) {
    (void)fn; if (argc != 1) hx_raise_error("mysql.execute expects a statement");
    HxMysqlStatement *s = mysql_stmt_wrapper(args[0]); mysql_stmt_execute_checked(s);
    my_ulonglong affected = mysql_stmt_affected_rows(s->stmt);
    return HX_INT_VALUE(affected == (my_ulonglong)-1 ? 0 : (int64_t)affected);
}
HX_NATIVE(nat_mysql_stmt_query) {
    (void)fn; if (argc != 1) hx_raise_error("mysql.queryStatement expects a statement");
    HxMysqlStatement *s = mysql_stmt_wrapper(args[0]); mysql_stmt_execute_checked(s);
    MYSQL_RES *meta = mysql_stmt_result_metadata(s->stmt);
    if (!meta) return table_new(hx_make_array(), hx_make_array());
    if (mysql_stmt_store_result(s->stmt)) { mysql_free_result(meta); mysql_stmt_fail(s, "mysql.store result"); }
    unsigned int n = mysql_num_fields(meta); MYSQL_FIELD *fields = mysql_fetch_fields(meta);
    HxValue cols = hx_make_array(); size_t total_cap = 0;
    for (unsigned int i = 0; i < n; ++i) hx_array_push(cols, hx_make_string(fields[i].name));
    MYSQL_BIND *binds = (MYSQL_BIND *)calloc(n ? n : 1, sizeof(MYSQL_BIND));
    char **buffers = (char **)calloc(n ? n : 1, sizeof(char *));
    unsigned long *lengths = (unsigned long *)calloc(n ? n : 1, sizeof(unsigned long));
    my_bool *nulls = (my_bool *)calloc(n ? n : 1, sizeof(my_bool));
    my_bool *errors = (my_bool *)calloc(n ? n : 1, sizeof(my_bool));
    if (!binds || !buffers || !lengths || !nulls || !errors) {
        mysql_free_result(meta); free(binds); free(buffers); free(lengths); free(nulls); free(errors); hx_raise_error("mysql.queryStatement: out of memory");
    }
    for (unsigned int i = 0; i < n; ++i) {
        size_t cap = (size_t)fields[i].max_length + 1; if (cap < 2) cap = 2;
        if (cap > 8u * 1024u * 1024u || total_cap + cap > 64u * 1024u * 1024u) {
            for (unsigned int j = 0; j < i; ++j) free(buffers[j]);
            mysql_free_result(meta); free(binds); free(buffers); free(lengths); free(nulls); free(errors);
            hx_raise_error("mysql.queryStatement: result column exceeds the 8 MiB safety limit");
        }
        total_cap += cap; buffers[i] = (char *)malloc(cap);
        if (!buffers[i]) {
            for (unsigned int j = 0; j < i; ++j) free(buffers[j]);
            mysql_free_result(meta); free(binds); free(buffers); free(lengths); free(nulls); free(errors); hx_raise_error("mysql.queryStatement: out of memory");
        }
        binds[i].buffer_type = MYSQL_TYPE_STRING; binds[i].buffer = buffers[i]; binds[i].buffer_length = (unsigned long)(cap - 1);
        binds[i].length = &lengths[i]; binds[i].is_null = &nulls[i]; binds[i].error = &errors[i];
    }
    if (mysql_stmt_bind_result(s->stmt, binds)) {
        char m[1024]; snprintf(m, sizeof(m), "mysql.bind results: %s", mysql_stmt_error(s->stmt));
        mysql_free_result(meta);
        mysql_stmt_query_buffers_free(buffers, n, binds, lengths, nulls, errors);
        hx_raise_error(m);
    }
    HxValue rows = hx_make_array(); int rc;
    while ((rc = mysql_stmt_fetch(s->stmt)) == 0 || rc == MYSQL_DATA_TRUNCATED) {
        if (rc == MYSQL_DATA_TRUNCATED) {
            mysql_free_result(meta);
            mysql_stmt_query_buffers_free(buffers, n, binds, lengths, nulls, errors);
            hx_raise_error("mysql.queryStatement: truncated result column (8 MiB maximum)");
        }
        HxValue row = hx_make_array();
        for (unsigned int i = 0; i < n; ++i) hx_array_push(row, nulls[i] ? HX_NIL_VALUE : hx_make_string_n(buffers[i], lengths[i]));
        hx_array_push(rows, row);
    }
    if (rc != MYSQL_NO_DATA) {
        char m[1024]; snprintf(m, sizeof(m), "mysql.fetch: %s", mysql_stmt_error(s->stmt));
        mysql_free_result(meta);
        mysql_stmt_query_buffers_free(buffers, n, binds, lengths, nulls, errors);
        hx_raise_error(m);
    }
    mysql_stmt_query_buffers_free(buffers, n, binds, lengths, nulls, errors);
    mysql_free_result(meta);
    return table_new(cols, rows);
}
HX_NATIVE(nat_mysql_stmt_close) {
    (void)fn; if (argc != 1) hx_raise_error("mysql.closeStatement expects a statement");
    HxMysqlStatement *s = mysql_stmt_wrapper(args[0]);
    for (unsigned long i = 0; i < s->param_count; ++i) if (s->owned_param_buffers[i]) free(s->owned_param_buffers[i]);
    free(s->param_binds); free(s->owned_param_buffers); free(s->param_lengths); free(s->param_nulls);
    int rc = mysql_stmt_close(s->stmt); s->stmt = NULL; s->closed = 1;
    if (s->owner && s->owner->open_statements > 0) s->owner->open_statements--;
    if (rc) hx_raise_error("mysql.closeStatement failed");
    return HX_BOOL_VALUE(1);
}
#else
static HxValue mysql_unavailable(void) { hx_raise_error("mysql module was built without MariaDB/MySQL Connector-C (install libmariadb and rebuild with WITH_MARIADB=1)"); }
HX_NATIVE(nat_mysql_open){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_open_tls){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_close){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_exec){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_query){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_error){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_prepare){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_stmt_bind_int){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_stmt_bind_float){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_stmt_bind_text){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_stmt_bind_null){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_stmt_execute){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_stmt_query){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
HX_NATIVE(nat_mysql_stmt_close){(void)args;(void)argc;(void)fn;return mysql_unavailable();}
#endif

/* --------------------------------------------- tiny, bounded HTTP server -- */
#if !defined(_WIN32)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <signal.h>
#include <sys/time.h>
static int socket_send_all(int fd, const char *data, size_t n) {
    size_t off = 0;
    while (off < n) {
#ifdef MSG_NOSIGNAL
        ssize_t k = send(fd, data + off, n - off, MSG_NOSIGNAL);
#else
        ssize_t k = send(fd, data + off, n - off, 0);
#endif
        if (k <= 0) return 0;
        off += (size_t)k;
    }
    return 1;
}
static const char *http_reason(int status) {
    switch (status) {
        case 200:return "OK"; case 201:return "Created"; case 202:return "Accepted";
        case 204:return "No Content"; case 301:return "Moved Permanently"; case 302:return "Found";
        case 304:return "Not Modified"; case 400:return "Bad Request"; case 401:return "Unauthorized";
        case 403:return "Forbidden"; case 404:return "Not Found"; case 405:return "Method Not Allowed";
        case 413:return "Payload Too Large"; case 415:return "Unsupported Media Type";
        case 429:return "Too Many Requests"; case 500:return "Internal Server Error";
        case 501:return "Not Implemented"; case 503:return "Service Unavailable";
        default:return "Response";
    }
}
static char *find_header_end(char *buf, size_t n) {
    if (n < 4) return NULL;
    for (size_t i = 0; i + 3 < n; ++i) if (!memcmp(buf+i,"\r\n\r\n",4)) return buf+i+4;
    for (size_t i = 0; i + 1 < n; ++i) if (!memcmp(buf+i,"\n\n",2)) return buf+i+2;
    return NULL;
}
static int parse_content_length(HxValue headers, size_t *length) {
    int found=0; HxValue k=hx_make_string("content-length"); int f=0; HxValue v=json_object_get(headers,k,&f);
    if(!f){*length=0;return 1;} if(v.tag!=HX_STRING)return 0;
    HxString*s=(HxString*)(uintptr_t)v.payload; char tmp[64]; if(s->length>=sizeof(tmp))return 0;memcpy(tmp,s->bytes,s->length);tmp[s->length]=0;
    char *end=NULL; errno=0; unsigned long long x=strtoull(tmp,&end,10);if(errno||!end||*end||x>8u*1024u*1024u)return 0;*length=(size_t)x;found=1;return found;
}
static HxValue make_http_headers(char *start, char *end) {
    HxValue headers = json_object_new();
    char *line = start;
    while (line < end) {
        char *nl = memchr(line, '\n', (size_t)(end - line));
        if (!nl) nl = end;
        char *line_end = nl;
        if (line_end > line && line_end[-1] == '\r') --line_end;
        if (line_end == line) break;
        char *colon = memchr(line, ':', (size_t)(line_end - line));
        if (colon) {
            char *value = colon + 1;
            while (value < line_end && (*value == ' ' || *value == '\t')) ++value;
            while (line_end > value && (line_end[-1] == ' ' || line_end[-1] == '\t')) --line_end;
            size_t key_len = (size_t)(colon - line), value_len = (size_t)(line_end - value);
            char *key = (char *)malloc(key_len + 1);
            if (!key) hx_raise_error("out of memory parsing HTTP headers");
            for (size_t i = 0; i < key_len; ++i) key[i] = (char)tolower((unsigned char)line[i]);
            key[key_len] = 0;
            json_object_set(headers, hx_make_string(key), hx_make_string_n(value, value_len));
            free(key);
        }
        line = nl < end ? nl + 1 : end;
    }
    return headers;
}
static void http_reply(int fd, int status, const char *content_type, const char *body,
                       size_t body_len, int head_only, HxValue extra_headers) {
    HxBuffer h = {0};
    char base[1024];
    int n = snprintf(base, sizeof(base),
        "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
        "Connection: close\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\n",
        status, http_reason(status), content_type, body_len);
    if (n > 0 && (size_t)n < sizeof(base)) buffer_bytes(&h, base, (size_t)n);

    HxArray *pairs = hx_as_array(extra_headers);
    if (json_is_object(extra_headers) && pairs) {
        for (size_t i = 1; i < pairs->length; ++i) {
            HxArray *pair = hx_as_array(pairs->items[i]);
            if (!pair || pair->length < 2 || pair->items[0].tag != HX_STRING || pair->items[1].tag != HX_STRING) continue;
            HxString *key = (HxString *)(uintptr_t)pair->items[0].payload;
            HxString *value = (HxString *)(uintptr_t)pair->items[1].payload;
            if (key->length == 0 || key->length > 64 || value->length > 2048) continue;
            int safe = 1;
            for (size_t j = 0; j < key->length; ++j) {
                unsigned char c = (unsigned char)key->bytes[j];
                if (!(isalnum(c) || c == '-')) safe = 0;
            }
            for (size_t j = 0; j < value->length; ++j) {
                if (value->bytes[j] == '\r' || value->bytes[j] == '\n' || value->bytes[j] == 0) safe = 0;
            }
            if (!safe) continue;
            buffer_bytes(&h, key->bytes, (size_t)key->length);
            buffer_cstr(&h, ": ");
            buffer_bytes(&h, value->bytes, (size_t)value->length);
            buffer_cstr(&h, "\r\n");
        }
    }
    buffer_cstr(&h, "\r\n");
    if (h.length < 16384) socket_send_all(fd, h.data, h.length);
    if (!head_only && body_len) socket_send_all(fd, body, body_len);
    free(h.data);
}
static void handle_http_client(int fd, HxValue callback) {
    const size_t max_header=32768, max_body=8u*1024u*1024u;
    size_t cap=8192, n=0;char *buf=(char*)malloc(cap);if(!buf){http_reply(fd,500,"text/plain","out of memory",13,0,HX_NIL_VALUE);return;}
    char *header_end=NULL;
    while(!header_end&&n<max_header){if(n==cap){cap*=2;char*t=(char*)realloc(buf,cap);if(!t){free(buf);http_reply(fd,500,"text/plain","out of memory",13,0,HX_NIL_VALUE);return;}buf=t;}
        ssize_t got=recv(fd,buf+n,cap-n,0);if(got<=0){free(buf);return;}n+=(size_t)got;header_end=find_header_end(buf,n);}
    if(!header_end){free(buf);http_reply(fd,400,"text/plain","request headers too large",26,0,HX_NIL_VALUE);return;}
    size_t header_bytes=(size_t)(header_end-buf);char *headers_start=memchr(buf,'\n',header_bytes);if(!headers_start){free(buf);http_reply(fd,400,"text/plain","invalid request line",21,0,HX_NIL_VALUE);return;}++headers_start;
    char *line_end=strstr(buf,"\r\n");if(!line_end)line_end=strchr(buf,'\n');if(!line_end){free(buf);http_reply(fd,400,"text/plain","invalid request line",21,0,HX_NIL_VALUE);return;}
    *line_end=0;char method[16]={0},target[4096]={0},version[16]={0};if(sscanf(buf,"%15s %4095s %15s",method,target,version)!=3){free(buf);http_reply(fd,400,"text/plain","invalid request line",21,0,HX_NIL_VALUE);return;}
    HxValue headers=make_http_headers(headers_start,header_end-2);size_t content_len=0;
    if(!parse_content_length(headers,&content_len)){free(buf);http_reply(fd,413,"text/plain","invalid content length or body too large",41,0,HX_NIL_VALUE);return;}
    size_t have=n-(size_t)(header_end-buf);
    if(content_len>max_body){free(buf);http_reply(fd,413,"text/plain","request body too large",22,0,HX_NIL_VALUE);return;}
    if(have<content_len){size_t need=(size_t)(header_end-buf)+content_len;if(need>cap){char*t=(char*)realloc(buf,need);if(!t){free(buf);http_reply(fd,500,"text/plain","out of memory",13,0,HX_NIL_VALUE);return;}buf=t;cap=need;}
        while(have<content_len){ssize_t got=recv(fd,buf+n,cap-n,0);if(got<=0){free(buf);http_reply(fd,400,"text/plain","incomplete request body",24,0,HX_NIL_VALUE);return;}n+=(size_t)got;have+=(size_t)got;}}
    int has_te=0; HxValue te=json_object_get(headers,hx_make_string("transfer-encoding"),&has_te);
    if(has_te && te.tag==HX_STRING && (te.tag==HX_STRING && strncasecmp(((HxString*)(uintptr_t)te.payload)->bytes,"chunked",((HxString*)(uintptr_t)te.payload)->length)==0)){free(buf);http_reply(fd,501,"text/plain","chunked request bodies are not supported",39,0,HX_NIL_VALUE);return;}
    char *q=strchr(target,'?');char *query="";if(q){*q=0;query=q+1;}
    HxValue args[5];args[0]=hx_make_string(method);args[1]=hx_make_string(target);args[2]=hx_make_string(query);args[3]=headers;args[4]=hx_make_string_n(header_end,content_len);
    HxValue response=hx_call_callback(callback.tag,callback.payload,args,5);
    int status=200;const char *ctype="text/html; charset=utf-8";const char *body="";size_t body_len=0;int head_only=!strcmp(method,"HEAD");HxValue extra_headers=HX_NIL_VALUE;
    if(response.tag==HX_STRING){HxString*s=(HxString*)(uintptr_t)response.payload;body=s->bytes;body_len=(size_t)s->length;}
    else if(response.tag==HX_ARRAY){HxArray*a=(HxArray*)(uintptr_t)response.payload;if(a->length>=3){if(a->items[0].tag==HX_INT)status=(int)(int64_t)a->items[0].payload;if(a->items[1].tag==HX_STRING)ctype=((HxString*)(uintptr_t)a->items[1].payload)->bytes;if(a->items[2].tag==HX_STRING){HxString*s=(HxString*)(uintptr_t)a->items[2].payload;body=s->bytes;body_len=(size_t)s->length;}if(a->length>=4)extra_headers=a->items[3];}}
    else if(response.tag==HX_NIL){status=404;body="Not Found";body_len=9;ctype="text/plain; charset=utf-8";}
    else {status=500;body="handler must return a string or [status, contentType, body]";body_len=strlen(body);ctype="text/plain; charset=utf-8";}
    http_reply(fd,status,ctype,body,body_len,head_only,extra_headers);free(buf);
}
HX_NATIVE(nat_web_serve) {
    (void)fn;
    if(argc<2||argc>3)hx_raise_error("hexoweb.serve expects port, handler and optional maxRequests");
    int64_t port=hx_to_int(args[0],"hexoweb port must be an integer");if(port<1||port>65535)hx_raise_error("hexoweb port must be between 1 and 65535");
    if(args[1].tag!=HX_FUNCTION)hx_raise_error("hexoweb.serve handler must be a function");
    int64_t maxreq=argc==3?hx_to_int(args[2],"hexoweb maxRequests must be an integer"):0;if(maxreq<0)hx_raise_error("hexoweb maxRequests cannot be negative");
    int server=socket(AF_INET,SOCK_STREAM,0);if(server<0)hx_raise_error("hexoweb: cannot create listening socket");
    int yes=1;setsockopt(server,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));struct sockaddr_in addr;memset(&addr,0,sizeof(addr));addr.sin_family=AF_INET;addr.sin_port=htons((uint16_t)port);/* INADDR_LOOPBACK is hidden by some Darwin feature-test profiles when
       _POSIX_C_SOURCE is enabled. 127.0.0.1 is the IPv4 loopback address. */
    addr.sin_addr.s_addr=htonl(UINT32_C(0x7f000001));
    if(bind(server,(struct sockaddr*)&addr,sizeof(addr))<0){close(server);char m[256];snprintf(m,sizeof(m),"hexoweb: bind failed: %s",strerror(errno));hx_raise_error(m);}
    if(listen(server,32)<0){close(server);hx_raise_error("hexoweb: listen failed");}
    int64_t served=0;
    while(!maxreq||served<maxreq){int client=accept(server,NULL,NULL);if(client<0){if(errno==EINTR)continue;close(server);hx_raise_error("hexoweb: accept failed");}
        struct timeval tv={10,0};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&tv,sizeof(tv));handle_http_client(client,args[1]);shutdown(client,SHUT_RDWR);close(client);++served;}
    close(server);return HX_INT_VALUE(served);
}
#else
HX_NATIVE(nat_web_serve){(void)args;(void)argc;(void)fn;hx_raise_error("hexoweb server is not supported on this platform build");}
#endif
HX_NATIVE(nat_web_html_escape) {
    (void)fn;if(argc!=1)hx_raise_error("hexoweb.escapeHTML expects one string");HxString*s=hx_as_string(args[0]);if(!s)hx_raise_error("hexoweb.escapeHTML expects a string");HxBuffer b={0};
    for(size_t i=0;i<s->length;++i){switch(s->bytes[i]){case '&':buffer_cstr(&b,"&amp;");break;case '<':buffer_cstr(&b,"&lt;");break;case '>':buffer_cstr(&b,"&gt;");break;case '"':buffer_cstr(&b,"&quot;");break;case '\'':buffer_cstr(&b,"&#39;");break;default:buffer_bytes(&b,&s->bytes[i],1);}}
    return buffer_value(&b);
}
HX_NATIVE(nat_web_response) {
    (void)fn;if(argc<1||argc>4)hx_raise_error("hexoweb.response expects body, optional status, contentType and headers");if(args[0].tag!=HX_STRING)hx_raise_error("hexoweb.response body must be a string");
    int64_t status=argc>1?hx_to_int(args[1],"response status must be integer"):200;if(status<100||status>599)hx_raise_error("HTTP status must be between 100 and 599");HxValue type=argc>2?args[2]:hx_make_string("text/html; charset=utf-8");if(type.tag!=HX_STRING)hx_raise_error("response contentType must be a string");HxString *ct=(HxString*)(uintptr_t)type.payload;if(ct->length>200)hx_raise_error("response contentType is too long");for(size_t i=0;i<ct->length;++i)if(ct->bytes[i]=='\r'||ct->bytes[i]=='\n')hx_raise_error("invalid response contentType");HxValue a=hx_make_array();hx_array_push(a,HX_INT_VALUE(status));hx_array_push(a,type);hx_array_push(a,args[0]);if(argc>3)hx_array_push(a,args[3]);return a;
}
HX_NATIVE(nat_web_url_encode) {
    (void)fn;if(argc!=1||args[0].tag!=HX_STRING)hx_raise_error("hexoweb.urlEncode expects a string");HxString*s=(HxString*)(uintptr_t)args[0].payload;HxBuffer b={0};static const char h[]="0123456789ABCDEF";
    for(size_t i=0;i<s->length;++i){unsigned char c=s->bytes[i];if(isalnum(c)||c=='-'||c=='_'||c=='.'||c=='~')buffer_bytes(&b,(char*)&s->bytes[i],1);else{char x[3]={'%',h[c>>4],h[c&15]};buffer_bytes(&b,x,3);}}return buffer_value(&b);
}
HX_NATIVE(nat_web_url_decode) {
    (void)fn;if(argc!=1||args[0].tag!=HX_STRING)hx_raise_error("hexoweb.urlDecode expects a string");HxString*s=(HxString*)(uintptr_t)args[0].payload;HxBuffer b={0};
    for(size_t i=0;i<s->length;++i){char c=s->bytes[i];if(c=='+')c=' ';else if(c=='%'){if(i+2>=s->length)hx_raise_error("invalid percent escape in URL");int a=hex_digit(s->bytes[i+1]),d=hex_digit(s->bytes[i+2]);if(a<0||d<0)hx_raise_error("invalid percent escape in URL");c=(char)((a<<4)|d);i+=2;}buffer_bytes(&b,&c,1);}return buffer_value(&b);
}
