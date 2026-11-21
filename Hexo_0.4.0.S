// ============================================================================
// Hexo - a gradually-typed scripting language, written in x86-64 assembly.
//
// One source file, three operating systems (x86-64 only):
//
//   Linux    gcc   main.S -o hexo -lm
//   macOS    clang main.S -o hexo            (on Apple Silicon add -arch x86_64:
//                                             the binary runs through Rosetta 2)
//   Windows  gcc   main.S -o hexo.exe        (MinGW-w64;  or cross-compile with
//                                             x86_64-w64-mingw32-gcc)
//
// Syntax: GNU as / LLVM, Intel flavour, run through the C preprocessor (.S).
// Internal convention (identical on all OSes): arguments in rdi rsi rdx rcx
// r8 r9, results in rax:rdx, callee-saved rbx rbp r12-r15. Only calls into the
// C library go through CALLC, which adapts to the host ABI (System V / Win64).
// A Hexo value is a pair (tag, payload) = (rax, rdx) in registers, 16 bytes
// in memory.
//
// Memory: values are never garbage-collected, except that the scopes of a
// function call are reclaimed in O(1) when the call created no closure.
//
// Modules:
//   import "path/to/module.hexo" as module;
//   from "path/to/module.hexo" import functionName, ClassName;
// Module paths are resolved relative to the process working directory.
// Each module is executed once and cached; imported functions/classes retain
// their defining module environment.
// ============================================================================

#if defined(__APPLE__)
#  define OS_MAC 1
#  define SYM(x) _##x
#  define RO_SECT __TEXT,__cstring,cstring_literals
#  define TB_SECT __TEXT,__const
#  define DA_SECT __DATA,__data
#elif defined(_WIN32)
#  define OS_WIN 1
#  define SYM(x) x
#  define RO_SECT .rdata,"dr"
#  define TB_SECT .rdata,"dr"
#  define DA_SECT .data
#else
#  define OS_LINUX 1
#  define SYM(x) x
#  define RO_SECT .rodata.str1.1,"aMS",@progbits,1
#  define TB_SECT .rodata
#  define DA_SECT .data
#endif

.intel_syntax noprefix

// Export the runtime allocation/value helpers used by native C extensions.
.global hx_alloc, str_new, arr_new, arr_push, hx_raise_error, hx_call_callback
#if defined(OS_MAC)
// Mach-O C symbols carry a leading underscore; these preserve the SysV ABI.
.global _hx_alloc, _str_new, _arr_new, _arr_push, _hx_raise_error, _hx_call_callback
_hx_alloc:         jmp hx_alloc
_str_new:          jmp str_new
_arr_new:          jmp arr_new
_arr_push:         jmp arr_push
_hx_raise_error:   jmp hx_raise_error
_hx_call_callback: jmp hx_call_callback
#endif

#define G(x)   qword ptr [rip + x]
#define GD(x)  dword ptr [rip + x]
#define GB(x)  byte ptr [rip + x]
#define L(n)   qword ptr [rbp - 48 - 8*(n)]
#define LD(n)  dword ptr [rbp - 48 - 8*(n)]
#define LA(n)  [rbp - 48 - 8*(n)]

// ---------------------------------------------------------------- constants
.equ T_NIL, 0
.equ T_BOOL, 1
.equ T_INT, 2
.equ T_FLOAT, 3
.equ T_STR, 4
.equ T_ARR, 5
.equ T_FN, 6
.equ T_CLS, 7
.equ T_INST, 8
.equ T_MOD, 9
.equ T_PTR, 10

.equ ARENA_CHUNK, 4194304
.equ OUT_CAP, 65536

// ------------------------------------------------------------------ macros
.macro TEXT
  .text
.endm
.macro DATA
  .section DA_SECT
.endm
.macro TABLE
  .section TB_SECT
.endm

// Call into the C library. Arguments are already in the System V registers.
.macro CALLC fn
#if defined(OS_WIN)
  mov r9, rcx
  mov r8, rdx
  mov rdx, rsi
  mov rcx, rdi
  sub rsp, 32
  call SYM(\fn)
  add rsp, 32
#elif defined(OS_LINUX)
  xor eax, eax
  call \fn@PLT
#else
  xor eax, eax
  call SYM(\fn)
#endif
.endm

// Function with a standard frame: all callee-saved registers are preserved,
// locals live at L(0)..L(n-1), rsp stays 16-byte aligned.
.macro FN name, nloc=0
  .balign 16
\name:
  push rbp
  mov rbp, rsp
  push rbx
  push r12
  push r13
  push r14
  push r15
  sub rsp, (((\nloc)*8 + 15) & -16) + 8
.endm

.macro EPI
  lea rsp, [rbp - 40]
  pop r15
  pop r14
  pop r13
  pop r12
  pop rbx
  pop rbp
  ret
.endm

// Inline string literal: LEAS reg, "text"
.macro LEAS reg, str
  .section RO_SECT
  99: .asciz "\str"
  .text
  lea \reg, [rip + 99b]
.endm

// Global 8-byte variable
.macro GV name, init=0
  .balign 8
\name: .quad \init
.endm

// Known names (interned at start-up so each gets a small integer id).
.set KCNT, 1
.macro KN id, text
  .set \id, KCNT
  .set KCNT, KCNT + 1
  .asciz "\text"
.endm

// ------------------------------------------------------------- known names
TABLE
known_names:
// keywords: order must match the keyword tokens TK_LET..TK_NIL
KN K_let, "let"
KN K_const, "const"
KN K_fn, "fn"
KN K_return, "return"
KN K_if, "if"
KN K_else, "else"
KN K_while, "while"
KN K_for, "for"
KN K_in, "in"
KN K_break, "break"
KN K_continue, "continue"
KN K_class, "class"
KN K_struct, "struct"
KN K_extends, "extends"
KN K_super, "super"
KN K_this, "this"
KN K_static, "static"
KN K_is, "is"
KN K_try, "try"
KN K_catch, "catch"
KN K_finally, "finally"
KN K_throw, "throw"
KN K_true, "true"
KN K_false, "false"
KN K_nil, "nil"
KN K_import, "import"
KN K_from, "from"
KN K_as, "as"
KN K_public, "public"
KN K_private, "private"
// type names (also used as builtin function names)
KN K_int, "int"
KN K_float, "float"
KN K_number, "number"
KN K_string, "string"
KN K_bool, "bool"
KN K_any, "any"
KN K_void, "void"
KN K_function, "function"
KN K_ptr, "ptr"
KN K_array, "array"
KN K_type, "type"
KN K_init, "init"
KN K_toString, "toString"
KN K_length, "length"
// array methods
KN K_push, "push"
KN K_pop, "pop"
KN K_map, "map"
KN K_filter, "filter"
KN K_forEach, "forEach"
KN K_reduce, "reduce"
KN K_find, "find"
KN K_join, "join"
KN K_contains, "contains"
KN K_indexOf, "indexOf"
KN K_slice, "slice"
KN K_reverse, "reverse"
KN K_sort, "sort"
// string methods
KN K_upper, "upper"
KN K_lower, "lower"
KN K_trim, "trim"
KN K_startsWith, "startsWith"
KN K_endsWith, "endsWith"
KN K_substring, "substring"
KN K_split, "split"
KN K_replace, "replace"
KN K_repeat, "repeat"
// global functions
KN K_print, "print"
KN K_input, "input"
KN K_len, "len"
KN K_typeof, "typeof"
KN K_range, "range"
KN K_abs, "abs"
KN K_sqrt, "sqrt"
KN K_pow, "pow"
KN K_floor, "floor"
KN K_ceil, "ceil"
KN K_round, "round"
KN K_min, "min"
KN K_max, "max"
KN K_sin, "sin"
KN K_cos, "cos"
KN K_tan, "tan"
KN K_asin, "asin"
KN K_acos, "acos"
KN K_atan, "atan"
KN K_atan2, "atan2"
KN K_sinh, "sinh"
KN K_cosh, "cosh"
KN K_tanh, "tanh"
KN K_log, "log"
KN K_log10, "log10"
KN K_exp, "exp"
KN K_fmod, "fmod"
KN K_hypot, "hypot"
KN K_envGet, "envGet"
KN K_fileExists, "fileExists"
KN K_readText, "readText"
KN K_writeText, "writeText"
KN K_appendText, "appendText"
KN K_removeFile, "removeFile"
KN K_renameFile, "renameFile"
KN K_currentDirectory, "currentDirectory"
KN K_clock, "clock"
KN K_assert, "assert"
KN K_random, "random"
KN K_randomInt, "randomInt"
KN K_seedRandom, "seedRandom"
KN K_randomChoice, "randomChoice"
KN K_exit, "exit"
// Data, database, web and graphics native module functions.
KN K_jsonParse, "jsonParse"
KN K_jsonStringify, "jsonStringify"
KN K_jsonObject, "jsonObject"
KN K_jsonArray, "jsonArray"
KN K_jsonGet, "jsonGet"
KN K_jsonSet, "jsonSet"
KN K_jsonHas, "jsonHas"
KN K_jsonKeys, "jsonKeys"
KN K_jsonIsObject, "jsonIsObject"
KN K_jsonRemove, "jsonRemove"
KN K_csvParse, "csvParse"
KN K_csvStringify, "csvStringify"
KN K_tabularFromRows, "tabularFromRows"
KN K_tabularReadCSV, "tabularReadCSV"
KN K_tabularToCSV, "tabularToCSV"
KN K_tabularWriteCSV, "tabularWriteCSV"
KN K_tabularColumns, "tabularColumns"
KN K_tabularRows, "tabularRows"
KN K_tabularShape, "tabularShape"
KN K_tabularHead, "tabularHead"
KN K_tabularColumn, "tabularColumn"
KN K_tabularSelect, "tabularSelect"
KN K_tabularSortBy, "tabularSortBy"
KN K_tabularFilterEquals, "tabularFilterEquals"
KN K_tabularInferTypes, "tabularInferTypes"
KN K_sqliteOpen, "sqliteOpen"
KN K_sqliteClose, "sqliteClose"
KN K_sqliteExec, "sqliteExec"
KN K_sqliteQuery, "sqliteQuery"
KN K_sqlitePrepare, "sqlitePrepare"
KN K_sqliteBindInt, "sqliteBindInt"
KN K_sqliteBindFloat, "sqliteBindFloat"
KN K_sqliteBindText, "sqliteBindText"
KN K_sqliteBindNull, "sqliteBindNull"
KN K_sqliteStep, "sqliteStep"
KN K_sqliteColumnCount, "sqliteColumnCount"
KN K_sqliteColumnName, "sqliteColumnName"
KN K_sqliteColumn, "sqliteColumn"
KN K_sqliteColumnType, "sqliteColumnType"
KN K_sqliteReset, "sqliteReset"
KN K_sqliteFinalize, "sqliteFinalize"
KN K_sqliteChanges, "sqliteChanges"
KN K_sqliteLastInsertId, "sqliteLastInsertId"
KN K_mysqlOpen, "mysqlOpen"
KN K_mysqlClose, "mysqlClose"
KN K_mysqlExec, "mysqlExec"
KN K_mysqlQuery, "mysqlQuery"
KN K_mysqlError, "mysqlError"
KN K_mysqlPrepare, "mysqlPrepare"
KN K_mysqlStmtBindInt, "mysqlStmtBindInt"
KN K_mysqlStmtBindFloat, "mysqlStmtBindFloat"
KN K_mysqlStmtBindText, "mysqlStmtBindText"
KN K_mysqlStmtBindNull, "mysqlStmtBindNull"
KN K_mysqlStmtExecute, "mysqlStmtExecute"
KN K_mysqlStmtQuery, "mysqlStmtQuery"
KN K_mysqlStmtClose, "mysqlStmtClose"
KN K_webServe, "webServe"
KN K_htmlEscape, "htmlEscape"
KN K_webResponse, "webResponse"
KN K_webUrlEncode, "webUrlEncode"
KN K_webUrlDecode, "webUrlDecode"
KN K_gameInit, "gameInit"
KN K_gameQuit, "gameQuit"
KN K_gamePollEvent, "gamePollEvent"
KN K_gameShouldClose, "gameShouldClose"
KN K_gameSetTitle, "gameSetTitle"
KN K_gameClear, "gameClear"
KN K_gamePresent, "gamePresent"
KN K_gameDrawLine, "gameDrawLine"
KN K_gameDrawRect, "gameDrawRect"
KN K_gameDrawCircle, "gameDrawCircle"
KN K_gameKeyDown, "gameKeyDown"
KN K_gameMouse, "gameMouse"
KN K_gameTicks, "gameTicks"
KN K_gameDelay, "gameDelay"
KN K_gameWindowSize, "gameWindowSize"
KN K_gameBackend, "gameBackend"
KN K_simpleInit, "simpleGameInit"
KN K_simpleClose, "simpleGameClose"
KN K_simpleShouldClose, "simpleGameShouldClose"
KN K_simpleBegin, "simpleGameBegin"
KN K_simpleEnd, "simpleGameEnd"
KN K_simpleClear, "simpleGameClear"
KN K_simpleRect, "simpleGameRect"
KN K_simpleLine, "simpleGameLine"
KN K_simpleCircle, "simpleGameCircle"
KN K_simpleText, "simpleGameText"
KN K_simpleKeyDown, "simpleGameKeyDown"
KN K_simpleKeyPressed, "simpleGameKeyPressed"
KN K_simpleMouse, "simpleGameMouse"
KN K_simpleFrameTime, "simpleGameFrameTime"
KN K_simpleFps, "simpleGameFps"
KN K_simpleTargetFps, "simpleGameTargetFps"
KN K_simpleTextureLoad, "simpleGameTextureLoad"
KN K_simpleTextureDraw, "simpleGameTextureDraw"
KN K_simpleTextureUnload, "simpleGameTextureUnload"
KN K_simpleSetTitle, "simpleGameSetTitle"
KN K_simpleFullscreen, "simpleGameFullscreen"
KN K_simpleBackend, "simpleGameBackend"
KN K_3dBegin, "game3DBegin"
KN K_3dEnd, "game3DEnd"
KN K_3dCube, "game3DCube"
KN K_3dSphere, "game3DSphere"
KN K_3dGrid, "game3DGrid"
KN K_PI, "PI"
KN K_E, "E"
KN K_module, "module"
.byte 0
.set K_LAST, KCNT - 1

// ------------------------------------------------------------------ globals
DATA
GV arena_ptr
GV arena_end
GV intern_tab
GV intern_cap
GV intern_cnt
GV out_buf
GV out_len
GV try_top
GV exc_kind          // 0 = runtime/type/syntax error, 1 = user `throw`
GV exc_name          // C string: "Runtime error", ...
GV exc_tag
GV exc_pay
GV exc_line
GV cur_line
GV str_empty
GV prog_args
.balign 8
tn_table: .space 88   // String* of each type name, indexed by tag
.balign 8
known_ptrs: .space 2048   // String* of each known name, indexed by id

// =================================================================== MEMORY
TEXT
.balign 16
hx_alloc:                      // rdi = size -> rax = zeroed memory (never freed)
  add rdi, 15
  and rdi, -16
  mov rax, G(arena_ptr)
  lea rcx, [rax + rdi]
  cmp rcx, G(arena_end)
  ja 1f
  mov G(arena_ptr), rcx
  ret
1:
  push rbx
  mov rbx, rdi
  cmp rdi, 262144
  jae 2f
  mov edi, 1
  mov esi, ARENA_CHUNK
  CALLC calloc
  test rax, rax
  jz hx_oom
  lea rcx, [rax + rbx]
  mov G(arena_ptr), rcx
  lea rcx, [rax + ARENA_CHUNK]
  mov G(arena_end), rcx
  pop rbx
  ret
2:
  mov edi, 1
  mov rsi, rbx
  CALLC calloc
  test rax, rax
  jz hx_oom
  pop rbx
  ret

.balign 16
hx_oom:
  LEAS rdi, "Out of memory\n"
  mov esi, 14
  call err_write
  mov edi, 1
  CALLC exit

// ================================================================== OUTPUT
// stdout goes through our own buffer and is written with write(2) so no
// FILE* symbol (which differs per OS) is ever needed.
FN out_flush, 1
  mov rbx, G(out_buf)
  mov r12, G(out_len)
1:
  test r12, r12
  jle 2f
  mov edi, 1
  mov rsi, rbx
  mov rdx, r12
  CALLC write
  test rax, rax
  jle 2f
  add rbx, rax
  sub r12, rax
  jmp 1b
2:
  mov G(out_len), 0
  EPI

FN out_put, 1                  // rdi = ptr, rsi = len
  mov rbx, rdi
  mov r12, rsi
  mov rax, G(out_len)
  add rax, r12
  cmp rax, OUT_CAP
  jbe 1f
  call out_flush
  cmp r12, OUT_CAP
  jbe 1f
  mov edi, 1
  mov rsi, rbx
  mov rdx, r12
  CALLC write
  jmp 2f
1:
  mov rdi, G(out_buf)
  add rdi, G(out_len)
  mov rsi, rbx
  mov rdx, r12
  CALLC memcpy
  add G(out_len), r12
2:
  EPI

FN out_putc, 1                 // edi = byte
  mov L(0), rdi
  lea rdi, [rbp - 48]
  mov esi, 1
  call out_put
  EPI

FN out_puts, 0                 // rdi = C string
  mov rbx, rdi
  CALLC strlen
  mov rdi, rbx
  mov rsi, rax
  call out_put
  EPI

FN out_putstr, 0               // rdi = String*
  lea rsi, [rdi + 16]
  mov rdx, [rdi]
  mov rdi, rsi
  mov rsi, rdx
  call out_put
  EPI

FN err_write, 1                // rdi = ptr, rsi = len  (stderr, after flushing stdout)
  mov rbx, rdi
  mov r12, rsi
  call out_flush
1:
  test r12, r12
  jle 2f
  mov edi, 2
  mov rsi, rbx
  mov rdx, r12
  CALLC write
  test rax, rax
  jle 2f
  add rbx, rax
  sub r12, rax
  jmp 1b
2:
  EPI

// =================================================================== STRINGS
// String object: +0 len, +8 id (known-name id or 0), +16 chars, NUL-terminated.
FN str_alloc, 0                // rdi = len -> rax = String* with zeroed chars
  mov rbx, rdi
  lea rdi, [rdi + 17]
  call hx_alloc
  mov [rax], rbx
  EPI

FN str_new, 1                  // rdi = ptr, rsi = len -> rax = String* (copy)
  mov rbx, rdi
  mov r12, rsi
  mov rdi, rsi
  call str_alloc
  mov r13, rax
  lea rdi, [rax + 16]
  mov rsi, rbx
  mov rdx, r12
  CALLC memcpy
  mov rax, r13
  EPI

FN cstr_new, 0                 // rdi = C string -> rax = String*
  mov rbx, rdi
  CALLC strlen
  mov rdi, rbx
  mov rsi, rax
  call str_new
  EPI

FN str_concat, 1               // rdi = a, rsi = b -> rax
  mov rbx, rdi
  mov r12, rsi
  mov rdi, [rbx]
  add rdi, [r12]
  call str_alloc
  mov r13, rax
  lea rdi, [rax + 16]
  lea rsi, [rbx + 16]
  mov rdx, [rbx]
  CALLC memcpy
  lea rdi, [r13 + 16]
  add rdi, [rbx]
  lea rsi, [r12 + 16]
  mov rdx, [r12]
  CALLC memcpy
  mov rax, r13
  EPI

FN str_eq, 0                   // rdi = a, rsi = b -> eax
  cmp rdi, rsi
  je 1f
  mov rdx, [rdi]
  cmp rdx, [rsi]
  jne 2f
  mov rbx, rdx
  add rdi, 16
  add rsi, 16
  CALLC memcmp
  test eax, eax
  jnz 2f
1:
  mov eax, 1
  EPI
2:
  xor eax, eax
  EPI

// FNV-1a hash of rdi[0..rsi) -> rax
.balign 16
hx_hash:
  mov rax, 0xcbf29ce484222325
  mov rcx, 0x100000001b3
1:
  test rsi, rsi
  jz 2f
  movzx edx, byte ptr [rdi]
  xor rax, rdx
  imul rax, rcx
  inc rdi
  dec rsi
  jmp 1b
2:
  ret

FN str_intern, 6               // rdi = ptr, rsi = len -> rax = canonical String*
  mov rbx, rdi
  mov r12, rsi
  call hx_hash                 // rdi/rsi already hold ptr,len
  mov r13, rax                 // hash
  mov r14, G(intern_cap)
  lea r15, [r14 - 1]           // mask
  mov rcx, r13
  and rcx, r15
  mov L(0), rcx                // idx
1:
  mov rcx, L(0)
  mov rax, G(intern_tab)
  mov rax, [rax + rcx*8]
  test rax, rax
  jz 3f
  cmp [rax], r12
  jne 2f
  mov L(1), rax
  lea rdi, [rax + 16]
  mov rsi, rbx
  mov rdx, r12
  CALLC memcmp
  test eax, eax
  mov rax, L(1)
  jz 9f
2:
  mov rcx, L(0)
  inc rcx
  and rcx, r15
  mov L(0), rcx
  jmp 1b
3:                              // not found: create and insert
  mov rdi, rbx
  mov rsi, r12
  call str_new
  mov rcx, L(0)
  mov rdx, G(intern_tab)
  mov [rdx + rcx*8], rax
  mov L(1), rax
  inc G(intern_cnt)
  mov rcx, G(intern_cnt)
  shl rcx, 1
  cmp rcx, G(intern_cap)
  jbe 8f
  call intern_grow
8:
  mov rax, L(1)
9:
  EPI

FN intern_grow, 2
  mov r12, G(intern_tab)
  mov r13, G(intern_cap)
  lea r14, [r13 * 2]
  mov rdi, r14
  mov esi, 8
  CALLC calloc
  test rax, rax
  jz hx_oom
  mov rbx, rax                 // new table
  lea r15, [r14 - 1]
  mov L(0), 0
1:
  mov rcx, L(0)
  cmp rcx, r13
  jae 4f
  mov rax, [r12 + rcx*8]
  test rax, rax
  jz 3f
  mov L(1), rax
  lea rdi, [rax + 16]
  mov rsi, [rax]
  call hx_hash
  and rax, r15
2:
  cmp qword ptr [rbx + rax*8], 0
  je 5f
  inc rax
  and rax, r15
  jmp 2b
5:
  mov rcx, L(1)
  mov [rbx + rax*8], rcx
3:
  inc L(0)
  jmp 1b
4:
  mov G(intern_tab), rbx
  mov G(intern_cap), r14
  mov rdi, r12
  CALLC free
  EPI

// ============================================================ VECTOR / BUILDER
// vec: +0 count, +8 cap, +16 data (qwords, malloc'd)
FN vec_push, 0                 // rdi = vec*, rsi = qword
  mov rbx, rdi
  mov r12, rsi
  mov rax, [rbx]
  cmp rax, [rbx + 8]
  jb 1f
  mov rcx, [rbx + 8]
  shl rcx, 1
  jnz 2f
  mov ecx, 8
2:
  mov [rbx + 8], rcx
  mov rdi, [rbx + 16]
  lea rsi, [rcx * 8]
  CALLC realloc
  test rax, rax
  jz hx_oom
  mov [rbx + 16], rax
1:
  mov rax, [rbx]
  mov rcx, [rbx + 16]
  mov [rcx + rax*8], r12
  inc qword ptr [rbx]
  EPI

FN vec_to_list, 0              // rdi = vec* -> rax = arena list {count, items...}; vec emptied
  mov rbx, rdi
  mov rdi, [rbx]
  lea rdi, [rdi*8 + 8]
  call hx_alloc
  mov r12, rax
  mov rcx, [rbx]
  mov [r12], rcx
  test rcx, rcx
  jz 1f
  lea rdi, [r12 + 8]
  mov rsi, [rbx + 16]
  lea rdx, [rcx * 8]
  CALLC memcpy
1:
  mov rdi, [rbx + 16]
  test rdi, rdi
  jz 2f
  CALLC free
2:
  xor eax, eax
  mov [rbx], rax
  mov [rbx + 8], rax
  mov [rbx + 16], rax
  mov rax, r12
  EPI

// string builder: +0 len, +8 cap, +16 buf (malloc'd)
.balign 16
sb_init:                       // rdi = sb
  xor eax, eax
  mov [rdi], rax
  mov [rdi + 8], rax
  mov [rdi + 16], rax
  ret

FN sb_reserve, 0               // rdi = sb, rsi = extra bytes
  mov rbx, rdi
  mov rax, [rbx]
  lea rax, [rax + rsi + 1]
  cmp rax, [rbx + 8]
  jbe 9f
  mov rcx, [rbx + 8]
  shl rcx, 1
  cmp rcx, 64
  jae 1f
  mov ecx, 64
1:
  cmp rcx, rax
  jae 2f
  mov rcx, rax
2:
  mov [rbx + 8], rcx
  mov rdi, [rbx + 16]
  mov rsi, rcx
  CALLC realloc
  test rax, rax
  jz hx_oom
  mov [rbx + 16], rax
9:
  EPI

FN sb_put, 0                   // rdi = sb, rsi = ptr, rdx = len
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov rsi, rdx
  call sb_reserve
  mov rdi, [rbx + 16]
  add rdi, [rbx]
  mov rsi, r12
  mov rdx, r13
  CALLC memcpy
  add [rbx], r13
  EPI

FN sb_putc, 1                  // rdi = sb, esi = byte
  mov L(0), rsi
  lea rsi, [rbp - 48]
  mov edx, 1
  call sb_put
  EPI

FN sb_putcs, 0                 // rdi = sb, rsi = C string
  mov rbx, rdi
  mov r12, rsi
  mov rdi, rsi
  CALLC strlen
  mov rdi, rbx
  mov rsi, r12
  mov rdx, rax
  call sb_put
  EPI

.balign 16
sb_putstr:                     // rdi = sb, rsi = String*
  mov rdx, [rsi]
  add rsi, 16
  jmp sb_put

FN sb_putint, 4                // rdi = sb, rsi = int64
  mov rbx, rdi
  mov rax, rsi
  lea r12, [rbp - 40]            // end (exclusive) of the 32-byte scratch area L(3)..L(0)
  mov r13, r12
  xor r14d, r14d
  test rax, rax
  jns 1f
  mov r14d, 1
  neg rax                      // INT64_MIN stays negative; handled by unsigned div
1:
  mov rcx, 10
2:
  xor edx, edx
  div rcx
  add dl, '0'
  dec r12
  mov [r12], dl
  test rax, rax
  jnz 2b
  test r14d, r14d
  jz 3f
  dec r12
  mov byte ptr [r12], '-'
3:
  mov rdi, rbx
  mov rsi, r12
  mov rdx, r13
  sub rdx, r12
  call sb_put
  EPI

FN sb_finish, 0                // rdi = sb -> rax = String* (sb freed)
  mov rbx, rdi
  mov rdi, [rbx + 16]
  mov rsi, [rbx]
  test rdi, rdi
  jnz 1f
  mov rdi, G(str_empty)
  add rdi, 16
1:
  call str_new
  mov r12, rax
  mov rdi, [rbx + 16]
  test rdi, rdi
  jz 2f
  CALLC free
2:
  mov rax, r12
  EPI

// =================================================== EXCEPTIONS (own setjmp)
// jmpbuf: +0 rbx +8 rbp +16 r12 +24 r13 +32 r14 +40 r15 +48 rsp +56 rip +64 prev
.balign 16
hx_try:                        // rdi = jmpbuf (lives in caller frame) -> 0, or 1 after a throw
  mov [rdi], rbx
  mov [rdi + 8], rbp
  mov [rdi + 16], r12
  mov [rdi + 24], r13
  mov [rdi + 32], r14
  mov [rdi + 40], r15
  lea rax, [rsp + 8]
  mov [rdi + 48], rax
  mov rax, [rsp]
  mov [rdi + 56], rax
  mov rax, G(try_top)
  mov [rdi + 64], rax
  mov G(try_top), rdi
  xor eax, eax
  ret

.balign 16
hx_try_end:                    // leave a protected region normally
  mov rax, G(try_top)
  mov rax, [rax + 64]
  mov G(try_top), rax
  ret

.balign 16
hx_throw:                      // exc_* globals already set
  mov rdi, G(try_top)
  mov rax, [rdi + 64]
  mov G(try_top), rax
  mov rbx, [rdi]
  mov rbp, [rdi + 8]
  mov r12, [rdi + 16]
  mov r13, [rdi + 24]
  mov r14, [rdi + 32]
  mov r15, [rdi + 40]
  mov rsp, [rdi + 48]
  mov eax, 1
  jmp qword ptr [rdi + 56]

.balign 16
raise_err:                     // rdi = kind C string, rsi = message String*, rdx = line
  mov G(exc_kind), 0
  mov G(exc_name), rdi
  mov G(exc_tag), T_STR
  mov G(exc_pay), rsi
  mov G(exc_line), rdx
  jmp hx_throw

.balign 16
raise_val:                     // rdi = tag, rsi = payload, rdx = line  (user `throw`)
  mov G(exc_kind), 1
  mov G(exc_tag), rdi
  mov G(exc_pay), rsi
  mov G(exc_line), rdx
  jmp hx_throw

FN fail_rt, 0                  // rdi = message C string -> Runtime error at cur_line
  call cstr_new
  mov rsi, rax
  LEAS rdi, "Runtime error"
  mov rdx, G(cur_line)
  call raise_err
  EPI

FN fail_ty, 0                  // rdi = message C string -> Type error at cur_line
  call cstr_new
  mov rsi, rax
  LEAS rdi, "Type error"
  mov rdx, G(cur_line)
  call raise_err
  EPI

FN fail_sb, 0                  // rdi = sb, rsi = kind C string, rdx = line
  mov rbx, rsi
  mov r12, rdx
  call sb_finish
  mov rdi, rbx
  mov rsi, rax
  mov rdx, r12
  call raise_err
  EPI

// "prefix" + name + "suffix"  (rdi = prefix, rsi = String* name, rdx = suffix, rcx = kind)
FN fail_n, 4                   // L(2)..L(0) = string builder, L(3) = spare
  mov rbx, rsi
  mov r12, rdx
  mov r13, rcx
  mov r14, rdi
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, r14
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, rbx
  call sb_putstr
  lea rdi, LA(2)
  mov rsi, r12
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  mov rdx, G(cur_line)
  call fail_sb
  EPI

.balign 16
fail_rt_n:                     // rdi = prefix, rsi = name, rdx = suffix
  LEAS rcx, "Runtime error"
  jmp fail_n

.balign 16
fail_ty_n:
  LEAS rcx, "Type error"
  jmp fail_n

.balign 16
syn_err:                       // rdi = message C string, rsi = line
  push rbx
  mov rbx, rsi
  call cstr_new
  mov rsi, rax
  LEAS rdi, "Syntax error"
  mov rdx, rbx
  call raise_err

// ================================================================ START-UP
FN rt_init, 3
  mov edi, 2048
  mov esi, 8
  mov G(intern_cap), 2048
  CALLC calloc
  test rax, rax
  jz hx_oom
  mov G(intern_tab), rax
  mov edi, OUT_CAP
  CALLC malloc
  test rax, rax
  jz hx_oom
  mov G(out_buf), rax
  // empty string first (K_empty is interned below as well; this one backs sb_finish)
  LEAS rdi, ""
  xor esi, esi
  call str_new
  mov G(str_empty), rax
  // intern all known names
  lea rbx, [rip + known_names]
  mov r12d, 1
1:
  cmp byte ptr [rbx], 0
  je 3f
  mov rdi, rbx
  CALLC strlen
  mov r13, rax
  mov rdi, rbx
  mov rsi, r13
  call str_intern
  mov [rax + 8], r12
  lea rcx, [rip + known_ptrs]
  mov [rcx + r12*8], rax
  lea rbx, [rbx + r13 + 1]
  inc r12
  jmp 1b
3:
  lea rcx, [rip + known_ptrs]
  lea rdx, [rip + tn_table]
  mov rax, [rcx + K_nil*8]
  mov [rdx + T_NIL*8], rax
  mov rax, [rcx + K_bool*8]
  mov [rdx + T_BOOL*8], rax
  mov rax, [rcx + K_int*8]
  mov [rdx + T_INT*8], rax
  mov rax, [rcx + K_float*8]
  mov [rdx + T_FLOAT*8], rax
  mov rax, [rcx + K_string*8]
  mov [rdx + T_STR*8], rax
  mov rax, [rcx + K_array*8]
  mov [rdx + T_ARR*8], rax
  mov rax, [rcx + K_function*8]
  mov [rdx + T_FN*8], rax
  mov rax, [rcx + K_class*8]
  mov [rdx + T_CLS*8], rax
  mov rax, [rcx + K_module*8]
  mov [rdx + T_MOD*8], rax
  mov rax, [rcx + K_ptr*8]
  mov [rdx + T_PTR*8], rax
  EPI
// ============================================================ FLOAT FORMATTING
// snprintf(buf, size, fmt, int prec, double d): the double is variadic, so the
// calling convention differs between System V and Win64.
.macro CALL_SNPRINTF           // rdi=buf rsi=size rdx=fmt ecx=prec xmm0=double
#if defined(OS_WIN)
  mov r9d, ecx
  mov r8, rdx
  mov rdx, rsi
  mov rcx, rdi
  movq rax, xmm0
  sub rsp, 48
  mov [rsp + 32], rax
  call SYM(snprintf)
  add rsp, 48
#elif defined(OS_LINUX)
  mov eax, 1
  call snprintf@PLT
#else
  mov eax, 1
  call SYM(snprintf)
#endif
.endm

// Appends the shortest representation of xmm0 that reads back identically
// (like JavaScript / Python), always showing a '.' or exponent (2.0, not 2).
FN fmt_float, 9                // rdi = sb, xmm0 = value; buffer = LA(7)..L(0) (64 bytes)
  mov r12, rdi
  movq r13, xmm0
  ucomisd xmm0, xmm0
  jp 8f                        // NaN
  mov rax, r13
  shl rax, 1
  mov rcx, 0xFFE0000000000000
  cmp rax, rcx
  je 9f                        // +/- infinity
  mov r14d, 15
1:
  lea rdi, LA(7)
  mov esi, 64
  LEAS rdx, "%.*g"
  mov ecx, r14d
  movq xmm0, r13
  CALL_SNPRINTF
  lea rdi, LA(7)
  xor esi, esi
  CALLC strtod
  movq rax, xmm0
  cmp rax, r13
  je 2f
  inc r14d
  cmp r14d, 17
  jbe 1b
2:
  lea rdi, LA(7)
  CALLC strlen
  mov rbx, rax                 // length
  xor r15d, r15d               // 1 once we saw '.' or 'e'
  mov r14, -1                  // index of 'e', if any
  xor ecx, ecx
3:
  cmp rcx, rbx
  jae 5f
  movzx eax, byte ptr [rbp - 48 - 8*7 + rcx]
  cmp al, '.'
  je 4f
  cmp al, 'e'
  je 6f
  inc rcx
  jmp 3b
6:
  mov r14, rcx                 // exponent marker
4:
  mov r15d, 1
  inc rcx
  jmp 3b
5:
  // Windows prints 3-digit exponents (1e+020): drop superfluous leading zeros
  cmp r14, -1
  je 11f
  lea rsi, [r14 + 2]
12:
  mov rax, rbx
  sub rax, rsi
  cmp rax, 2
  jbe 11f
  cmp byte ptr [rbp - 48 - 8*7 + rsi], '0'
  jne 11f
  mov rcx, rsi
13:
  cmp rcx, rbx
  jae 14f
  movzx eax, byte ptr [rbp - 48 - 8*7 + rcx + 1]
  mov [rbp - 48 - 8*7 + rcx], al
  inc rcx
  jmp 13b
14:
  dec rbx
  jmp 12b
11:
  mov rdi, r12
  lea rsi, LA(7)
  mov rdx, rbx
  call sb_put
  test r15d, r15d
  jnz 7f
  mov rdi, r12
  LEAS rsi, ".0"
  call sb_putcs
7:
  EPI
8:
  mov rdi, r12
  LEAS rsi, "nan"
  call sb_putcs
  EPI
9:
  mov rdi, r12
  test r13, r13
  js 10f
  LEAS rsi, "inf"
  call sb_putcs
  EPI
10:
  LEAS rsi, "-inf"
  call sb_putcs
  EPI
// ============================================================ SHARED CONSTANTS
.set TKC, 1
.macro TK name
  .set \name, TKC
  .set TKC, TKC + 1
.endm
TK TK_INT
TK TK_FLOAT
TK TK_STRING
TK TK_IDENT
// keywords: same order as K_let .. K_nil
TK TK_LET
TK TK_CONST
TK TK_FN
TK TK_RETURN
TK TK_IF
TK TK_ELSE
TK TK_WHILE
TK TK_FOR
TK TK_IN
TK TK_BREAK
TK TK_CONTINUE
TK TK_CLASS
TK TK_STRUCT
TK TK_EXTENDS
TK TK_SUPER
TK TK_THIS
TK TK_STATIC
TK TK_IS
TK TK_TRY
TK TK_CATCH
TK TK_FINALLY
TK TK_THROW
TK TK_TRUE
TK TK_FALSE
TK TK_NIL
TK TK_IMPORT
TK TK_FROM
TK TK_AS
TK TK_PUBLIC
TK TK_PRIVATE
// operators and punctuation
TK TK_PLUS
TK TK_MINUS
TK TK_STAR
TK TK_SLASH
TK TK_PERCENT
TK TK_PLUSPLUS
TK TK_MINUSMINUS
TK TK_EQUAL
TK TK_PLUSEQ
TK TK_MINUSEQ
TK TK_STAREQ
TK TK_SLASHEQ
TK TK_PERCENTEQ
TK TK_EQEQ
TK TK_BANGEQ
TK TK_LT
TK TK_LE
TK TK_GT
TK TK_GE
TK TK_BANG
TK TK_ANDAND
TK TK_OROR
TK TK_ARROW
TK TK_THIN
TK TK_AMP
TK TK_QUESTION
TK TK_COLON
TK TK_PIPE
TK TK_LPAREN
TK TK_RPAREN
TK TK_LBRACE
TK TK_RBRACE
TK TK_LBRACKET
TK TK_RBRACKET
TK TK_COMMA
TK TK_DOT
TK TK_SEMI
TK TK_END
.set TK_COUNT, TKC

// AST node: +0 kind (low 32 bits) | line (high 32 bits), +8.. fields A..F
.equ N_A, 8
.equ N_B, 16
.equ N_C, 24
.equ N_D, 32
.equ N_E, 40
.equ N_F, 48

// expression kinds
.equ EK_LIT, 1        // A=tag B=payload
.equ EK_VAR, 2        // A=name
.equ EK_ASSIGN, 3     // A=target B=op token (TK_EQUAL or TK_PLUS...) C=value
.equ EK_UPDATE, 4     // A=target B=increment C=prefix
.equ EK_UNARY, 5      // A=op token B=operand
.equ EK_BINARY, 6     // A=left B=op token C=right
.equ EK_LOGICAL, 7    // A=left B=op token C=right
.equ EK_TERNARY, 8    // A=cond B=then C=else
.equ EK_CALL, 9       // A=callee B=args list
.equ EK_GET, 10       // A=object B=name
.equ EK_INDEX, 11     // A=object B=index
.equ EK_THIS, 12
.equ EK_SUPER, 13     // A=method name
.equ EK_LAMBDA, 14    // A=function decl
.equ EK_ARRAY, 15     // A=elements list
.equ EK_IS, 16        // A=expr B=type
// statement kinds
.equ SK_EXPR, 32      // A=expr
.equ SK_VAR, 33       // A=name B=type C=init D=isConst
.equ SK_BLOCK, 34     // A=statements list B=needsScope
.equ SK_IF, 35        // A=cond B=then C=else
.equ SK_WHILE, 36     // A=cond B=body
.equ SK_FOR, 37       // A=init B=cond C=incr D=body
.equ SK_FORIN, 38     // A=var B=type C=isConst D=iterable E=body
.equ SK_RETURN, 39    // A=expr
.equ SK_BREAK, 40
.equ SK_CONTINUE, 41
.equ SK_FUNC, 42      // A=function decl
.equ SK_CLASS, 43     // A=class decl
.equ SK_TYPE, 44      // A=name B=type
.equ SK_THROW, 45     // A=expr
.equ SK_TRY, 46       // A=try block B=catch name C=catch block D=finally block
.equ SK_IMPORT, 47     // A=path String* B=alias String*
.equ SK_FROM_IMPORT, 48 // A=path String* B=list of imported names
// function decl (not a statement): A=name B=params C=return type D=body E=minArgs F=maxArgs
// param record: +0 name +8 type +16 default
// class decl: A=name B=super name C=isStruct D=fields list E=methods list
// field record: +0 name +8 type +16 init +24 flags(1 const, 2 static) +32 line
// method record: +0 function decl +8 isStatic
// type expressions
.equ TY_NAMED, 48     // A=builtin B=name
.equ TY_UNION, 49     // C=items list
.equ TY_ARRAY, 50     // D=element type
.equ TY_FUNC, 51      // C=param types list D=return type (or 0)
.equ BI_NONE, 0
.equ BI_INT, 1
.equ BI_FLOAT, 2
.equ BI_NUMBER, 3
.equ BI_STRING, 4
.equ BI_BOOL, 5
.equ BI_ANY, 6
.equ BI_VOID, 7
.equ BI_FUNCTION, 8
.equ BI_NIL, 9
.equ BI_PTR, 10

// statement results
.equ F_NORMAL, 0
.equ F_BREAK, 1
.equ F_CONT, 2
.equ F_RET, 3

// table (environment / instance / class member table)
.equ TB_COUNT, 0
.equ TB_CAP, 8
.equ TB_ENT, 16
.equ TB_LINK, 24      // env: parent;  instance: class
.equ TB_X, 32         // instance: "initializing" flag;  env: unused
// table entry (56 bytes)
.equ E_NAME, 0
.equ E_TAG, 8
.equ E_PAY, 16
.equ E_TYPE, 24
.equ E_FLAGS, 32
.equ E_TENV, 40
.equ E_OWNER, 48     // declaring class for private fields/static members
.equ E_SIZE, 56
.equ EF_CONST, 1
.equ EF_ALIAS, 2
.equ EF_STATIC, 4
.equ EF_METHOD, 8
.equ EF_PRIVATE, 16

// function object
.equ FO_KIND, 0       // 0 user, 1 native
.equ FO_NAME, 8
.equ FO_MIN, 16
.equ FO_MAX, 24       // -1 = variadic
.equ FO_CODE, 32      // user: function decl; native: code pointer
.equ FO_ENV, 40       // closure
.equ FO_INIT, 48      // user: is a constructor
.equ FO_BTAG, 56      // native method: bound receiver
.equ FO_BPAY, 64
.equ FO_SIZE, 80

// class object (a table + metadata)
.equ CL_SUPER, 24     // == TB_LINK
.equ CL_DECL, 32
.equ CL_DEFENV, 40
.equ CL_NAME, 48
.equ CL_STRUCT, 56
.equ CL_SIZE, 64
// instance object: table + class (TB_LINK) + initializing (TB_X)
.equ IN_SIZE, 48
// array object
.equ AR_LEN, 0
.equ AR_CAP, 8
.equ AR_DATA, 16
.equ AR_SIZE, 24
// ===================================================================== LEXER
// Token: +0 type, +8 String* (identifiers are interned), +16 line
DATA
GV tok_base
GV tok_count
GV tok_cap

TEXT
FN tok_add, 0                  // rdi = type, rsi = String* or 0, rdx = line
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov rax, G(tok_count)
  cmp rax, G(tok_cap)
  jb 1f
  mov rcx, G(tok_cap)
  shl rcx, 1
  jnz 2f
  mov ecx, 256
2:
  mov G(tok_cap), rcx
  mov rdi, G(tok_base)
  lea rsi, [rcx + rcx*2]
  shl rsi, 3
  CALLC realloc
  test rax, rax
  jz hx_oom
  mov G(tok_base), rax
1:
  mov rax, G(tok_count)
  lea rcx, [rax + rax*2]
  shl rcx, 3
  add rcx, G(tok_base)
  mov [rcx], rbx
  mov [rcx + 8], r12
  mov [rcx + 16], r13
  inc G(tok_count)
  EPI

TABLE
lex_ops2:                      // c1, c2, token
  .byte '=', '=', TK_EQEQ
  .byte '!', '=', TK_BANGEQ
  .byte '<', '=', TK_LE
  .byte '>', '=', TK_GE
  .byte '&', '&', TK_ANDAND
  .byte '|', '|', TK_OROR
  .byte '=', '>', TK_ARROW
  .byte '-', '>', TK_THIN
  .byte '+', '+', TK_PLUSPLUS
  .byte '-', '-', TK_MINUSMINUS
  .byte '+', '=', TK_PLUSEQ
  .byte '-', '=', TK_MINUSEQ
  .byte '*', '=', TK_STAREQ
  .byte '/', '=', TK_SLASHEQ
  .byte '%', '=', TK_PERCENTEQ
  .byte 0
lex_ops1:                      // c, token
  .byte '+', TK_PLUS
  .byte '-', TK_MINUS
  .byte '*', TK_STAR
  .byte '&', TK_AMP
  .byte '/', TK_SLASH
  .byte '%', TK_PERCENT
  .byte '=', TK_EQUAL
  .byte '!', TK_BANG
  .byte '<', TK_LT
  .byte '>', TK_GT
  .byte '|', TK_PIPE
  .byte '?', TK_QUESTION
  .byte ':', TK_COLON
  .byte '.', TK_DOT
  .byte ',', TK_COMMA
  .byte ';', TK_SEMI
  .byte '(', TK_LPAREN
  .byte ')', TK_RPAREN
  .byte '{', TK_LBRACE
  .byte '}', TK_RBRACE
  .byte '[', TK_LBRACKET
  .byte ']', TK_RBRACKET
  .byte 0

TEXT
// al = char -> eax = 1 if digit
.balign 16
lx_isdigit:
  xor ecx, ecx
  cmp al, '0'
  jb 1f
  cmp al, '9'
  ja 1f
  mov ecx, 1
1:
  mov eax, ecx
  ret

.balign 16
lx_isalpha:                    // al = char -> eax = 1 if [A-Za-z_]
  xor ecx, ecx
  cmp al, '_'
  je 2f
  cmp al, 'A'
  jb 1f
  cmp al, 'Z'
  jbe 2f
  cmp al, 'a'
  jb 1f
  cmp al, 'z'
  ja 1f
2:
  mov ecx, 1
1:
  mov eax, ecx
  ret

// Lexes rdi[0..rsi) (the buffer must be NUL-terminated) into the token array.
FN lex, 6                      // r12 = cursor, r13 = end, r14 = line, rbx = scratch
  mov r12, rdi
  lea r13, [rdi + rsi]
  mov r14d, 1
  mov G(tok_count), 0
  cmp rsi, 2
  jb lx_loop
  cmp word ptr [r12], 0x2123   // "#!" shebang
  jne lx_loop
1:
  cmp r12, r13
  jae lx_loop
  cmp byte ptr [r12], 10
  je lx_loop
  inc r12
  jmp 1b

lx_loop:
  cmp r12, r13
  jae lx_done
  movzx eax, byte ptr [r12]
  cmp al, 10
  jne 1f
  inc r14
  inc r12
  jmp lx_loop
1:
  cmp al, ' '
  je 2f
  cmp al, 9
  je 2f
  cmp al, 13
  jne 3f
2:
  inc r12
  jmp lx_loop
3:
  cmp al, '/'
  jne lx_token
  movzx ecx, byte ptr [r12 + 1]
  cmp cl, '/'
  jne 4f
5:                              // line comment
  cmp r12, r13
  jae lx_loop
  cmp byte ptr [r12], 10
  je lx_loop
  inc r12
  jmp 5b
4:
  cmp cl, '*'
  jne lx_token
  mov rbx, r14                  // block comment: remember the start line for errors
  add r12, 2
6:
  cmp r12, r13
  jae 7f
  cmp byte ptr [r12], '*'
  jne 8f
  cmp byte ptr [r12 + 1], '/'
  jne 8f
  add r12, 2
  jmp lx_loop
8:
  cmp byte ptr [r12], 10
  jne 9f
  inc r14
9:
  inc r12
  jmp 6b
7:
  LEAS rdi, "Unterminated block comment"
  mov rsi, rbx
  call syn_err

lx_token:
  movzx eax, byte ptr [r12]
  // ---- number: decimal, float or 0x hexadecimal integer
  call lx_isdigit
  test eax, eax
  jz lx_not_num
  cmp byte ptr [r12], '0'
  jne lx_decimal_number
  movzx eax, byte ptr [r12 + 1]
  cmp al, 'x'
  je lx_hex_number
  cmp al, 'X'
  jne lx_decimal_number
lx_hex_number:
  mov r15, r12
  add r12, 2
  xor ebx, ebx
lx_hex_scan:
  movzx eax, byte ptr [r12]
  cmp al, '0'
  jb lx_hex_alpha
  cmp al, '9'
  jbe lx_hex_digit
lx_hex_alpha:
  cmp al, 'a'
  jb lx_hex_upper
  cmp al, 'f'
  jbe lx_hex_digit
lx_hex_upper:
  cmp al, 'A'
  jb lx_hex_end
  cmp al, 'F'
  ja lx_hex_end
lx_hex_digit:
  inc ebx
  inc r12
  jmp lx_hex_scan
lx_hex_end:
  test ebx, ebx
  jnz lx_hex_emit
  LEAS rdi, "Expected at least one hexadecimal digit after 0x"
  mov rsi, r14
  call syn_err
lx_hex_emit:
  mov rdi, r15
  mov rsi, r12
  sub rsi, r15
  call str_new
  mov rsi, rax
  mov edi, TK_INT
  mov rdx, r14
  call tok_add
  jmp lx_loop
lx_decimal_number:
  mov r15, r12                  // start
  xor ebx, ebx                  // 1 if float
  inc r12
1:
  movzx eax, byte ptr [r12]
  call lx_isdigit
  test eax, eax
  jz 2f
  inc r12
  jmp 1b
2:
  cmp byte ptr [r12], '.'
  jne 3f
  movzx eax, byte ptr [r12 + 1]
  call lx_isdigit
  test eax, eax
  jz 3f
  mov ebx, 1
  inc r12
4:
  movzx eax, byte ptr [r12]
  call lx_isdigit
  test eax, eax
  jz 3f
  inc r12
  jmp 4b
3:
  movzx eax, byte ptr [r12]
  cmp al, 'e'
  je 5f
  cmp al, 'E'
  jne 8f
5:
  movzx eax, byte ptr [r12 + 1]
  cmp al, '+'
  je 6f
  cmp al, '-'
  je 6f
  call lx_isdigit
  test eax, eax
  jz 8f
  add r12, 2                     // e + first digit
  jmp 7f
6:
  movzx eax, byte ptr [r12 + 2]
  call lx_isdigit
  test eax, eax
  jz 8f
  add r12, 3                     // e + sign + first digit
7:
  mov ebx, 1
9:
  movzx eax, byte ptr [r12]
  call lx_isdigit
  test eax, eax
  jz 8f
  inc r12
  jmp 9b
8:
  mov rdi, r15
  mov rsi, r12
  sub rsi, r15
  call str_new
  mov rsi, rax
  mov edi, TK_INT
  test ebx, ebx
  jz 1f
  mov edi, TK_FLOAT
1:
  mov rdx, r14
  call tok_add
  jmp lx_loop

lx_not_num:
  movzx eax, byte ptr [r12]
  call lx_isalpha
  test eax, eax
  jz lx_not_ident
  mov r15, r12
1:
  movzx eax, byte ptr [r12]
  call lx_isdigit
  test eax, eax
  jnz 2f
  movzx eax, byte ptr [r12]
  call lx_isalpha
  test eax, eax
  jz 3f
2:
  inc r12
  jmp 1b
3:
  mov rdi, r15
  mov rsi, r12
  sub rsi, r15
  call str_intern
  mov rsi, rax
  mov rcx, [rax + 8]            // known-name id
  mov edi, TK_IDENT
  cmp rcx, K_let
  jb 4f
  cmp rcx, K_private
  ja 4f
  lea rdi, [rcx - K_let + TK_LET]
4:
  mov rdx, r14
  call tok_add
  jmp lx_loop

lx_not_ident:
  movzx eax, byte ptr [r12]
  cmp al, '"'
  je lx_string
  cmp al, 39
  jne lx_operator
lx_string:
  movzx ebx, byte ptr [r12]     // quote character
  mov r15, r14                  // line where the string starts
  inc r12
  lea rdi, LA(2)
  call sb_init
1:
  cmp r12, r13
  jae 8f
  movzx eax, byte ptr [r12]
  cmp eax, ebx
  je 6f
  cmp al, 10
  jne 2f
  inc r14
2:
  cmp al, '\\'
  jne 5f
  inc r12
  cmp r12, r13
  jae 8f
  movzx eax, byte ptr [r12]
  cmp al, 'n'
  jne 3f
  mov al, 10
  jmp 5f
3:
  cmp al, 't'
  jne 4f
  mov al, 9
  jmp 5f
4:
  cmp al, 'r'
  jne 7f
  mov al, 13
  jmp 5f
7:
  cmp al, '0'
  jne 9f
  xor eax, eax
  jmp 5f
9:
  cmp al, '\\'
  je 5f
  cmp al, '"'
  je 5f
  cmp al, 39
  je 5f
  mov r15d, eax
  lea rdi, LA(5)
  call sb_init
  lea rdi, LA(5)
  LEAS rsi, "Invalid escape sequence '"
  call sb_putcs
  lea rdi, LA(5)
  mov esi, '\\'
  call sb_putc
  lea rdi, LA(5)
  mov esi, r15d
  call sb_putc
  lea rdi, LA(5)
  mov esi, 39
  call sb_putc
  lea rdi, LA(5)
  LEAS rsi, "Syntax error"
  mov rdx, r14
  call fail_sb
5:
  lea rdi, LA(2)
  movzx esi, al
  call sb_putc
  inc r12
  jmp 1b
6:
  inc r12                       // closing quote
  lea rdi, LA(2)
  call sb_finish
  mov rsi, rax
  mov edi, TK_STRING
  mov rdx, r15
  call tok_add
  jmp lx_loop
8:
  LEAS rdi, "Unterminated string"
  mov rsi, r15
  call syn_err

lx_operator:
  movzx eax, byte ptr [r12]
  lea rsi, [rip + lex_ops2]
1:
  movzx ecx, byte ptr [rsi]
  test cl, cl
  jz 3f
  cmp cl, al
  jne 2f
  movzx edx, byte ptr [r12 + 1]
  cmp dl, [rsi + 1]
  jne 2f
  movzx r15d, byte ptr [rsi + 2]
  add r12, 2
  mov r10d, 2
  jmp 6f
2:
  add rsi, 3
  jmp 1b
3:
  lea rsi, [rip + lex_ops1]
4:
  movzx ecx, byte ptr [rsi]
  test cl, cl
  jz 5f
  cmp cl, al
  je 7f
  add rsi, 2
  jmp 4b
7:
  movzx r15d, byte ptr [rsi + 1]
  inc r12
  mov r10d, 1
6:
  mov rdi, r12                 // operator tokens carry their text (for error messages)
  sub rdi, r10
  mov rsi, r10
  call str_intern
  mov rsi, rax
  mov edi, r15d
  mov rdx, r14
  call tok_add
  jmp lx_loop
5:
  cmp al, '&'
  jne 8f
  LEAS rdi, "Unexpected '&' (did you mean '&&'?)"
  mov rsi, r14
  call syn_err
8:
  LEAS rdi, "Unexpected character"
  mov rsi, r14
  call syn_err

lx_done:
  mov edi, TK_END
  xor esi, esi
  mov rdx, r14
  call tok_add
  EPI
// ==================================================================== PARSER
DATA
GV p_pos
GV p_fdepth                    // > 0 inside a function body
GV p_ldepth                    // > 0 inside a loop body
GV p_closures                  // number of functions/lambdas/classes created so far

// NODE kind, line, a, b, c, d, e : allocate an AST node (a..e are operands)
.macro NODE kind, line, a=0, b=0, c=0, d=0, e=0
  mov rdi, \line
  shl rdi, 32
  or rdi, \kind
  mov rsi, \a
  mov rdx, \b
  mov rcx, \c
  mov r8, \d
  mov r9, \e
  call mk_node
.endm

TEXT
FN mk_node, 1                  // rdi = kind|line<<32, rsi..r9 = fields A..E
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov r15, r8
  mov L(0), r9
  mov edi, 64
  call hx_alloc
  mov [rax], rbx
  mov [rax + 8], r12
  mov [rax + 16], r13
  mov [rax + 24], r14
  mov [rax + 32], r15
  mov rcx, L(0)
  mov [rax + 40], rcx
  EPI

// ------------------------------------------------------------ token helpers
.balign 16
p_cur:                         // -> rax = current token
  mov rax, G(p_pos)
  lea rax, [rax + rax*2]
  shl rax, 3
  add rax, G(tok_base)
  ret

.balign 16
p_tokat:                       // rdi = index -> rax = token (clamped to the last one)
  mov rax, G(tok_count)
  dec rax
  cmp rdi, rax
  cmova rdi, rax
  lea rax, [rdi + rdi*2]
  shl rax, 3
  add rax, G(tok_base)
  ret

.balign 16
p_ahead:                       // rdi = offset -> rax = token at p_pos + offset
  add rdi, G(p_pos)
  jmp p_tokat

.balign 16
p_prev:
  mov rdi, G(p_pos)
  dec rdi
  jmp p_tokat

.balign 16
p_adv:                         // consume the current token, rax = that token
  call p_cur
  cmp qword ptr [rax], TK_END
  je 1f
  inc G(p_pos)
1:
  ret

.balign 16
p_match:                       // rdi = type -> eax = 1 if consumed
  call p_cur
  cmp [rax], rdi
  jne 1f
  inc G(p_pos)
  mov eax, 1
  ret
1:
  xor eax, eax
  ret

.balign 16
p_check:                       // rdi = type -> eax
  call p_cur
  xor ecx, ecx
  cmp [rax], rdi
  sete cl
  mov eax, ecx
  ret

.balign 16
p_atype:                       // rdi = offset -> rax = type of the token at p_pos + offset
  call p_ahead
  mov rax, [rax]
  ret

.balign 16
p_term:                        // optional ';'
  mov edi, TK_SEMI
  jmp p_match

FN p_finish, 0                 // rdi = message builder, rsi = token: add the position hint and raise
  mov rbx, rdi
  mov r12, rsi
  cmp qword ptr [r12], TK_END
  jne 1f
  mov rdi, rbx
  LEAS rsi, " (at end of input)"
  call sb_putcs
  jmp 3f
1:
  mov rsi, [r12 + 8]
  test rsi, rsi
  jz 3f
  mov rdi, rbx
  LEAS rsi, " (near '"
  call sb_putcs
  mov rdi, rbx
  mov rsi, [r12 + 8]
  call sb_putstr
  mov rdi, rbx
  LEAS rsi, "')"
  call sb_putcs
3:
  mov rdi, rbx
  LEAS rsi, "Syntax error"
  mov rdx, [r12 + 16]
  call fail_sb
  EPI

FN p_error, 3                  // rdi = message: syntax error at the current token
  mov r12, rdi
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, r12
  call sb_putcs
  call p_cur
  lea rdi, LA(2)
  mov rsi, rax
  call p_finish
  EPI

FN p_error_prev, 3             // rdi = message: syntax error at the token just consumed
  mov r12, rdi
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, r12
  call sb_putcs
  call p_prev
  lea rdi, LA(2)
  mov rsi, rax
  call p_finish
  EPI

FN p_expect, 0                 // rdi = token type, rsi = message -> rax = consumed token
  mov rbx, rsi
  call p_cur
  cmp [rax], rdi
  jne 1f
  call p_adv
  EPI
1:
  mov rdi, rbx
  call p_error
  EPI

// ---------------------------------------------------------------- type scan
// Scans a type starting at token index rdi WITHOUT building anything.
// Returns the index after the type, or -1 if there is no type there.
FN p_scan_primary, 0
  mov rbx, rdi
  call p_tokat
  mov rcx, [rax]
  cmp rcx, TK_NIL
  je 1f
  cmp rcx, TK_IDENT
  je 1f
  cmp rcx, TK_LPAREN
  je 2f
  cmp rcx, TK_FN
  je 3f
  jmp 9f
1:
  lea rax, [rbx + 1]
  EPI
2:                              // ( type )
  lea rdi, [rbx + 1]
  call p_scan_type
  test rax, rax
  js 9f
  mov rbx, rax
  mov rdi, rbx
  call p_tokat
  cmp qword ptr [rax], TK_RPAREN
  jne 9f
  lea rax, [rbx + 1]
  EPI
3:                              // fn ( types ) [-> type]
  lea rdi, [rbx + 1]
  call p_tokat
  cmp qword ptr [rax], TK_LPAREN
  jne 9f
  add rbx, 2
  mov rdi, rbx
  call p_tokat
  cmp qword ptr [rax], TK_RPAREN
  je 5f
4:
  mov rdi, rbx
  call p_scan_type
  test rax, rax
  js 9f
  mov rbx, rax
  mov rdi, rbx
  call p_tokat
  cmp qword ptr [rax], TK_COMMA
  jne 5f
  inc rbx
  jmp 4b
5:
  mov rdi, rbx
  call p_tokat
  cmp qword ptr [rax], TK_RPAREN
  jne 9f
  inc rbx
  mov rdi, rbx
  call p_tokat
  cmp qword ptr [rax], TK_THIN
  jne 6f
  lea rdi, [rbx + 1]
  call p_scan_type
  test rax, rax
  js 9f
  mov rbx, rax
6:
  mov rax, rbx
  EPI
9:
  mov rax, -1
  EPI

FN p_scan_postfix, 0
  call p_scan_primary
  test rax, rax
  js 9f
  mov rbx, rax
1:
  mov rdi, rbx
  call p_tokat
  mov rcx, [rax]
  cmp rcx, TK_LBRACKET
  jne 2f
  lea rdi, [rbx + 1]
  call p_tokat
  cmp qword ptr [rax], TK_RBRACKET
  jne 8f
  add rbx, 2
  jmp 1b
2:
  cmp rcx, TK_QUESTION
  jne 8f
  inc rbx
  jmp 1b
8:
  mov rax, rbx
9:
  EPI

FN p_scan_type, 0
  call p_scan_postfix
  test rax, rax
  js 9f
1:
  mov rbx, rax
  mov rdi, rax
  call p_tokat
  cmp qword ptr [rax], TK_PIPE
  jne 8f
  lea rdi, [rbx + 1]
  call p_scan_postfix
  test rax, rax
  js 9f
  jmp 1b
8:
  mov rax, rbx
9:
  EPI

// Does the upcoming text look like  `Type name` ?  (this is what lets `let` be
// optional:  int age = 10 ). strict: the name must be followed by = ; } end or
// a newline, so that  `a ? b : c`  is not mistaken for a declaration.
FN p_looks_typed, 0            // rdi = strict -> eax
  mov r12, rdi
  mov rdi, G(p_pos)
  call p_scan_type
  test rax, rax
  js 8f
  mov rbx, rax
  mov rdi, rbx
  call p_tokat
  cmp qword ptr [rax], TK_IDENT
  jne 8f
  mov r13, [rax + 16]
  lea rdi, [rbx - 1]
  call p_tokat
  cmp [rax + 16], r13
  jne 8f
  test r12, r12
  jz 9f
  lea rdi, [rbx + 1]
  call p_tokat
  mov rcx, [rax]
  cmp rcx, TK_EQUAL
  je 9f
  cmp rcx, TK_SEMI
  je 9f
  cmp rcx, TK_RBRACE
  je 9f
  cmp rcx, TK_END
  je 9f
  cmp [rax + 16], r13
  jne 9f
8:
  xor eax, eax
  EPI
9:
  mov eax, 1
  EPI

// -------------------------------------------------------------- type parse
FN mk_named_type, 0            // rdi = interned name -> TY_NAMED node
  mov rbx, rdi
  mov rcx, [rdi + 8]
  xor eax, eax
  cmp rcx, K_nil
  jne 1f
  mov eax, BI_NIL
  jmp 3f
1:
  cmp rcx, K_ptr
  jne .Lnamed_type_regular
  mov eax, BI_PTR
  jmp 3f
.Lnamed_type_regular:
  cmp rcx, K_int
  jb 3f
  cmp rcx, K_function
  ja 3f
  lea rax, [rcx - K_int + 1]
3:
  NODE TY_NAMED, 0, rax, rbx
  EPI

FN p_primary_type, 3           // rdi = allow nullable
  mov r12, rdi
  mov edi, TK_NIL
  call p_match
  test eax, eax
  jz 1f
  lea rcx, [rip + known_ptrs]
  mov rdi, [rcx + K_nil*8]
  call mk_named_type
  EPI
1:
  mov edi, TK_LPAREN
  call p_match
  test eax, eax
  jz 2f
  mov rdi, r12
  call p_parse_type
  mov rbx, rax
  mov edi, TK_RPAREN
  LEAS rsi, "Expected ')' in type"
  call p_expect
  mov rax, rbx
  EPI
2:
  mov edi, TK_FN
  call p_match
  test eax, eax
  jz 6f
  mov edi, TK_LPAREN
  LEAS rsi, "Expected '(' after 'fn' in function type"
  call p_expect
  lea rdi, LA(2)
  call sb_init
  mov edi, TK_RPAREN
  call p_check
  test eax, eax
  jnz 4f
3:
  mov edi, 1
  call p_parse_type
  lea rdi, LA(2)
  mov rsi, rax
  call vec_push
  mov edi, TK_COMMA
  call p_match
  test eax, eax
  jnz 3b
4:
  mov edi, TK_RPAREN
  LEAS rsi, "Expected ')' in function type"
  call p_expect
  xor ebx, ebx                 // return type
  mov edi, TK_THIN
  call p_match
  test eax, eax
  jz 5f
  mov rdi, r12
  call p_parse_type
  mov rbx, rax
5:
  lea rdi, LA(2)
  call vec_to_list
  NODE TY_FUNC, 0, 0, 0, rax, rbx
  EPI
6:
  mov edi, TK_IDENT
  call p_check
  test eax, eax
  jz 7f
  call p_adv
  mov rdi, [rax + 8]
  call mk_named_type
  EPI
7:
  LEAS rdi, "Expected a type"
  call p_error
  EPI

FN p_postfix_type, 0           // rdi = allow nullable
  mov r12, rdi
  call p_primary_type
  mov rbx, rax
1:
  mov edi, TK_LBRACKET
  call p_check
  test eax, eax
  jz 3f
  mov edi, 1
  call p_atype
  cmp eax, TK_RBRACKET
  jne 3f
  call p_adv
  call p_adv
  NODE TY_ARRAY, 0, 0, 0, 0, rbx
  mov rbx, rax
  jmp 1b
3:
  test r12, r12
  jz 8f
  mov edi, TK_QUESTION
  call p_check
  test eax, eax
  jz 8f
  call p_adv
  mov edi, 24                  // T? == union { T, nil }
  call hx_alloc
  mov qword ptr [rax], 2
  mov [rax + 8], rbx
  mov r13, rax
  lea rcx, [rip + known_ptrs]
  mov rdi, [rcx + K_nil*8]
  call mk_named_type
  mov [r13 + 16], rax
  NODE TY_UNION, 0, 0, 0, r13
  mov rbx, rax
  jmp 1b
8:
  mov rax, rbx
  EPI

FN p_parse_type, 3             // rdi = allow nullable ('?' suffix) -> type node
  mov r12, rdi
  call p_postfix_type
  mov rbx, rax
  mov edi, TK_PIPE
  call p_check
  test eax, eax
  jz 9f
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, rbx
  call vec_push
1:
  mov edi, TK_PIPE
  call p_match
  test eax, eax
  jz 2f
  mov rdi, r12
  call p_postfix_type
  lea rdi, LA(2)
  mov rsi, rax
  call vec_push
  jmp 1b
2:
  lea rdi, LA(2)
  call vec_to_list
  NODE TY_UNION, 0, 0, 0, rax
  EPI
9:
  mov rax, rbx
  EPI

// -------------------------------------------------------------- expressions
.balign 16
p_binprec:                     // edi = token type -> eax = binary operator precedence (0 = none)
  mov eax, 1
  cmp edi, TK_OROR
  je 9f
  mov eax, 2
  cmp edi, TK_ANDAND
  je 9f
  mov eax, 3
  cmp edi, TK_EQEQ
  je 9f
  cmp edi, TK_BANGEQ
  je 9f
  mov eax, 4
  cmp edi, TK_IS
  je 9f
  cmp edi, TK_LT
  jb 1f
  cmp edi, TK_GE
  jbe 9f
1:
  mov eax, 5
  cmp edi, TK_PLUS
  je 9f
  cmp edi, TK_MINUS
  je 9f
  mov eax, 6
  cmp edi, TK_STAR
  jb 2f
  cmp edi, TK_PERCENT
  jbe 9f
2:
  xor eax, eax
9:
  ret

FN parse_int, 3                // rdi = String* decimal/hex digits -> signed int64
  mov rbx, rdi
  lea rsi, [rdi + 16]
  mov rcx, [rdi]
  mov r15, 10
  cmp rcx, 2
  jb .Lparse_dec
  cmp byte ptr [rsi], '0'
  jne .Lparse_dec
  movzx edx, byte ptr [rsi + 1]
  cmp dl, 'x'
  je .Lparse_hex
  cmp dl, 'X'
  jne .Lparse_dec
.Lparse_hex:
  mov r15, 16
  add rsi, 2
  sub rcx, 2
.Lparse_dec:
  xor eax, eax
1:
  test rcx, rcx
  jz 3f
  movzx edx, byte ptr [rsi]
  cmp dl, '0'
  jb .Lparse_alpha
  cmp dl, '9'
  jbe .Lparse_digit
.Lparse_alpha:
  cmp r15, 16
  jne 2f
  cmp dl, 'a'
  jb .Lparse_upper
  cmp dl, 'f'
  jbe .Lparse_lower_digit
.Lparse_upper:
  cmp dl, 'A'
  jb 2f
  cmp dl, 'F'
  ja 2f
  sub edx, 'A' - 10
  jmp .Lparse_add
.Lparse_lower_digit:
  sub edx, 'a' - 10
  jmp .Lparse_add
.Lparse_digit:
  sub edx, '0'
.Lparse_add:
  imul rax, r15
  jo 2f
  add rax, rdx
  jo 2f
  inc rsi
  dec rcx
  jmp 1b
2:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Integer literal is too large: "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, rbx
  call sb_putstr
  call p_prev
  mov r12, [rax + 16]
  lea rdi, LA(2)
  LEAS rsi, "Syntax error"
  mov rdx, r12
  call fail_sb
3:
  EPI

// is the assignment target valid? rdi = expr node -> eax
.balign 16
p_assignable:
  mov eax, [rdi]
  cmp eax, EK_VAR
  je 1f
  cmp eax, EK_GET
  je 1f
  cmp eax, EK_INDEX
  je 1f
  cmp eax, EK_UNARY
  jne 2f
  cmp qword ptr [rdi + N_A], TK_STAR
  je 1f
2:
  xor eax, eax
  ret
1:
  mov eax, 1
  ret

FN p_expression, 0
  call p_assignment
  EPI

FN p_assignment, 3
  call p_ternary
  mov rbx, rax
  call p_cur
  mov rcx, [rax]
  cmp rcx, TK_EQUAL
  je 1f
  cmp rcx, TK_PLUSEQ
  jb 9f
  cmp rcx, TK_PERCENTEQ
  ja 9f
1:
  call p_adv
  mov r12, [rax]               // operator token type
  mov r13, [rax + 16]          // line
  call p_assignment
  mov r14, rax
  mov rdi, rbx
  call p_assignable
  test eax, eax
  jnz 2f
  LEAS rdi, "Invalid assignment target"
  mov rsi, r13
  call syn_err
2:
  cmp r12, TK_EQUAL
  je 3f
  sub r12, TK_PLUSEQ
  add r12, TK_PLUS             // += -> +, -= -> -, ...
3:
  NODE EK_ASSIGN, r13, rbx, r12, r14
  EPI
9:
  mov rax, rbx
  EPI

FN p_ternary, 3
  mov edi, 1
  call p_binary
  mov rbx, rax
  mov edi, TK_QUESTION
  call p_match
  test eax, eax
  jz 9f
  call p_prev
  mov r12, [rax + 16]
  call p_assignment
  mov r13, rax
  mov edi, TK_COLON
  LEAS rsi, "Expected ':' in conditional expression"
  call p_expect
  call p_assignment
  NODE EK_TERNARY, r12, rbx, r13, rax
  EPI
9:
  mov rax, rbx
  EPI

FN p_binary, 4                 // rdi = minimum precedence (precedence climbing)
  mov r12, rdi
  call p_unary
  mov rbx, rax
1:
  call p_cur
  mov r13, [rax]               // operator type
  mov rdi, r13
  call p_binprec
  test eax, eax
  jz 9f
  cmp eax, r12d
  jb 9f
  mov r14, rax                 // precedence
  call p_adv
  mov r15, [rax + 16]          // line
  cmp r13, TK_IS
  jne 2f
  xor edi, edi                 // `x is T`: no '?' suffix (clashes with the ternary)
  call p_parse_type
  NODE EK_IS, r15, rbx, rax
  mov rbx, rax
  jmp 1b
2:
  lea rdi, [r14 + 1]
  call p_binary
  mov rcx, EK_BINARY
  cmp r13, TK_OROR
  je 3f
  cmp r13, TK_ANDAND
  jne 4f
3:
  mov ecx, EK_LOGICAL
4:
  mov L(0), rcx
  mov rdi, r15
  shl rdi, 32
  or rdi, L(0)
  mov rsi, rbx
  mov rdx, r13
  mov rcx, rax
  xor r8d, r8d
  xor r9d, r9d
  call mk_node
  mov rbx, rax
  jmp 1b
9:
  mov rax, rbx
  EPI

FN p_unary, 3
  call p_cur
  mov r12, [rax]
  cmp r12, TK_MINUS
  je 1f
  cmp r12, TK_BANG
  je 1f
  cmp r12, TK_STAR
  je 1f
  cmp r12, TK_AMP
  je 1f
  cmp r12, TK_PLUSPLUS
  je 2f
  cmp r12, TK_MINUSMINUS
  je 2f
  call p_postfix
  EPI
1:
  call p_adv
  mov r13, [rax + 16]
  call p_unary
  NODE EK_UNARY, r13, r12, rax
  EPI
2:
  call p_adv
  mov r13, [rax + 16]
  call p_unary
  mov rbx, rax
  mov rdi, rax
  call p_assignable
  test eax, eax
  jnz 3f
  LEAS rdi, "Invalid target for '++' / '--'"
  mov rsi, r13
  call syn_err
3:
  xor ecx, ecx
  cmp r12, TK_PLUSPLUS
  sete cl
  NODE EK_UPDATE, r13, rbx, rcx, 1
  EPI

FN p_postfix, 3
  call p_call
  mov rbx, rax
  call p_cur
  mov r12, [rax]
  cmp r12, TK_PLUSPLUS
  je 1f
  cmp r12, TK_MINUSMINUS
  jne 9f
1:
  mov r13, [rax + 16]
  call p_prev
  cmp [rax + 16], r13
  jne 9f                       // `++` on the next line is not a postfix
  call p_adv
  mov rdi, rbx
  call p_assignable
  test eax, eax
  jnz 2f
  LEAS rdi, "Invalid target for '++' / '--'"
  mov rsi, r13
  call syn_err
2:
  xor ecx, ecx
  cmp r12, TK_PLUSPLUS
  sete cl
  NODE EK_UPDATE, r13, rbx, rcx, 0
  mov rbx, rax
9:
  mov rax, rbx
  EPI

FN p_call, 4                   // primary followed by (args) .name [index]
  call p_primary
  mov rbx, rax
1:
  call p_cur
  mov r12, rax
  mov rcx, [rax]
  cmp rcx, TK_LPAREN
  je 2f
  cmp rcx, TK_LBRACKET
  je 5f
  cmp rcx, TK_DOT
  je 8f
  jmp 9f
2:                              // call: the '(' must be on the same line as the previous token
  call p_prev
  mov rcx, [r12 + 16]
  cmp [rax + 16], rcx
  jne 9f
  call p_adv
  mov r13, [rax + 16]
  lea rdi, LA(2)
  call sb_init
  mov edi, TK_RPAREN
  call p_check
  test eax, eax
  jnz 4f
3:
  mov edi, TK_RPAREN
  call p_check
  test eax, eax
  jnz 4f
  call p_expression
  lea rdi, LA(2)
  mov rsi, rax
  call vec_push
  mov edi, TK_COMMA
  call p_match
  test eax, eax
  jnz 3b
4:
  mov edi, TK_RPAREN
  LEAS rsi, "Expected ')' after arguments"
  call p_expect
  lea rdi, LA(2)
  call vec_to_list
  NODE EK_CALL, r13, rbx, rax
  mov rbx, rax
  jmp 1b
5:                              // index
  call p_prev
  mov rcx, [r12 + 16]
  cmp [rax + 16], rcx
  jne 9f
  call p_adv
  mov r13, [rax + 16]
  call p_expression
  mov r14, rax
  mov edi, TK_RBRACKET
  LEAS rsi, "Expected ']' after index"
  call p_expect
  NODE EK_INDEX, r13, rbx, r14
  mov rbx, rax
  jmp 1b
8:                              // .name
  call p_adv
  mov edi, TK_IDENT
  LEAS rsi, "Expected property name after '.'"
  call p_expect
  mov r13, [rax + 16]
  mov r14, [rax + 8]
  NODE EK_GET, r13, rbx, r14
  mov rbx, rax
  jmp 1b
9:
  mov rax, rbx
  EPI

// ---------------------------------------------------------------- functions
// params -> list of records {name, type, default}; the '(' is already consumed
FN p_params, 6                 // LA(2) = vec
  lea rdi, LA(2)
  call sb_init
  xor r14d, r14d               // seen a default value
  mov edi, TK_RPAREN
  call p_check
  test eax, eax
  jnz 8f
1:
  mov edi, TK_RPAREN
  call p_check
  test eax, eax
  jnz 8f                       // trailing comma
  xor r12d, r12d               // type
  xor edi, edi
  call p_looks_typed
  test eax, eax
  jz 2f
  mov edi, 1
  call p_parse_type
  mov r12, rax
2:
  mov edi, TK_IDENT
  LEAS rsi, "Expected parameter name"
  call p_expect
  mov r13, [rax + 8]           // name
  mov rcx, L(2)
  xor edx, edx
3:                              // duplicate check
  cmp rdx, [rbp - 48 - 8*2]
  jae 4f
  mov rsi, [rbp - 48 - 8*0]
  mov rax, [rsi + rdx*8]
  cmp [rax], r13
  jne 5f
  lea rdi, LA(5)
  call sb_init
  lea rdi, LA(5)
  LEAS rsi, "Duplicate parameter '"
  call sb_putcs
  lea rdi, LA(5)
  mov rsi, r13
  call sb_putstr
  lea rdi, LA(5)
  mov esi, 39
  call sb_putc
  call p_prev
  lea rdi, LA(5)
  mov rsi, rax
  call p_finish
5:
  inc rdx
  jmp 3b
4:
  xor r15d, r15d               // default expression
  mov edi, TK_EQUAL
  call p_match
  test eax, eax
  jz 6f
  call p_expression
  mov r15, rax
  mov r14d, 1
  jmp 7f
6:
  test r14d, r14d
  jz 7f
  LEAS rdi, "Parameters without a default value cannot follow ones with a default"
  call p_error_prev
7:
  mov edi, 32
  call hx_alloc
  mov [rax], r13
  mov [rax + 8], r12
  mov [rax + 16], r15
  lea rdi, LA(2)
  mov rsi, rax
  call vec_push
  mov edi, TK_COMMA
  call p_match
  test eax, eax
  jnz 1b
8:
  mov edi, TK_RPAREN
  LEAS rsi, "Expected ')' after parameters"
  call p_expect
  lea rdi, LA(2)
  call vec_to_list
  EPI

// function declaration node (body filled in later)
FN mk_fdecl, 0                 // rdi = name (or 0), rsi = params list, rdx = return type, rcx = line
  inc G(p_closures)
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov rcx, [r12]               // max args = count
  xor edx, edx                 // min args = params without default
  xor eax, eax
1:
  cmp rax, rcx
  jae 2f
  mov rsi, [r12 + 8 + rax*8]
  cmp qword ptr [rsi + 16], 0
  jne 3f
  inc rdx
3:
  inc rax
  jmp 1b
2:
  mov r15, rdx
  mov rdi, r14
  shl rdi, 32                  // kind 0
  mov rsi, rbx
  mov rdx, r12
  mov rcx, r13
  xor r8d, r8d
  mov r9, r15
  call mk_node
  mov rcx, [r12]
  mov [rax + N_F], rcx
  EPI

// body: either a block, or (exprBody) a single expression that is returned
FN p_body, 3                   // rdi = fdecl, rsi = exprBody allowed
  mov rbx, rdi
  mov r12, rsi
  mov r13, G(p_ldepth)
  mov G(p_ldepth), 0
  inc G(p_fdepth)
  test r12, r12
  jz 1f
  mov edi, TK_LBRACE
  call p_check
  test eax, eax
  jnz 1f
  call p_cur                    // expression body  =>  return <expr>
  mov r14, [rax + 16]
  call p_expression
  NODE SK_RETURN, r14, rax
  mov r15, rax
  mov edi, 16
  call hx_alloc
  mov qword ptr [rax], 1
  mov [rax + 8], r15
  mov [rbx + N_D], rax
  jmp 9f
1:
  mov edi, TK_LBRACE
  LEAS rsi, "Expected '{' before function body"
  call p_expect
  lea rdi, LA(2)
  call sb_init
2:
  mov edi, TK_RBRACE
  call p_check
  test eax, eax
  jnz 3f
  call p_cur
  cmp qword ptr [rax], TK_END
  je 3f
  call p_declaration
  lea rdi, LA(2)
  mov rsi, rax
  call vec_push
  jmp 2b
3:
  mov edi, TK_RBRACE
  LEAS rsi, "Expected '}' after function body"
  call p_expect
  lea rdi, LA(2)
  call vec_to_list
  mov [rbx + N_D], rax
9:
  dec G(p_fdepth)
  mov G(p_ldepth), r13
  mov rax, rbx
  EPI

// After the name:  (params) [-> Type] { body }  |  (params) [-> Type] => expr
FN p_fn_tail, 4                // rdi = name, rsi = line, rdx = prefix type
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  mov edi, TK_LPAREN
  LEAS rsi, "Expected '(' after function name"
  call p_expect
  call p_params
  mov r15, rax
  xor ebx, ebx
  mov edi, TK_THIN
  call p_match
  test eax, eax
  jz 1f
  mov edi, 1
  call p_parse_type
  mov rbx, rax
1:
  test r14, r14
  jz 3f
  test rbx, rbx
  jz 2f
  mov rdi, r14                 // both given: they must agree
  mov rsi, rbx
  call type_equal
  test eax, eax
  jnz 3f
  LEAS rdi, "Conflicting return types: the type before the name and the one after '->' differ"
  mov rsi, r13
  call syn_err
2:
  mov rbx, r14
3:
  mov rdi, r12
  mov rsi, r15
  mov rdx, rbx
  mov rcx, r13
  call mk_fdecl
  mov r12, rax
  mov edi, TK_ARROW
  call p_match
  mov rdi, r12
  mov esi, eax
  call p_body
  EPI

FN p_fn_after_fn, 1            // after 'fn':  [ReturnType] name(...)
  xor ebx, ebx
  mov edi, TK_IDENT
  call p_check
  test eax, eax
  jz 1f
  mov edi, 1
  call p_atype
  cmp eax, TK_LPAREN
  je 2f
1:
  mov edi, 1
  call p_parse_type
  mov rbx, rax
2:
  mov edi, TK_IDENT
  LEAS rsi, "Expected function name"
  call p_expect
  mov rdi, [rax + 8]
  mov rsi, [rax + 16]
  mov rdx, rbx
  call p_fn_tail
  EPI

// (...) => ... : is the parenthesis at the cursor the parameter list of a lambda?
FN p_is_lambda, 0
  mov rbx, G(p_pos)
  xor r12d, r12d               // depth
1:
  mov rdi, rbx
  call p_tokat
  mov rcx, [rax]
  cmp rcx, TK_END
  je 8f
  cmp rcx, TK_LPAREN
  jne 2f
  inc r12
  jmp 4f
2:
  cmp rcx, TK_RPAREN
  jne 4f
  dec r12
  jnz 4f
  lea rdi, [rbx + 1]
  call p_tokat
  mov rcx, [rax]
  cmp rcx, TK_ARROW
  je 9f
  cmp rcx, TK_THIN
  je 9f
  jmp 8f
4:
  inc rbx
  jmp 1b
8:
  xor eax, eax
  EPI
9:
  mov eax, 1
  EPI

FN p_lambda_parens, 4
  mov edi, TK_LPAREN
  LEAS rsi, "Expected '('"
  call p_expect
  mov r12, [rax + 16]
  call p_params
  mov r13, rax
  xor ebx, ebx
  mov edi, TK_THIN
  call p_match
  test eax, eax
  jz 1f
  mov edi, 1
  call p_parse_type
  mov rbx, rax
1:
  xor edi, edi
  mov rsi, r13
  mov rdx, rbx
  mov rcx, r12
  call mk_fdecl
  mov r14, rax
  mov edi, TK_ARROW
  LEAS rsi, "Expected '=>' in lambda"
  call p_expect
  mov rdi, r14
  mov esi, 1
  call p_body
  NODE EK_LAMBDA, r12, r14
  EPI

FN p_lambda_single, 3          // name => expr
  call p_adv
  mov r12, [rax + 8]
  mov r13, [rax + 16]
  call p_adv                   // '=>'
  mov edi, 32
  call hx_alloc
  mov [rax], r12
  mov rbx, rax
  mov edi, 16
  call hx_alloc
  mov qword ptr [rax], 1
  mov [rax + 8], rbx
  xor edi, edi
  mov rsi, rax
  xor edx, edx
  mov rcx, r13
  call mk_fdecl
  mov r14, rax
  mov rdi, rax
  mov esi, 1
  call p_body
  NODE EK_LAMBDA, r13, r14
  EPI

FN p_anon_fn, 3                // fn (params) [-> T] { body }
  call p_adv
  mov r12, [rax + 16]
  mov edi, TK_LPAREN
  LEAS rsi, "Expected '(' after 'fn'"
  call p_expect
  call p_params
  mov r13, rax
  xor ebx, ebx
  mov edi, TK_THIN
  call p_match
  test eax, eax
  jz 1f
  mov edi, 1
  call p_parse_type
  mov rbx, rax
1:
  xor edi, edi
  mov rsi, r13
  mov rdx, rbx
  mov rcx, r12
  call mk_fdecl
  mov r14, rax
  mov edi, TK_ARROW
  call p_match
  mov rdi, r14
  mov esi, eax
  call p_body
  NODE EK_LAMBDA, r12, r14
  EPI

FN p_primary, 4
  call p_cur
  mov rbx, rax
  mov r12, [rbx]               // type
  mov r13, [rbx + 16]          // line
  mov r14, [rbx + 8]           // string
  cmp r12, TK_FALSE
  je 1f
  cmp r12, TK_TRUE
  je 2f
  cmp r12, TK_NIL
  je 3f
  cmp r12, TK_INT
  je 4f
  cmp r12, TK_FLOAT
  je 5f
  cmp r12, TK_STRING
  je 6f
  cmp r12, TK_THIS
  je 7f
  cmp r12, TK_SUPER
  je 8f
  cmp r12, TK_IDENT
  je 9f
  cmp r12, TK_LPAREN
  je 10f
  cmp r12, TK_LBRACKET
  je 11f
  cmp r12, TK_FN
  je 12f
  LEAS rdi, "Expected expression"
  call p_error
1:
  call p_adv
  NODE EK_LIT, r13, T_BOOL, 0
  EPI
2:
  call p_adv
  NODE EK_LIT, r13, T_BOOL, 1
  EPI
3:
  call p_adv
  NODE EK_LIT, r13, T_NIL, 0
  EPI
4:
  call p_adv
  mov rdi, r14
  call parse_int
  NODE EK_LIT, r13, T_INT, rax
  EPI
5:
  call p_adv
  lea rdi, [r14 + 16]
  xor esi, esi
  CALLC strtod
  movq rax, xmm0
  NODE EK_LIT, r13, T_FLOAT, rax
  EPI
6:
  call p_adv
  NODE EK_LIT, r13, T_STR, r14
  EPI
7:
  call p_adv
  NODE EK_THIS, r13
  EPI
8:
  call p_adv
  mov edi, TK_DOT
  LEAS rsi, "Expected '.' after 'super'"
  call p_expect
  mov edi, TK_IDENT
  LEAS rsi, "Expected superclass method name"
  call p_expect
  mov r14, [rax + 8]
  NODE EK_SUPER, r13, r14
  EPI
9:
  mov edi, 1
  call p_atype
  cmp eax, TK_ARROW
  jne 13f
  call p_lambda_single
  EPI
13:
  call p_adv
  NODE EK_VAR, r13, r14
  EPI
10:
  call p_is_lambda
  test eax, eax
  jz 14f
  call p_lambda_parens
  EPI
14:
  call p_adv
  call p_expression
  mov rbx, rax
  mov edi, TK_RPAREN
  LEAS rsi, "Expected ')' after expression"
  call p_expect
  mov rax, rbx
  EPI
11:                             // array literal
  call p_adv
  lea rdi, LA(2)
  call sb_init
  mov edi, TK_RBRACKET
  call p_check
  test eax, eax
  jnz 16f
15:
  mov edi, TK_RBRACKET
  call p_check
  test eax, eax
  jnz 16f
  call p_expression
  lea rdi, LA(2)
  mov rsi, rax
  call vec_push
  mov edi, TK_COMMA
  call p_match
  test eax, eax
  jnz 15b
16:
  mov edi, TK_RBRACKET
  LEAS rsi, "Expected ']' after array elements"
  call p_expect
  lea rdi, LA(2)
  call vec_to_list
  NODE EK_ARRAY, r13, rax
  EPI
12:
  call p_anon_fn
  EPI
// ------------------------------------------------------------- declarations
FN p_var_decl, 5               // rdi = isConst (after `let`/`const`, or nothing for `int x = 1`)
  mov r12, rdi
  xor ebx, ebx
  mov edi, 1
  call p_looks_typed
  test eax, eax
  jz 1f
  mov edi, 1
  call p_parse_type
  mov rbx, rax
1:
  mov edi, TK_IDENT
  LEAS rsi, "Expected variable name"
  call p_expect
  mov r13, [rax + 8]
  mov r14, [rax + 16]
  xor r15d, r15d
  mov edi, TK_EQUAL
  call p_match
  test eax, eax
  jz 2f
  call p_expression
  mov r15, rax
  jmp 3f
2:
  test r12, r12
  jz 3f
  lea rdi, LA(4)
  call sb_init
  lea rdi, LA(4)
  LEAS rsi, "const '"
  call sb_putcs
  lea rdi, LA(4)
  mov rsi, r13
  call sb_putstr
  lea rdi, LA(4)
  LEAS rsi, "' requires an initializer"
  call sb_putcs
  call p_prev
  lea rdi, LA(4)
  mov rsi, rax
  call p_finish
3:
  NODE SK_VAR, r14, r13, rbx, r15, r12
  EPI

FN p_type_alias, 0
  call p_adv                   // the contextual keyword `type`
  mov r12, [rax + 16]
  mov edi, TK_IDENT
  LEAS rsi, "Expected type name"
  call p_expect
  mov rbx, [rax + 8]
  mov rcx, [rbx + 8]
  cmp rcx, K_int
  jb 1f
  cmp rcx, K_ptr
  ja 1f
  LEAS rdi, "A built-in type cannot be redefined"
  call p_error
1:
  mov edi, TK_EQUAL
  LEAS rsi, "Expected '=' after type name"
  call p_expect
  mov edi, 1
  call p_parse_type
  mov r13, rax
  call p_term
  NODE SK_TYPE, r12, rbx, r13
  EPI

FN p_class_member, 4           // rdi = fields vec, rsi = methods vec
  mov r14, rdi
  mov r15, rsi
  mov L(3), 0                  // members are public by default
  mov edi, TK_PUBLIC
  call p_match
  test eax, eax
  jnz .Lpclass_visibility_done
  mov edi, TK_PRIVATE
  call p_match
  test eax, eax
  jz .Lpclass_visibility_done
  mov L(3), 1
.Lpclass_visibility_done:
  mov edi, TK_STATIC
  call p_match
  mov r12d, eax                // isStatic
  mov edi, TK_FN
  call p_match
  test eax, eax
  jz 1f
  call p_fn_after_fn
  jmp 4f
1:
  mov edi, TK_IDENT
  call p_check
  test eax, eax
  jz 2f
  mov edi, 1
  call p_atype
  cmp eax, TK_LPAREN
  jne 2f
  call p_adv                   // method shorthand: name(...) {...}
  mov rdi, [rax + 8]
  mov rsi, [rax + 16]
  xor edx, edx
  call p_fn_tail
  jmp 4f
2:                              // field:  [const] [let] [Type] name [= expr]
  xor r13d, r13d
  mov edi, TK_CONST
  call p_match
  test eax, eax
  jz 3f
  or r13d, 1
3:
  test r12d, r12d
  jz 5f
  or r13d, 2
5:
  cmp L(3), 0
  je .Lpclass_field_public
  or r13d, 4                 // private field flag
.Lpclass_field_public:
  mov edi, TK_LET
  call p_match
  xor ebx, ebx
  mov edi, 1
  call p_looks_typed
  test eax, eax
  jz 6f
  mov edi, 1
  call p_parse_type
  mov rbx, rax
6:
  mov edi, TK_IDENT
  LEAS rsi, "Expected a field or method name"
  call p_expect
  mov rcx, [rax + 8]
  mov L(0), rcx
  mov rcx, [rax + 16]
  mov L(1), rcx
  mov L(2), 0
  mov edi, TK_EQUAL
  call p_match
  test eax, eax
  jz 7f
  call p_expression
  mov L(2), rax
7:
  mov edi, TK_SEMI
  call p_match
  test eax, eax
  jnz 8f
  mov edi, TK_COMMA
  call p_match
8:
  mov edi, 48
  call hx_alloc
  mov rcx, L(0)
  mov [rax], rcx
  mov [rax + 8], rbx
  mov rcx, L(2)
  mov [rax + 16], rcx
  mov [rax + 24], r13
  mov rcx, L(1)
  mov [rax + 32], rcx
  mov rdi, r14
  mov rsi, rax
  call vec_push
  EPI
4:                              // push method record {fdecl, isStatic, isPrivate}
  mov rbx, rax
  mov edi, 24
  call hx_alloc
  mov [rax], rbx
  mov [rax + 8], r12
  mov rcx, L(3)
  mov [rax + 16], rcx
  mov rdi, r15
  mov rsi, rax
  call vec_push
  EPI

FN p_class_decl, 8             // LA(2) = fields vec, LA(5) = methods vec
  inc G(p_closures)
  call p_adv
  mov r12, [rax]
  mov r13, [rax + 16]
  xor r14d, r14d
  cmp r12, TK_STRUCT
  sete r14b                    // isStruct
  mov edi, TK_IDENT
  LEAS rsi, "Expected class name"
  call p_expect
  mov rbx, [rax + 8]
  mov rcx, [rbx + 8]
  cmp rcx, K_int
  jb 1f
  cmp rcx, K_ptr
  ja 1f
  LEAS rdi, "A built-in type name cannot be used for a class"
  call p_error
1:
  xor r15d, r15d
  mov edi, TK_EXTENDS
  call p_match
  test eax, eax
  jz 3f
  test r14d, r14d
  jz 2f
  LEAS rdi, "A struct cannot extend another type"
  call p_error_prev
2:
  mov edi, TK_IDENT
  LEAS rsi, "Expected superclass name"
  call p_expect
  mov r15, [rax + 8]
  cmp r15, rbx
  jne 3f
  LEAS rdi, "A class cannot extend itself"
  call p_error
3:
  mov edi, TK_LBRACE
  LEAS rsi, "Expected '{' before class body"
  call p_expect
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(5)
  call sb_init
4:
  mov edi, TK_RBRACE
  call p_check
  test eax, eax
  jnz 5f
  call p_cur
  cmp qword ptr [rax], TK_END
  je 5f
  lea rdi, LA(2)
  lea rsi, LA(5)
  call p_class_member
  jmp 4b
5:
  mov edi, TK_RBRACE
  LEAS rsi, "Expected '}' after class body"
  call p_expect
  lea rdi, LA(2)
  call vec_to_list
  mov L(6), rax
  lea rdi, LA(5)
  call vec_to_list
  mov rdi, r13
  shl rdi, 32
  or rdi, SK_CLASS
  mov rsi, rbx
  mov rdx, r15
  mov rcx, r14
  mov r8, L(6)
  mov r9, rax
  call mk_node
  EPI

FN p_import_decl, 3             // import "module.hexo" as module
  call p_cur
  mov r12, [rax + 16]          // source line
  call p_adv                   // import
  mov edi, TK_STRING
  LEAS rsi, "Expected a quoted module path after 'import'"
  call p_expect
  mov r13, [rax + 8]           // path String*
  mov edi, TK_AS
  LEAS rsi, "Expected 'as' and a module alias"
  call p_expect
  mov edi, TK_IDENT
  LEAS rsi, "Expected a module alias after 'as'"
  call p_expect
  mov r14, [rax + 8]           // alias String*
  call p_term
  NODE SK_IMPORT, r12, r13, r14
  EPI

FN p_from_import_decl, 4        // from "module.hexo" import Name, other
  call p_cur
  mov r12, [rax + 16]          // source line
  call p_adv                   // from
  mov edi, TK_STRING
  LEAS rsi, "Expected a quoted module path after 'from'"
  call p_expect
  mov r13, [rax + 8]           // path String*
  mov edi, TK_IMPORT
  LEAS rsi, "Expected 'import' after the module path"
  call p_expect
  lea rdi, LA(2)               // vector of imported identifiers
  call sb_init
1:
  mov edi, TK_IDENT
  LEAS rsi, "Expected an exported name after 'import'"
  call p_expect
  mov r14, [rax + 8]
  lea rdi, LA(2)
  mov rsi, r14
  call vec_push
  mov edi, TK_COMMA
  call p_match
  test eax, eax
  jnz 1b
  call p_term
  lea rdi, LA(2)
  call vec_to_list
  mov r14, rax
  NODE SK_FROM_IMPORT, r12, r13, r14
  EPI

FN p_declaration, 2
  call p_cur
  mov rbx, [rax]
  cmp rbx, TK_IMPORT
  jne 90f
  call p_import_decl
  EPI
90:
  cmp rbx, TK_FROM
  jne 91f
  call p_from_import_decl
  EPI
91:
  cmp rbx, TK_LET
  jne 1f
  call p_adv
  xor edi, edi
  call p_var_decl
  mov r12, rax
  call p_term
  mov rax, r12
  EPI
1:
  cmp rbx, TK_CONST
  jne 2f
  call p_adv
  mov edi, 1
  call p_var_decl
  mov r12, rax
  call p_term
  mov rax, r12
  EPI
2:
  cmp rbx, TK_FN
  jne 3f
  mov edi, 1
  call p_atype
  cmp eax, TK_IDENT
  jne 5f                       // `fn(int) -> int f = ...` (typed declaration)
  call p_adv
  mov r13, [rax + 16]
  call p_fn_after_fn
  mov r12, rax
  call p_term
  NODE SK_FUNC, r13, r12
  EPI
3:
  cmp rbx, TK_CLASS
  je 4f
  cmp rbx, TK_STRUCT
  jne 6f
4:
  call p_class_decl
  EPI
6:
  cmp rbx, TK_IDENT            // `type Name = ...` (contextual keyword)
  jne 5f
  call p_cur
  mov rax, [rax + 8]
  cmp qword ptr [rax + 8], K_type
  jne 5f
  mov edi, 1
  call p_atype
  cmp eax, TK_IDENT
  jne 5f
  mov edi, 2
  call p_atype
  cmp eax, TK_EQUAL
  jne 5f
  call p_type_alias
  EPI
5:
  cmp rbx, TK_IDENT            // `int age = 10`
  je 7f
  cmp rbx, TK_FN
  je 7f
  cmp rbx, TK_NIL
  jne 8f
7:
  mov edi, 1
  call p_looks_typed
  test eax, eax
  jz 8f
  xor edi, edi
  call p_var_decl
  mov r12, rax
  call p_term
  mov rax, r12
  EPI
8:
  call p_statement
  EPI

// -------------------------------------------------------------- statements
FN p_block, 4                  // after '{'
  call p_prev
  mov r12, [rax + 16]
  lea rdi, LA(2)
  call sb_init
1:
  mov edi, TK_RBRACE
  call p_check
  test eax, eax
  jnz 2f
  call p_cur
  cmp qword ptr [rax], TK_END
  je 2f
  call p_declaration
  lea rdi, LA(2)
  mov rsi, rax
  call vec_push
  jmp 1b
2:
  mov edi, TK_RBRACE
  LEAS rsi, "Expected '}' after block"
  call p_expect
  lea rdi, LA(2)
  call vec_to_list
  mov rbx, rax
  xor r13d, r13d               // does the block declare anything? (then it needs its own scope)
  mov rcx, [rbx]
  xor edx, edx
3:
  cmp rdx, rcx
  jae 5f
  mov rsi, [rbx + 8 + rdx*8]
  mov eax, [rsi]
  cmp eax, SK_VAR
  je 4f
  cmp eax, SK_FUNC
  je 4f
  cmp eax, SK_CLASS
  je 4f
  cmp eax, SK_TYPE
  jne 6f
4:
  mov r13d, 1
6:
  inc rdx
  jmp 3b
5:
  NODE SK_BLOCK, r12, rbx, r13
  EPI

FN p_expr_stmt, 1
  call p_cur
  mov r12, [rax + 16]
  call p_expression
  mov rbx, rax
  call p_term
  NODE SK_EXPR, r12, rbx
  EPI

FN p_if, 3
  call p_prev
  mov r12, [rax + 16]
  mov edi, TK_LPAREN
  LEAS rsi, "Expected '(' after 'if'"
  call p_expect
  call p_expression
  mov rbx, rax
  mov edi, TK_RPAREN
  LEAS rsi, "Expected ')' after condition"
  call p_expect
  call p_statement
  mov r13, rax
  xor r14d, r14d
  mov edi, TK_ELSE
  call p_match
  test eax, eax
  jz 1f
  call p_statement
  mov r14, rax
1:
  NODE SK_IF, r12, rbx, r13, r14
  EPI

FN p_while, 3
  mov r13, G(p_closures)
  call p_prev
  mov r12, [rax + 16]
  mov edi, TK_LPAREN
  LEAS rsi, "Expected '(' after 'while'"
  call p_expect
  call p_expression
  mov rbx, rax
  mov edi, TK_RPAREN
  LEAS rsi, "Expected ')' after condition"
  call p_expect
  inc G(p_ldepth)
  call p_statement
  dec G(p_ldepth)
  xor ecx, ecx
  cmp r13, G(p_closures)
  setne cl
  NODE SK_WHILE, r12, rbx, rax, rcx
  EPI

FN p_for, 8
  mov rax, G(p_closures)
  mov L(5), rax
  call p_prev
  mov r12, [rax + 16]
  mov edi, TK_LPAREN
  LEAS rsi, "Expected '(' after 'for'"
  call p_expect
  mov r13, G(p_pos)            // for-in or C-style? try for-in first, rewind if not
  xor r14d, r14d
  mov edi, TK_LET
  call p_match
  test eax, eax
  jnz 1f
  mov edi, TK_CONST
  call p_match
  mov r14d, eax
1:
  xor ebx, ebx
  xor edi, edi
  call p_looks_typed
  test eax, eax
  jz 2f
  mov edi, 1
  call p_parse_type
  mov rbx, rax
2:
  mov edi, TK_IDENT
  call p_check
  test eax, eax
  jz 4f
  mov edi, 1
  call p_atype
  cmp eax, TK_IN
  jne 4f
  call p_adv
  mov r15, [rax + 8]
  call p_adv                   // 'in'
  call p_expression
  mov L(0), rax
  mov edi, TK_RPAREN
  LEAS rsi, "Expected ')' after for-in clause"
  call p_expect
  inc G(p_ldepth)
  call p_statement
  dec G(p_ldepth)
  mov L(1), rax
  mov rdi, r12
  shl rdi, 32
  or rdi, SK_FORIN
  mov rsi, r15
  mov rdx, rbx
  mov rcx, r14
  mov r8, L(0)
  mov r9, L(1)
  call mk_node
  xor ecx, ecx
  mov rdx, L(5)
  cmp rdx, G(p_closures)
  setne cl
  mov [rax + N_F], rcx
  EPI
4:                              // C-style:  for (init; cond; incr) body
  mov G(p_pos), r13
  mov L(0), 0                  // init
  mov L(1), 0                  // cond
  mov L(2), 0                  // incr
  mov edi, TK_SEMI
  call p_match
  test eax, eax
  jnz 9f
  call p_cur
  mov rcx, [rax]
  cmp rcx, TK_LET
  je 5f
  cmp rcx, TK_CONST
  je 6f
  cmp rcx, TK_IDENT
  je 7f
  cmp rcx, TK_FN
  je 7f
  cmp rcx, TK_NIL
  jne 8f
7:
  mov edi, 1
  call p_looks_typed
  test eax, eax
  jz 8f
  xor edi, edi
  call p_var_decl
  mov L(0), rax
  mov edi, TK_SEMI
  LEAS rsi, "Expected ';' after loop initializer"
  call p_expect
  jmp 9f
5:
  xor r14d, r14d
  jmp 10f
6:
  mov r14d, 1
10:
  call p_adv
  mov rdi, r14
  call p_var_decl
  mov L(0), rax
  mov edi, TK_SEMI
  LEAS rsi, "Expected ';' after loop initializer"
  call p_expect
  jmp 9f
8:
  call p_cur
  mov r14, [rax + 16]
  call p_expression
  mov rbx, rax
  mov edi, TK_SEMI
  LEAS rsi, "Expected ';' after loop initializer"
  call p_expect
  NODE SK_EXPR, r14, rbx
  mov L(0), rax
9:
  mov edi, TK_SEMI
  call p_check
  test eax, eax
  jnz 11f
  call p_expression
  mov L(1), rax
11:
  mov edi, TK_SEMI
  LEAS rsi, "Expected ';' after loop condition"
  call p_expect
  mov edi, TK_RPAREN
  call p_check
  test eax, eax
  jnz 12f
  call p_expression
  mov L(2), rax
12:
  mov edi, TK_RPAREN
  LEAS rsi, "Expected ')' after for clauses"
  call p_expect
  inc G(p_ldepth)
  call p_statement
  dec G(p_ldepth)
  mov r8, rax
  xor r9d, r9d
  mov rdx, L(5)
  cmp rdx, G(p_closures)
  setne r9b
  mov rdi, r12
  shl rdi, 32
  or rdi, SK_FOR
  mov rsi, L(0)
  mov rdx, L(1)
  mov rcx, L(2)
  call mk_node
  EPI

FN p_try, 4
  call p_prev
  mov r12, [rax + 16]
  mov edi, TK_LBRACE
  LEAS rsi, "Expected '{' after 'try'"
  call p_expect
  call p_block
  mov rbx, rax                 // try block
  xor r13d, r13d               // catch name
  xor r14d, r14d               // catch block
  xor r15d, r15d               // finally block
  mov edi, TK_CATCH
  call p_match
  test eax, eax
  jz 2f
  mov edi, TK_LPAREN
  call p_match
  test eax, eax
  jz 1f
  mov edi, TK_IDENT
  LEAS rsi, "Expected a name in 'catch'"
  call p_expect
  mov r13, [rax + 8]
  mov edi, TK_RPAREN
  LEAS rsi, "Expected ')' after catch variable"
  call p_expect
1:
  mov edi, TK_LBRACE
  LEAS rsi, "Expected '{' after 'catch'"
  call p_expect
  call p_block
  mov r14, rax
2:
  mov edi, TK_FINALLY
  call p_match
  test eax, eax
  jz 3f
  mov edi, TK_LBRACE
  LEAS rsi, "Expected '{' after 'finally'"
  call p_expect
  call p_block
  mov r15, rax
3:
  test r14, r14
  jnz 4f
  test r15, r15
  jnz 4f
  LEAS rdi, "'try' needs a 'catch' or a 'finally' block"
  call p_error
4:
  NODE SK_TRY, r12, rbx, r13, r14, r15
  EPI

FN p_statement, 3
  call p_cur
  mov rbx, [rax]
  mov r12, [rax + 16]
  cmp rbx, TK_IF
  jne 1f
  call p_adv
  call p_if
  EPI
1:
  cmp rbx, TK_WHILE
  jne 2f
  call p_adv
  call p_while
  EPI
2:
  cmp rbx, TK_FOR
  jne 3f
  call p_adv
  call p_for
  EPI
3:
  cmp rbx, TK_TRY
  jne 4f
  call p_adv
  call p_try
  EPI
4:
  cmp rbx, TK_LBRACE
  jne 5f
  call p_adv
  call p_block
  EPI
5:
  cmp rbx, TK_RETURN
  jne 8f
  call p_adv
  cmp G(p_fdepth), 0
  jne 6f
  LEAS rdi, "'return' outside of a function"
  call p_error_prev
6:
  xor r13d, r13d
  mov edi, TK_SEMI
  call p_check
  test eax, eax
  jnz 7f
  mov edi, TK_RBRACE
  call p_check
  test eax, eax
  jnz 7f
  call p_cur
  cmp qword ptr [rax], TK_END
  je 7f
  cmp [rax + 16], r12
  jne 7f
  call p_expression
  mov r13, rax
7:
  call p_term
  NODE SK_RETURN, r12, r13
  EPI
8:
  cmp rbx, TK_BREAK
  jne 10f
  call p_adv
  cmp G(p_ldepth), 0
  jne 9f
  LEAS rdi, "'break' outside of a loop"
  call p_error_prev
9:
  call p_term
  NODE SK_BREAK, r12
  EPI
10:
  cmp rbx, TK_CONTINUE
  jne 12f
  call p_adv
  cmp G(p_ldepth), 0
  jne 11f
  LEAS rdi, "'continue' outside of a loop"
  call p_error_prev
11:
  call p_term
  NODE SK_CONTINUE, r12
  EPI
12:
  cmp rbx, TK_THROW
  jne 13f
  call p_adv
  call p_expression
  mov r13, rax
  call p_term
  NODE SK_THROW, r12, r13
  EPI
13:
  call p_expr_stmt
  EPI

FN parse_program, 3            // tokens -> list of statements
  mov G(p_pos), 0
  mov G(p_fdepth), 0
  mov G(p_ldepth), 0
  lea rdi, LA(2)
  call sb_init
1:
  call p_cur
  cmp qword ptr [rax], TK_END
  je 2f
  call p_declaration
  lea rdi, LA(2)
  mov rsi, rax
  call vec_push
  jmp 1b
2:
  lea rdi, LA(2)
  call vec_to_list
  EPI
// ============================================================== INTERPRETER CORE
DATA
GV g_globals
GV g_builtins
GV g_repl
GV ret_tag                     // value of the last executed `return`
GV ret_pay
GV ret_line
GV stack_base
GV stack_budget
GV str_anon                     // "<anonymous>"
GV env_chunk                   // environment arena (rewound when a call created no closures)
GV env_ptr
GV env_end
GV closure_cnt                 // closures / bound methods / classes created so far
.equ ENV_CHUNK, 2097152
.equ ENV_MAGIC, 0x456E5600       // TB_X of an environment table (instances use 0/1, classes a pointer)
GV coerce_ctx                  // optional " of 'fname'" suffix for the next coerce() error
GV module_cache                 // linked list: {next, path String*, module env}
GV access_class                  // class currently executing (private member access)
.equ MOD_MAGIC, 0x4D6F4400

TEXT
// ------------------------------------------------------------------ tables
// table: +0 count, +8 capacity, +16 entries, +24 link, +32 extra.  Entries are
// 56 bytes: name, tag, payload, type, flags, type-env, declaring-class.
.balign 16
tbl_find:                      // rdi = table, rsi = name, edx = want alias (0/1) -> rax = entry or 0
  mov rcx, [rdi + TB_COUNT]
  mov r8, [rdi + TB_ENT]
1:
  test rcx, rcx
  jz 3f
  cmp [r8 + E_NAME], rsi
  jne 2f
  mov rax, [r8 + E_FLAGS]
  shr rax, 1
  and eax, 1
  cmp eax, edx
  je 4f
2:
  add r8, E_SIZE
  dec rcx
  jmp 1b
3:
  xor eax, eax
  ret
4:
  mov rax, r8
  ret

FN env_alloc, 0                // rdi = size -> rax = zeroed memory from the environment arena
  add rdi, 15
  and rdi, -16
  mov rbx, rdi
  cmp rdi, 65536
  ja 9f
  mov rax, G(env_ptr)
  lea rcx, [rax + rbx]
  cmp rcx, G(env_end)
  jbe 3f
  mov rax, G(env_chunk)        // current chunk is full: use the next one (allocate if needed)
  test rax, rax
  jz 1f
  mov rcx, [rax]
  test rcx, rcx
  jnz 2f
1:
  mov edi, 1
  mov esi, ENV_CHUNK + 16
  CALLC calloc
  test rax, rax
  jz hx_oom
  mov rcx, G(env_chunk)
  test rcx, rcx
  jz 11f
  mov [rcx], rax               // link the old chunk to the new one
11:
  mov rcx, rax
2:
  mov G(env_chunk), rcx        // rcx = chunk to use
  lea rax, [rcx + 16]
  lea rdx, [rax + ENV_CHUNK]
  mov G(env_end), rdx
3:
  lea rcx, [rax + rbx]
  mov G(env_ptr), rcx
  mov r12, rax
  mov rdi, rax                 // rewound memory is dirty: always clear it
  xor esi, esi
  mov rdx, rbx
  CALLC memset
  mov rax, r12
  EPI
9:
  mov rdi, rbx
  call hx_alloc
  EPI

.balign 16
env_mark:                      // rdi = 3-qword record {chunk, pointer, closure count}
  mov rax, G(env_chunk)
  mov [rdi], rax
  mov rax, G(env_ptr)
  mov [rdi + 8], rax
  mov rax, G(closure_cnt)
  mov [rdi + 16], rax
  ret

.balign 16
env_release:                   // rdi = record from env_mark; keeps rax:rdx (the call result)
  mov rcx, G(closure_cnt)
  cmp rcx, [rdi + 16]
  jne 1f                       // a closure was created: some scope may still be referenced
  mov rcx, [rdi]
  mov G(env_chunk), rcx
  mov rcx, [rdi + 8]
  mov G(env_ptr), rcx
  mov rcx, [rdi]
  add rcx, ENV_CHUNK + 16
  mov G(env_end), rcx
1:
  ret

FN tbl_add, 0                  // rdi = table, rsi = name -> rax = new zeroed entry
  mov rbx, rdi
  mov r12, rsi
  mov rax, [rbx + TB_COUNT]
  cmp rax, [rbx + TB_CAP]
  jb 3f
  mov rcx, [rbx + TB_CAP]
  shl rcx, 1
  jnz 1f
  mov ecx, 4
1:
  mov r13, rcx
  imul rdi, rcx, E_SIZE
  cmp qword ptr [rbx + TB_X], ENV_MAGIC
  jne 11f
  call env_alloc
  jmp 12f
11:
  call hx_alloc
12:
  mov r14, rax
  mov rcx, [rbx + TB_COUNT]
  test rcx, rcx
  jz 2f
  imul rdx, rcx, E_SIZE
  mov rdi, r14
  mov rsi, [rbx + TB_ENT]
  CALLC memcpy
2:
  mov [rbx + TB_ENT], r14
  mov [rbx + TB_CAP], r13
3:
  mov rax, [rbx + TB_COUNT]
  imul rcx, rax, E_SIZE
  add rcx, [rbx + TB_ENT]
  mov [rcx + E_NAME], r12
  inc qword ptr [rbx + TB_COUNT]
  mov rax, rcx
  EPI

FN env_new, 0                  // rdi = parent -> rax
  mov rbx, rdi
  mov edi, 48
  call env_alloc
  mov [rax + TB_LINK], rbx
  mov qword ptr [rax + TB_X], ENV_MAGIC
  EPI

FN env_find, 0                 // rdi = env, rsi = name, edx = want alias -> rax = entry (0 if none), rdx = owner env
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
1:
  test rbx, rbx
  jz 9f
  mov rdi, rbx
  mov rsi, r12
  mov rdx, r13
  call tbl_find
  test rax, rax
  jnz 8f
  mov rbx, [rbx + TB_LINK]
  jmp 1b
8:
  mov rdx, rbx
  EPI
9:
  xor eax, eax
  xor edx, edx
  EPI

// create or overwrite a binding in this very table
FN env_define, 1               // rdi = table, rsi = name, rdx = tag, rcx = payload, r8 = type, r9 = flags
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov r15, r8
  mov L(0), r9
  mov rdx, r9
  shr rdx, 1
  and edx, 1
  mov rdi, rbx
  mov rsi, r12
  call tbl_find
  test rax, rax
  jnz 1f
  mov rdi, rbx
  mov rsi, r12
  call tbl_add
1:
  mov [rax + E_TAG], r13
  mov [rax + E_PAY], r14
  mov [rax + E_TYPE], r15
  mov rcx, L(0)
  mov [rax + E_FLAGS], rcx
  mov qword ptr [rax + E_TENV], 0
  mov qword ptr [rax + E_OWNER], 0
  EPI

// like env_define, but refuses to redeclare (except at the REPL top level)
FN declare, 1                  // same arguments as env_define
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov r15, r8
  mov L(0), r9
  mov rdx, r9
  shr rdx, 1
  and edx, 1
  call tbl_find                // rdi = table, rsi = name still in place
  test rax, rax
  jz 2f
  cmp G(g_repl), 0
  je 1f
  cmp rbx, G(g_globals)
  je 2f
1:
  LEAS rdi, "'"
  mov rsi, r12
  LEAS rdx, "' is already declared in this scope"
  call fail_rt_n
2:
  mov rdi, rbx
  mov rsi, r12
  mov rdx, r13
  mov rcx, r14
  mov r8, r15
  mov r9, L(0)
  call env_define
  EPI

// ------------------------------------------------------------------- values
.balign 16
value_type_name:               // rdi = tag, rsi = payload -> rax = String*
  cmp rdi, T_INST
  jne 1f
  mov rax, [rsi + TB_LINK]
  mov rax, [rax + CL_NAME]
  ret
1:
  lea rax, [rip + tn_table]
  mov rax, [rax + rdi*8]
  ret

.balign 16
to_double:                     // rdi = tag (INT/FLOAT), rsi = payload -> xmm0
  cmp rdi, T_INT
  jne 1f
  cvtsi2sd xmm0, rsi
  ret
1:
  movq xmm0, rsi
  ret

FN arr_new, 0                  // rdi = initial capacity -> rax = array object
  mov rbx, rdi
  mov edi, AR_SIZE
  call hx_alloc
  mov r12, rax
  test rbx, rbx
  jz 1f
  mov [r12 + AR_CAP], rbx
  mov rdi, rbx
  shl rdi, 4
  CALLC malloc
  test rax, rax
  jz hx_oom
  mov [r12 + AR_DATA], rax
1:
  mov rax, r12
  EPI

FN arr_push, 0                 // rdi = array, rsi = tag, rdx = payload
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov rax, [rbx + AR_LEN]
  cmp rax, [rbx + AR_CAP]
  jb 1f
  mov rcx, [rbx + AR_CAP]
  shl rcx, 1
  jnz 2f
  mov ecx, 8
2:
  mov [rbx + AR_CAP], rcx
  mov rdi, [rbx + AR_DATA]
  mov rsi, rcx
  shl rsi, 4
  CALLC realloc
  test rax, rax
  jz hx_oom
  mov [rbx + AR_DATA], rax
1:
  mov rax, [rbx + AR_LEN]
  shl rax, 4
  add rax, [rbx + AR_DATA]
  mov [rax], r12
  mov [rax + 8], r13
  inc qword ptr [rbx + AR_LEN]
  EPI

FN values_equal, 6             // rdi = t1, rsi = p1, rdx = t2, rcx = p2 -> eax
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  lea rax, [rbx - T_INT]
  cmp rax, 1
  ja 3f
  lea rax, [r13 - T_INT]
  cmp rax, 1
  ja 8f                        // number vs non-number
  cmp rbx, T_INT
  jne 1f
  cmp r13, T_INT
  jne 1f
  xor eax, eax
  cmp r12, r14
  sete al
  EPI
1:
  mov rdi, rbx
  mov rsi, r12
  call to_double
  movq r15, xmm0
  mov rdi, r13
  mov rsi, r14
  call to_double
  movaps xmm1, xmm0
  movq xmm0, r15
  ucomisd xmm0, xmm1
  jp 8f
  jne 8f
  mov eax, 1
  EPI
3:
  cmp rbx, r13
  jne 8f
  cmp rbx, T_NIL
  je 9f
  cmp rbx, T_STR
  je 4f
  cmp rbx, T_ARR
  je 5f
  xor eax, eax                 // bool, function, class, instance: identity
  cmp r12, r14
  sete al
  EPI
4:
  mov rdi, r12
  mov rsi, r14
  call str_eq
  EPI
5:
  cmp r12, r14
  je 9f
  mov rax, [r12 + AR_LEN]
  cmp rax, [r14 + AR_LEN]
  jne 8f
  xor r15d, r15d
6:
  cmp r15, [r12 + AR_LEN]
  jae 9f
  mov rax, r15
  shl rax, 4
  mov rcx, [r12 + AR_DATA]
  mov rdx, [r14 + AR_DATA]
  mov rdi, [rcx + rax]
  mov rsi, [rcx + rax + 8]
  mov r8, [rdx + rax]
  mov rcx, [rdx + rax + 8]
  mov rdx, r8
  call values_equal
  test eax, eax
  jz 8f
  inc r15
  jmp 6b
8:
  xor eax, eax
  EPI
9:
  mov eax, 1
  EPI

// ---------------------------------------------------------------- classes
.balign 16
inherits:                      // rdi = class, rsi = other -> eax
1:
  test rdi, rdi
  jz 2f
  cmp rdi, rsi
  je 3f
  mov rdi, [rdi + CL_SUPER]
  jmp 1b
2:
  xor eax, eax
  ret
3:
  mov eax, 1
  ret

FN class_find_method, 0        // rdi = class, rsi = name -> rax = function object or 0
  mov rbx, rdi
  mov r12, rsi
1:
  test rbx, rbx
  jz 9f
  mov rcx, [rbx + TB_COUNT]
  mov r8, [rbx + TB_ENT]
2:
  test rcx, rcx
  jz 4f
  cmp [r8 + E_NAME], r12
  jne 3f
  mov rax, [r8 + E_FLAGS]
  and eax, EF_METHOD | EF_STATIC
  cmp eax, EF_METHOD
  jne 3f
  mov rax, [r8 + E_PAY]
  EPI
3:
  add r8, E_SIZE
  dec rcx
  jmp 2b
4:
  mov rbx, [rbx + CL_SUPER]
  jmp 1b
9:
  xor eax, eax
  EPI

FN class_find_static, 0        // rdi = class, rsi = name -> rax = entry (static field or method) or 0
  mov rbx, rdi
  mov r12, rsi
1:
  test rbx, rbx
  jz 9f
  mov rcx, [rbx + TB_COUNT]
  mov r8, [rbx + TB_ENT]
2:
  test rcx, rcx
  jz 4f
  cmp [r8 + E_NAME], r12
  jne 3f
  test dword ptr [r8 + E_FLAGS], EF_STATIC
  jz 3f
  mov rax, r8
  EPI
3:
  add r8, E_SIZE
  dec rcx
  jmp 2b
4:
  mov rbx, [rbx + CL_SUPER]
  jmp 1b
9:
  xor eax, eax
  EPI

// Verify a class member entry is accessible. rdi=entry, rsi=member name.
FN private_check, 3
  mov rbx, rdi
  mov r12, rsi
  test dword ptr [rbx + E_FLAGS], EF_PRIVATE
  jz .Lprivate_ok
  mov rax, G(access_class)
  test rax, rax
  jz .Lprivate_denied
  cmp rax, [rbx + E_OWNER]
  je .Lprivate_ok
.Lprivate_denied:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Member '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r12
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "' is private"
  call sb_putcs
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
.Lprivate_ok:
  xor eax, eax
  EPI

// Verify a method object; FO_OWNER bit 0 encodes its private flag.
FN private_check_method, 3     // rdi=function object, rsi=method name
  mov rbx, rdi
  mov r12, rsi
  mov rax, [rbx + 72]
  test rax, rax
  jz .Lprivmethod_ok
  test al, 1
  jz .Lprivmethod_ok
  and rax, -2
  mov rcx, G(access_class)
  cmp rax, rcx
  je .Lprivmethod_ok
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Member '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r12
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "' is private"
  call sb_putcs
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
.Lprivmethod_ok:
  xor eax, eax
  EPI

// copy of a user function whose closure additionally defines `this`
FN fn_bind, 0                  // rdi = function object, rsi = instance, edx = 1 if the result may escape
  mov rbx, rdi
  mov r12, rsi
  mov r14, rdx
  test r14, r14
  jz 1f
  inc G(closure_cnt)           // a bound method is a closure over its `this` scope
1:
  mov edi, FO_SIZE
  test r14, r14
  jz 2f
  call hx_alloc                // may escape: ordinary memory
  jmp 3f
2:
  call env_alloc               // used only as a callee: reclaimed with the call's scopes
3:
  mov r13, rax
  mov rdi, rax
  mov rsi, rbx
  mov edx, FO_SIZE
  CALLC memcpy
  mov rdi, [rbx + FO_ENV]
  call env_new
  mov [r13 + FO_ENV], rax
  mov rdi, rax
  lea rcx, [rip + known_ptrs]
  mov rsi, [rcx + K_this*8]
  mov edx, T_INST
  mov rcx, r12
  xor r8d, r8d
  mov r9d, EF_CONST
  call env_define
  mov rax, r13
  EPI

// ------------------------------------------------------------ stringify
FN str_quote, 0                // rdi = sb, rsi = String*  (appends "..." with escapes)
  mov rbx, rdi
  mov r12, rsi
  mov esi, '"'
  call sb_putc
  xor r13d, r13d
1:
  cmp r13, [r12]
  jae 8f
  movzx r14d, byte ptr [r12 + 16 + r13]
  cmp r14d, '"'
  je 5f
  cmp r14d, '\\'
  je 5f
  cmp r14d, 10
  jne 2f
  mov r14d, 'n'
  jmp 5f
2:
  cmp r14d, 9
  jne 3f
  mov r14d, 't'
  jmp 5f
3:
  cmp r14d, 13
  jne 4f
  mov r14d, 'r'
  jmp 5f
4:
  mov rdi, rbx
  mov esi, r14d
  call sb_putc
  jmp 6f
5:                              // escaped character
  mov rdi, rbx
  mov esi, '\\'
  call sb_putc
  mov rdi, rbx
  mov esi, r14d
  call sb_putc
6:
  inc r13
  jmp 1b
8:
  mov rdi, rbx
  mov esi, '"'
  call sb_putc
  EPI

FN repr, 0                     // rdi = sb, rsi = tag, rdx = payload, rcx = depth
  cmp rsi, T_STR
  jne 1f
  mov rsi, rdx
  call str_quote
  EPI
1:
  call stringify
  EPI

FN stringify, 4                // rdi = sb, rsi = tag, rdx = payload, rcx = depth
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  cmp r12, T_NIL
  je 10f
  cmp r12, T_BOOL
  je 11f
  cmp r12, T_INT
  je 12f
  cmp r12, T_FLOAT
  je 13f
  cmp r12, T_STR
  je 14f
  cmp r12, T_ARR
  je 15f
  cmp r12, T_FN
  je 20f
  cmp r12, T_CLS
  je 21f
  cmp r12, T_PTR
  je 22f
  jmp 30f
10:
  mov rdi, rbx
  LEAS rsi, "nil"
  call sb_putcs
  EPI
11:
  mov rdi, rbx
  test r13, r13
  jz 1f
  LEAS rsi, "true"
  call sb_putcs
  EPI
1:
  LEAS rsi, "false"
  call sb_putcs
  EPI
12:
  mov rdi, rbx
  mov rsi, r13
  call sb_putint
  EPI
13:
  mov rdi, rbx
  movq xmm0, r13
  call fmt_float
  EPI
14:
  mov rdi, rbx
  mov rsi, r13
  call sb_putstr
  EPI
15:                             // array: [a, b, c]
  mov rdi, rbx
  cmp r14, 8
  jbe 1f
  LEAS rsi, "[...]"
  call sb_putcs
  EPI
1:
  mov esi, '['
  call sb_putc
  xor r15d, r15d
2:
  cmp r15, [r13 + AR_LEN]
  jae 4f
  test r15, r15
  jz 3f
  mov rdi, rbx
  LEAS rsi, ", "
  call sb_putcs
3:
  mov rax, r15
  shl rax, 4
  add rax, [r13 + AR_DATA]
  mov rdi, rbx
  mov rsi, [rax]
  mov rdx, [rax + 8]
  lea rcx, [r14 + 1]
  call repr
  inc r15
  jmp 2b
4:
  mov rdi, rbx
  mov esi, ']'
  call sb_putc
  EPI
20:                             // function
  mov rdi, rbx
  cmp qword ptr [r13 + FO_KIND], 1
  jne 1f
  LEAS rsi, "<native fn "
  call sb_putcs
  jmp 2f
1:
  cmp qword ptr [r13 + FO_NAME], 0
  jne 3f
  LEAS rsi, "<fn>"
  call sb_putcs
  EPI
3:
  LEAS rsi, "<fn "
  call sb_putcs
2:
  mov rdi, rbx
  mov rsi, [r13 + FO_NAME]
  call sb_putstr
  mov rdi, rbx
  mov esi, '>'
  call sb_putc
  EPI
22:
  mov rdi, rbx
  LEAS rsi, "<ptr>"
  call sb_putcs
  EPI
21:                             // class
  mov rdi, rbx
  LEAS rsi, "<class "
  call sb_putcs
  mov rdi, rbx
  mov rsi, [r13 + CL_NAME]
  call sb_putstr
  mov rdi, rbx
  mov esi, '>'
  call sb_putc
  EPI
30:                             // instance: toString() or Name(field=value, ...)
  mov r15, [r13 + TB_LINK]     // class
  cmp r14, 8
  jbe 1f
  mov rdi, rbx
  mov rsi, [r15 + CL_NAME]
  call sb_putstr
  mov rdi, rbx
  LEAS rsi, "(...)"
  call sb_putcs
  EPI
1:
  mov rdi, r15
  lea rcx, [rip + known_ptrs]
  mov rsi, [rcx + K_toString*8]
  call class_find_method
  test rax, rax
  jz 2f
  mov rdi, rax
  mov rsi, r13
  xor edx, edx
  call fn_bind
  mov rsi, rax
  mov edi, T_FN
  xor edx, edx
  xor ecx, ecx
  call call_value
  mov rsi, rax
  mov rdx, rdx
  mov rdi, rbx
  mov rcx, r14
  inc rcx
  call stringify
  EPI
2:
  mov rdi, rbx
  mov rsi, [r15 + CL_NAME]
  call sb_putstr
  mov rdi, rbx
  mov esi, '('
  call sb_putc
  xor r15d, r15d
3:
  cmp r15, [r13 + TB_COUNT]
  jae 6f
  test r15, r15
  jz 4f
  mov rdi, rbx
  LEAS rsi, ", "
  call sb_putcs
4:
  lea rax, [r15 + r15*2]
  shl rax, 4
  add rax, [r13 + TB_ENT]
  mov L(0), rax
  mov rdi, rbx
  mov rsi, [rax + E_NAME]
  call sb_putstr
  mov rdi, rbx
  mov esi, '='
  call sb_putc
  mov rax, L(0)
  mov rdi, rbx
  mov rsi, [rax + E_TAG]
  mov rdx, [rax + E_PAY]
  lea rcx, [r14 + 1]
  call repr
  inc r15
  jmp 3b
6:
  mov rdi, rbx
  mov esi, ')'
  call sb_putc
  EPI

// ------------------------------------------------------------------- types
FN type_str, 2                 // rdi = sb, rsi = type node: appends its text
  mov rbx, rdi
  mov r12, rsi
  mov eax, [r12]
  cmp eax, TY_NAMED
  jne 1f
  mov rsi, [r12 + N_B]
  mov rdi, rbx
  call sb_putstr
  EPI
1:
  cmp eax, TY_ARRAY
  jne 2f
  mov r13, [r12 + N_D]
  mov eax, [r13]
  mov r14d, eax
  cmp r14d, TY_UNION
  je 5f
  cmp r14d, TY_FUNC
  je 5f
  mov rdi, rbx
  mov rsi, r13
  call type_str
  jmp 6f
5:
  mov rdi, rbx
  mov esi, '('
  call sb_putc
  mov rdi, rbx
  mov rsi, r13
  call type_str
  mov rdi, rbx
  mov esi, ')'
  call sb_putc
6:
  mov rdi, rbx
  LEAS rsi, "[]"
  call sb_putcs
  EPI
2:
  cmp eax, TY_UNION
  jne 3f
  mov r13, [r12 + N_C]
  xor r14d, r14d
7:
  cmp r14, [r13]
  jae 9f
  test r14, r14
  jz 8f
  mov rdi, rbx
  LEAS rsi, " | "
  call sb_putcs
8:
  mov rdi, rbx
  mov rsi, [r13 + 8 + r14*8]
  call type_str
  inc r14
  jmp 7b
3:                              // fn(types) -> ret
  mov rdi, rbx
  LEAS rsi, "fn("
  call sb_putcs
  mov r13, [r12 + N_C]
  xor r14d, r14d
4:
  cmp r14, [r13]
  jae 5f
  test r14, r14
  jz 3f
  mov rdi, rbx
  LEAS rsi, ", "
  call sb_putcs
3:
  mov rdi, rbx
  mov rsi, [r13 + 8 + r14*8]
  call type_str
  inc r14
  jmp 4b
5:
  mov rdi, rbx
  mov esi, ')'
  call sb_putc
  cmp qword ptr [r12 + N_D], 0
  je 9f
  mov rdi, rbx
  LEAS rsi, " -> "
  call sb_putcs
  mov rdi, rbx
  mov rsi, [r12 + N_D]
  call type_str
9:
  EPI

FN type_equal, 8               // rdi = type a, rsi = type b -> eax
  mov r12, rdi
  mov r13, rsi
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, r12
  call type_str
  lea rdi, LA(2)
  call sb_finish
  mov rbx, rax
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, r13
  call type_str
  lea rdi, LA(2)
  call sb_finish
  mov rdi, rbx
  mov rsi, rax
  call str_eq
  EPI

// Does value (tag, payload) conform to the type?  (No implicit conversion here.)
FN type_matches, 2             // rdi = tag, rsi = payload, rdx = type, rcx = type env, r8 = depth -> eax
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov r15, r8
  mov eax, [r13]
  cmp eax, TY_NAMED
  je 20f
  cmp eax, TY_UNION
  je 10f
  cmp eax, TY_ARRAY
  je 11f
  // TY_FUNC: a callable whose arity accepts that many arguments
  cmp rbx, T_FN
  jne 90f
  mov rax, [r13 + N_C]
  mov rax, [rax]
  cmp rax, [r12 + FO_MIN]
  jl 90f
  mov rcx, [r12 + FO_MAX]
  test rcx, rcx
  js 91f
  cmp rax, rcx
  jg 90f
  jmp 91f
10:                             // union: any member
  mov L(0), 0
1:
  mov rcx, L(0)
  mov rax, [r13 + N_C]
  cmp rcx, [rax]
  jae 90f
  mov rdx, [rax + 8 + rcx*8]
  mov rdi, rbx
  mov rsi, r12
  mov rcx, r14
  mov r8, r15
  call type_matches
  test eax, eax
  jnz 91f
  inc L(0)
  jmp 1b
11:                             // array: all elements
  cmp rbx, T_ARR
  jne 90f
  mov L(0), 0
2:
  mov rcx, L(0)
  cmp rcx, [r12 + AR_LEN]
  jae 91f
  shl rcx, 4
  add rcx, [r12 + AR_DATA]
  mov rdi, [rcx]
  mov rsi, [rcx + 8]
  mov rdx, [r13 + N_D]
  mov rcx, r14
  mov r8, r15
  call type_matches
  test eax, eax
  jz 90f
  inc L(0)
  jmp 2b
20:                             // named: builtin, alias or class
  mov rax, [r13 + N_A]
  cmp rax, BI_INT
  je 30f
  cmp rax, BI_FLOAT
  je 31f
  cmp rax, BI_NUMBER
  je 32f
  cmp rax, BI_STRING
  je 33f
  cmp rax, BI_BOOL
  je 34f
  cmp rax, BI_ANY
  je 91f
  cmp rax, BI_NIL
  je 35f
  cmp rax, BI_VOID
  je 35f
  cmp rax, BI_FUNCTION
  je 36f
  cmp rax, BI_PTR
  je 37f
  cmp r15, 64
  jbe 3f
  LEAS rdi, "Type '"
  mov rsi, [r13 + N_B]
  LEAS rdx, "' is defined in terms of itself"
  call fail_ty_n
3:
  mov rdi, r14                 // alias?
  mov rsi, [r13 + N_B]
  mov edx, 1
  call env_find
  test rax, rax
  jz 4f
  mov rcx, rdx                 // owner env
  mov rdx, [rax + E_PAY]
  mov rdi, rbx
  mov rsi, r12
  lea r8, [r15 + 1]
  call type_matches
  EPI
4:
  mov rdi, r14                 // class?
  mov rsi, [r13 + N_B]
  xor edx, edx
  call env_find
  test rax, rax
  jz 5f
  cmp qword ptr [rax + E_TAG], T_CLS
  jne 5f
  cmp rbx, T_INST
  jne 90f
  mov rsi, [rax + E_PAY]
  mov rdi, [r12 + TB_LINK]
  call inherits
  EPI
5:
  LEAS rdi, "Unknown type '"
  mov rsi, [r13 + N_B]
  LEAS rdx, "'"
  call fail_ty_n
30:
  cmp rbx, T_INT
  je 91f
  jmp 90f
31:
  cmp rbx, T_FLOAT
  je 91f
  jmp 90f
32:
  lea rax, [rbx - T_INT]
  cmp rax, 1
  jbe 91f
  jmp 90f
33:
  cmp rbx, T_STR
  je 91f
  jmp 90f
34:
  cmp rbx, T_BOOL
  je 91f
  jmp 90f
35:
  test rbx, rbx
  jz 91f
  jmp 90f
36:
  cmp rbx, T_FN
  je 91f
  jmp 90f
37:
  cmp rbx, T_PTR
  je 91f
90:
  xor eax, eax
  EPI
91:
  mov eax, 1
  EPI

// Checks a value against a declared type; an int is widened to float when that
// makes it fit.  Fails with a type error naming `prefix 'name'`.
FN coerce, 8                   // rdi = tag, rsi = payload, rdx = type, rcx = type env,
                               // r8 = prefix C string, r9 = name String* -> rax:rdx
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov r15, r8
  mov L(7), r9
  test r13, r13
  jz 8f
  call type_matches_wrap
  test eax, eax
  jnz 8f
  cmp rbx, T_INT
  jne 5f
  cvtsi2sd xmm0, r12
  movq rsi, xmm0
  mov edi, T_FLOAT
  mov rdx, r13
  mov rcx, r14
  xor r8d, r8d
  call type_matches
  test eax, eax
  jz 5f
  cvtsi2sd xmm0, r12
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI
5:                              // build the error message
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, r15
  call sb_putcs
  lea rdi, LA(2)
  LEAS rsi, "'"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, L(7)
  call sb_putstr
  mov rsi, G(coerce_ctx)       // parameters: "parameter 'b' of 'f' expects ..."
  test rsi, rsi
  jz 7f
  mov G(coerce_ctx), 0
  mov r14, rsi
  lea rdi, LA(2)
  LEAS rsi, "' of '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r14
  call sb_putstr
7:
  lea rdi, LA(2)
  LEAS rsi, "' expects "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  call type_str
  lea rdi, LA(2)
  LEAS rsi, " but got "
  call sb_putcs
  mov rdi, rbx
  mov rsi, r12
  call value_type_name
  mov rsi, rax
  lea rdi, LA(2)
  call sb_putstr
  test rbx, rbx
  jz 6f
  lea rdi, LA(2)
  LEAS rsi, " ("
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, rbx
  mov rdx, r12
  xor ecx, ecx
  call repr
  lea rdi, LA(2)
  mov esi, ')'
  call sb_putc
6:
  lea rdi, LA(2)
  LEAS rsi, "Type error"
  mov rdx, G(cur_line)
  call fail_sb
8:
  mov rax, rbx
  mov rdx, r12
  EPI

.balign 16
type_matches_wrap:             // (rbx, r12, r13, r14) -> eax ; helper for coerce
  mov rdi, rbx
  mov rsi, r12
  mov rdx, r13
  mov rcx, r14
  xor r8d, r8d
  jmp type_matches

// default value of a type, for `let int x` / `string name` with no initializer
FN zero_value, 2               // rdi = type, rsi = type env, rdx = out Value*, rcx = depth -> eax = found
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  cmp r14, 64
  ja 90f
  mov eax, [rbx]
  cmp eax, TY_ARRAY
  je 10f
  cmp eax, TY_FUNC
  je 90f
  cmp eax, TY_UNION
  je 11f
  mov rax, [rbx + N_A]         // named
  cmp rax, BI_INT
  je 20f
  cmp rax, BI_NUMBER
  je 20f
  cmp rax, BI_FLOAT
  je 21f
  cmp rax, BI_STRING
  je 22f
  cmp rax, BI_BOOL
  je 23f
  cmp rax, BI_ANY
  je 24f
  cmp rax, BI_NIL
  je 24f
  cmp rax, BI_VOID
  je 24f
  cmp rax, BI_FUNCTION
  je 90f
  cmp rax, BI_PTR
  je 25f
  mov rdi, r12                 // alias
  mov rsi, [rbx + N_B]
  mov edx, 1
  call env_find
  test rax, rax
  jz 90f
  mov rdi, [rax + E_PAY]
  mov rsi, rdx
  mov rdx, r13
  lea rcx, [r14 + 1]
  call zero_value
  EPI
10:
  xor edi, edi
  call arr_new
  mov qword ptr [r13], T_ARR
  mov [r13 + 8], rax
  jmp 91f
11:                             // union: nil if it allows nil, else the first member
  mov L(0), 0
1:
  mov rcx, L(0)
  mov rax, [rbx + N_C]
  cmp rcx, [rax]
  jae 2f
  mov rdx, [rax + 8 + rcx*8]
  cmp dword ptr [rdx], TY_NAMED
  jne 3f
  mov rcx, [rdx + N_A]
  cmp rcx, BI_NIL
  je 24f
  cmp rcx, BI_ANY
  je 24f
  cmp rcx, BI_VOID
  je 24f
3:
  inc L(0)
  jmp 1b
2:
  mov rax, [rbx + N_C]
  mov rdi, [rax + 8]
  mov rsi, r12
  mov rdx, r13
  lea rcx, [r14 + 1]
  call zero_value
  EPI
20:
  mov qword ptr [r13], T_INT
  mov qword ptr [r13 + 8], 0
  jmp 91f
21:
  mov qword ptr [r13], T_FLOAT
  mov qword ptr [r13 + 8], 0
  jmp 91f
22:
  mov qword ptr [r13], T_STR
  mov rax, G(str_empty)
  mov [r13 + 8], rax
  jmp 91f
23:
  mov qword ptr [r13], T_BOOL
  mov qword ptr [r13 + 8], 0
  jmp 91f
24:
  mov qword ptr [r13], T_NIL
  mov qword ptr [r13 + 8], 0
  jmp 91f
25:
  mov qword ptr [r13], T_PTR
  mov qword ptr [r13 + 8], 0
91:
  mov eax, 1
  EPI
90:
  xor eax, eax
  EPI
// ============================================================== EXPRESSIONS
DATA
.balign 8
eval_table:
  .quad 0, ev_lit, ev_var, ev_assign, ev_update, ev_unary, ev_binary, ev_logical
  .quad ev_ternary, ev_call, ev_get, ev_index, ev_this, ev_super, ev_lambda, ev_array, ev_is

.macro SETLINE node               // cur_line = line of the AST node (clobbers only r11)
  mov r11d, dword ptr [\node + 4]
  mov G(cur_line), r11
.endm

TEXT
.balign 16
eval:                          // rdi = node, rsi = environment -> rax:rdx = value
  mov eax, [rdi]
  lea rcx, [rip + eval_table]
  jmp qword ptr [rcx + rax*8]

.balign 16
truthy:                        // rdi = tag, rsi = payload -> eax
  xor eax, eax
  test rdi, rdi
  jz 1f
  mov eax, 1
  cmp rdi, T_BOOL
  jne 1f
  test rsi, rsi
  setne al
  movzx eax, al
1:
  ret

.balign 16
ev_lit:
  mov rax, [rdi + N_A]
  mov rdx, [rdi + N_B]
  ret

FN ev_var, 0
  mov rbx, rdi
  mov rdi, rsi
  mov rsi, [rbx + N_A]
  xor edx, edx
  call env_find
  test rax, rax
  jz 1f
  mov rdx, [rax + E_PAY]
  mov rax, [rax + E_TAG]
  EPI
1:
  SETLINE rbx
  LEAS rdi, "Undefined variable '"
  mov rsi, [rbx + N_A]
  LEAS rdx, "'"
  call fail_rt_n
  EPI

FN ev_this, 0
  mov rbx, rdi
  mov rdi, rsi
  lea rcx, [rip + known_ptrs]
  mov rsi, [rcx + K_this*8]
  xor edx, edx
  call env_find
  test rax, rax
  jz 1f
  mov rdx, [rax + E_PAY]
  mov rax, [rax + E_TAG]
  EPI
1:
  SETLINE rbx
  LEAS rdi, "'this' can only be used inside a method"
  call fail_rt
  EPI

FN ev_ternary, 0
  mov rbx, rdi
  mov r12, rsi
  mov rdi, [rbx + N_A]
  call eval
  mov rdi, rax
  mov rsi, rdx
  call truthy
  mov rdi, [rbx + N_B]
  test eax, eax
  jnz 1f
  mov rdi, [rbx + N_C]
1:
  mov rsi, r12
  call eval
  EPI

FN ev_logical, 2
  mov rbx, rdi
  mov r12, rsi
  mov rdi, [rbx + N_A]
  call eval
  mov L(0), rax
  mov L(1), rdx
  mov rdi, rax
  mov rsi, rdx
  call truthy
  cmp qword ptr [rbx + N_B], TK_OROR
  jne 1f
  test eax, eax                // ||: a truthy left operand is the result
  jnz 2f
  jmp 3f
1:
  test eax, eax                // &&: a falsy left operand is the result
  jz 2f
3:
  mov rdi, [rbx + N_C]
  mov rsi, r12
  call eval
  EPI
2:
  mov rax, L(0)
  mov rdx, L(1)
  EPI

FN ev_unary, 0
  mov rbx, rdi
  mov r14, rsi
  cmp qword ptr [rbx + N_A], TK_AMP
  je .Lev_address
  mov rdi, [rbx + N_B]
  mov rsi, r14
  call eval
  mov r12, rax
  mov r13, rdx
  SETLINE rbx
  cmp qword ptr [rbx + N_A], TK_STAR
  je .Lev_deref
  cmp qword ptr [rbx + N_A], TK_BANG
  jne 1f
  mov rdi, r12
  mov rsi, r13
  call truthy
  xor eax, 1
  mov edx, eax
  mov eax, T_BOOL
  EPI
1:
  cmp r12, T_INT
  jne 2f
  neg r13
  mov eax, T_INT
  mov rdx, r13
  EPI
2:
  cmp r12, T_FLOAT
  jne 3f
  btc r13, 63
  mov eax, T_FLOAT
  mov rdx, r13
  EPI
3:
  mov rdi, r12
  mov rsi, r13
  call value_type_name
  mov rsi, rax
  LEAS rdi, "Unary '-' requires a number but got "
  LEAS rdx, ""
  call fail_rt_n
  EPI
.Lev_address:
  mov rdi, [rbx + N_B]
  call p_assignable
  test eax, eax
  jz .Lev_bad_address
  mov edi, 56
  call hx_alloc
  mov r13, rax
  mov rdi, r13
  mov rsi, [rbx + N_B]
  mov rdx, r14
  call lv_prepare
  mov eax, T_PTR
  mov rdx, r13
  EPI
.Lev_bad_address:
  LEAS rdi, "Address-of '&' requires an assignable target"
  call fail_rt
  EPI
.Lev_deref:
  cmp r12, T_PTR
  jne .Lev_bad_ptr
  test r13, r13
  jz .Lev_null_ptr
  mov rdi, r13
  call lv_get
  EPI
.Lev_bad_ptr:
  LEAS rdi, "Unary '*' requires a pointer"
  call fail_rt
  EPI
.Lev_null_ptr:
  LEAS rdi, "Cannot dereference a null pointer"
  call fail_rt
  EPI

// ------------------------------------------------------------ binary operators
.balign 16
op_text:                       // rdi = operator token -> rax = C string
  lea rax, [rip + 2f]
  cmp rdi, TK_PLUS
  je 1f
  lea rax, [rip + 3f]
  cmp rdi, TK_MINUS
  je 1f
  lea rax, [rip + 4f]
  cmp rdi, TK_STAR
  je 1f
  lea rax, [rip + 5f]
  cmp rdi, TK_SLASH
  je 1f
  lea rax, [rip + 6f]
  cmp rdi, TK_PERCENT
  je 1f
  lea rax, [rip + 7f]
  cmp rdi, TK_LT
  je 1f
  lea rax, [rip + 8f]
  cmp rdi, TK_LE
  je 1f
  lea rax, [rip + 9f]
  cmp rdi, TK_GT
  je 1f
  lea rax, [rip + 10f]
1:
  ret
  .section RO_SECT
2: .asciz "+"
3: .asciz "-"
4: .asciz "*"
5: .asciz "/"
6: .asciz "%"
7: .asciz "<"
8: .asciz "<="
9: .asciz ">"
10: .asciz ">="
  .text

FN str_compare, 0              // rdi = String* a, rsi = String* b -> rax = <0, 0, >0
  mov rbx, rdi
  mov r12, rsi
  mov r13, [rbx]
  cmp r13, [r12]
  jbe 1f
  mov r13, [r12]
1:
  lea rdi, [rbx + 16]
  lea rsi, [r12 + 16]
  mov rdx, r13
  CALLC memcmp
  movsxd rax, eax
  test rax, rax
  jnz 2f
  mov rax, [rbx]
  sub rax, [r12]
2:
  EPI

FN apply_binary, 4             // rdi = op token, rsi = ltag, rdx = lpay, rcx = rtag, r8 = rpay
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov r15, r8
  cmp rbx, TK_EQEQ
  je 50f
  cmp rbx, TK_BANGEQ
  je 51f
  cmp rbx, TK_PLUS
  je 10f
  cmp rbx, TK_LT
  jb 4f
  cmp rbx, TK_GE
  jbe 40f
4:
  cmp rbx, TK_MINUS
  je 11f
  cmp rbx, TK_STAR
  je 12f
  cmp rbx, TK_SLASH
  je 13f
  cmp rbx, TK_PERCENT
  je 14f
  jmp 90f
// --- helpers: numeric operands?  (jumps to 90f when not)
10:                             // +
  cmp r12, T_INT
  jne 1f
  cmp r14, T_INT
  jne 1f
  mov rdx, r13
  add rdx, r15
  mov eax, T_INT
  EPI
1:
  lea rax, [r12 - T_INT]
  cmp rax, 1
  ja 2f
  lea rax, [r14 - T_INT]
  cmp rax, 1
  ja 2f
  call bin_load_doubles
  addsd xmm0, xmm1
  jmp 80f
2:
  cmp r12, T_STR
  je 3f
  cmp r14, T_STR
  jne 5f
3:                              // string concatenation, anything is stringified
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, r12
  mov rdx, r13
  xor ecx, ecx
  call stringify
  lea rdi, LA(2)
  mov rsi, r14
  mov rdx, r15
  xor ecx, ecx
  call stringify
  lea rdi, LA(2)
  call sb_finish
  mov rdx, rax
  mov eax, T_STR
  EPI
5:
  cmp r12, T_ARR
  jne 90f
  cmp r14, T_ARR
  jne 90f
  mov rdi, [r13 + AR_LEN]
  add rdi, [r15 + AR_LEN]
  call arr_new
  mov rbx, rax
  xor ecx, ecx
6:
  cmp rcx, [r13 + AR_LEN]
  jae 7f
  mov L(0), rcx
  mov rax, rcx
  shl rax, 4
  add rax, [r13 + AR_DATA]
  mov rdi, rbx
  mov rsi, [rax]
  mov rdx, [rax + 8]
  call arr_push
  mov rcx, L(0)
  inc rcx
  jmp 6b
7:
  xor ecx, ecx
8:
  cmp rcx, [r15 + AR_LEN]
  jae 9f
  mov L(0), rcx
  mov rax, rcx
  shl rax, 4
  add rax, [r15 + AR_DATA]
  mov rdi, rbx
  mov rsi, [rax]
  mov rdx, [rax + 8]
  call arr_push
  mov rcx, L(0)
  inc rcx
  jmp 8b
9:
  mov eax, T_ARR
  mov rdx, rbx
  EPI
11:                             // -
  cmp r12, T_INT
  jne 1f
  cmp r14, T_INT
  jne 1f
  mov rdx, r13
  sub rdx, r15
  mov eax, T_INT
  EPI
1:
  call bin_both_numbers
  test eax, eax
  jz 90f
  call bin_load_doubles
  subsd xmm0, xmm1
  jmp 80f
12:                             // *
  cmp r12, T_INT
  jne 1f
  cmp r14, T_INT
  jne 1f
  mov rdx, r13
  imul rdx, r15
  mov eax, T_INT
  EPI
1:
  call bin_both_numbers
  test eax, eax
  jz 90f
  call bin_load_doubles
  mulsd xmm0, xmm1
  jmp 80f
13:                             // /
  call bin_both_numbers
  test eax, eax
  jz 90f
  cmp r12, T_INT
  jne 2f
  cmp r14, T_INT
  jne 2f
  test r15, r15
  jnz 1f
  LEAS rdi, "Division by zero"
  call fail_rt
1:
  mov rax, r13
  cmp r15, -1
  jne 3f
  neg rax
  mov rdx, rax
  mov eax, T_INT
  EPI
3:
  cqo
  idiv r15
  mov rdx, rax
  mov eax, T_INT
  EPI
2:
  call bin_load_doubles
  xorpd xmm2, xmm2
  ucomisd xmm1, xmm2
  jp 4f
  jne 4f
  LEAS rdi, "Division by zero"
  call fail_rt
4:
  divsd xmm0, xmm1
  jmp 80f
14:                             // %
  call bin_both_numbers
  test eax, eax
  jz 90f
  cmp r12, T_INT
  jne 2f
  cmp r14, T_INT
  jne 2f
  test r15, r15
  jnz 1f
  LEAS rdi, "Modulo by zero"
  call fail_rt
1:
  xor edx, edx
  cmp r15, -1
  je 3f
  mov rax, r13
  cqo
  idiv r15
3:
  mov eax, T_INT
  EPI
2:
  call bin_load_doubles
  xorpd xmm2, xmm2
  ucomisd xmm1, xmm2
  jp 4f
  jne 4f
  LEAS rdi, "Modulo by zero"
  call fail_rt
4:
  CALLC fmod
  jmp 80f
40:                             // < <= > >=
  cmp r12, T_INT
  jne 1f
  cmp r14, T_INT
  jne 1f
  xor eax, eax
  cmp r13, r15
  cmp rbx, TK_LT
  je 41f
  cmp rbx, TK_LE
  je 42f
  cmp rbx, TK_GT
  je 43f
  jmp 44f
41:
  cmp r13, r15
  setl al
  jmp 85f
42:
  cmp r13, r15
  setle al
  jmp 85f
43:
  cmp r13, r15
  setg al
  jmp 85f
44:
  cmp r13, r15
  setge al
  jmp 85f
1:
  call bin_both_numbers
  test eax, eax
  jz 2f
  call bin_load_doubles
  cmp rbx, TK_LT
  je 45f
  cmp rbx, TK_LE
  je 46f
  cmp rbx, TK_GT
  je 47f
  ucomisd xmm0, xmm1            // >=
  setae al
  jmp 85f
45:
  ucomisd xmm1, xmm0            // a < b  <=>  b above a (false for NaN)
  seta al
  jmp 85f
46:
  ucomisd xmm1, xmm0
  setae al
  jmp 85f
47:
  ucomisd xmm0, xmm1
  seta al
  jmp 85f
2:
  cmp r12, T_STR
  jne 90f
  cmp r14, T_STR
  jne 90f
  mov rdi, r13
  mov rsi, r15
  call str_compare
  cmp rbx, TK_LT
  je 48f
  cmp rbx, TK_LE
  je 49f
  cmp rbx, TK_GT
  je 52f
  test rax, rax
  setns al
  jmp 85f
48:
  test rax, rax
  sets al
  jmp 85f
49:
  test rax, rax
  setle al
  jmp 85f
52:
  test rax, rax
  setg al
  jmp 85f
50:
  mov rdi, r12
  mov rsi, r13
  mov rdx, r14
  mov rcx, r15
  call values_equal
  jmp 86f
51:
  mov rdi, r12
  mov rsi, r13
  mov rdx, r14
  mov rcx, r15
  call values_equal
  xor eax, 1
  jmp 86f
80:                             // float result in xmm0
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI
85:
  movzx eax, al
86:
  mov edx, eax
  mov eax, T_BOOL
  EPI
90:                             // operator cannot be applied
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Operator '"
  call sb_putcs
  mov rdi, rbx
  call op_text
  mov rsi, rax
  lea rdi, LA(2)
  call sb_putcs
  cmp rbx, TK_LT
  jb 91f
  cmp rbx, TK_GE
  ja 91f
  lea rdi, LA(2)
  LEAS rsi, "' requires two numbers or two strings but got "
  call sb_putcs
  jmp 92f
91:
  lea rdi, LA(2)
  LEAS rsi, "' cannot be applied to "
  call sb_putcs
92:
  mov rdi, r12
  mov rsi, r13
  call value_type_name
  mov rsi, rax
  lea rdi, LA(2)
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, " and "
  call sb_putcs
  mov rdi, r14
  mov rsi, r15
  call value_type_name
  mov rsi, rax
  lea rdi, LA(2)
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
  EPI

.balign 16
bin_both_numbers:              // (r12, r14 = tags) -> eax = 1 if both are numbers
  xor eax, eax
  lea rcx, [r12 - T_INT]
  cmp rcx, 1
  ja 1f
  lea rcx, [r14 - T_INT]
  cmp rcx, 1
  ja 1f
  mov eax, 1
1:
  ret

.balign 16
bin_load_doubles:              // (r12,r13) and (r14,r15) as numbers -> xmm0, xmm1
  cmp r12, T_INT
  jne 1f
  cvtsi2sd xmm0, r13
  jmp 2f
1:
  movq xmm0, r13
2:
  cmp r14, T_INT
  jne 3f
  cvtsi2sd xmm1, r15
  ret
3:
  movq xmm1, r15
  ret

FN ev_binary, 2
  mov rbx, rdi
  mov r12, rsi
  mov rdi, [rbx + N_A]
  call eval
  mov L(0), rax
  mov L(1), rdx
  mov rdi, [rbx + N_C]
  mov rsi, r12
  call eval
  mov rcx, rax
  mov r8, rdx
  mov rsi, L(0)
  mov rdx, L(1)
  mov rdi, [rbx + N_B]
  SETLINE rbx
  call apply_binary
  EPI

// ------------------------------------------------------- assignable places
// lvalue: +0 kind, +8 name, +16 obj tag, +24 obj payload, +32 index tag,
//         +40 index payload, +48 environment      (7 qwords)
FN lv_prepare, 0               // rdi = lvalue*, rsi = target node, rdx = env
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov eax, [r12]
  mov [rbx], rax
  mov [rbx + 48], r13
  cmp eax, EK_VAR
  jne 1f
  mov rax, [r12 + N_A]
  mov [rbx + 8], rax
  EPI
1:
  cmp eax, EK_GET
  jne 2f
  mov rax, [r12 + N_B]
  mov [rbx + 8], rax
  mov rdi, [r12 + N_A]
  mov rsi, r13
  call eval
  mov [rbx + 16], rax
  mov [rbx + 24], rdx
  EPI
2:
  cmp dword ptr [r12], EK_UNARY
  jne 3f
  cmp qword ptr [r12 + N_A], TK_STAR
  jne 3f
  mov rdi, [r12 + N_B]
  mov rsi, r13
  call eval
  cmp rax, T_PTR
  jne .Llv_bad_ptr
  test rdx, rdx
  jz .Llv_null_ptr
  mov rdi, rbx
  mov rsi, rdx
  mov edx, 56
  CALLC memcpy
  EPI
3:
  mov rdi, [r12 + N_A]
  mov rsi, r13
  call eval
  mov [rbx + 16], rax
  mov [rbx + 24], rdx
  mov rdi, [r12 + N_B]
  mov rsi, r13
  call eval
  mov [rbx + 32], rax
  mov [rbx + 40], rdx
  EPI
.Llv_bad_ptr:
  LEAS rdi, "Unary '*' requires a pointer"
  call fail_rt
  EPI
.Llv_null_ptr:
  LEAS rdi, "Cannot dereference a null pointer"
  call fail_rt
  EPI

FN lv_get, 0                   // rdi = lvalue* -> rax:rdx
  mov rbx, rdi
  cmp qword ptr [rbx], EK_VAR
  jne 2f
  mov rdi, [rbx + 48]
  mov rsi, [rbx + 8]
  xor edx, edx
  call env_find
  test rax, rax
  jnz 1f
  LEAS rdi, "Undefined variable '"
  mov rsi, [rbx + 8]
  LEAS rdx, "'"
  call fail_rt_n
1:
  mov rdx, [rax + E_PAY]
  mov rax, [rax + E_TAG]
  EPI
2:
  cmp qword ptr [rbx], EK_GET
  jne 3f
  mov rdi, [rbx + 16]
  mov rsi, [rbx + 24]
  mov rdx, [rbx + 8]
  xor ecx, ecx
  call get_prop
  EPI
3:
  mov rdi, [rbx + 16]
  mov rsi, [rbx + 24]
  mov rdx, [rbx + 32]
  mov rcx, [rbx + 40]
  call index_get
  EPI

FN lv_set, 0                   // rdi = lvalue*, rsi = tag, rdx = payload -> stored value
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  cmp qword ptr [rbx], EK_VAR
  jne 1f
  mov rdi, [rbx + 48]
  mov rsi, [rbx + 8]
  mov rdx, r12
  mov rcx, r13
  call assign_var
  EPI
1:
  cmp qword ptr [rbx], EK_GET
  jne 2f
  mov rdi, [rbx + 16]
  mov rsi, [rbx + 24]
  mov rdx, [rbx + 8]
  mov rcx, r12
  mov r8, r13
  call set_prop
  EPI
2:
  mov rdi, [rbx + 16]
  mov rsi, [rbx + 24]
  mov rdx, [rbx + 32]
  mov rcx, [rbx + 40]
  mov r8, r12
  mov r9, r13
  call index_set
  EPI

FN assign_var, 0               // rdi = env, rsi = name, rdx = tag, rcx = payload -> stored value
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  xor edx, edx
  call env_find
  test rax, rax
  jnz 1f
  LEAS rdi, "Undefined variable '"
  mov rsi, r12
  LEAS rdx, "'"
  call fail_rt_n
1:
  mov r15, rax
  test dword ptr [rax + E_FLAGS], EF_CONST
  jz 2f
  LEAS rdi, "Cannot assign to constant '"
  mov rsi, r12
  LEAS rdx, "'"
  call fail_rt_n
2:
  mov rdi, r13
  mov rsi, r14
  mov rdx, [r15 + E_TYPE]
  mov rcx, rbx
  LEAS r8, "variable "
  mov r9, r12
  call coerce
  mov [r15 + E_TAG], rax
  mov [r15 + E_PAY], rdx
  EPI

FN ev_assign, 12               // lvalue at LA(6)
  mov rbx, rdi
  mov r12, rsi
  lea rdi, LA(6)
  mov rsi, [rbx + N_A]
  mov rdx, r12
  call lv_prepare
  cmp qword ptr [rbx + N_B], TK_EQUAL
  je 1f
  SETLINE rbx                   // compound: read the current value first
  lea rdi, LA(6)
  call lv_get
  mov L(7), rax
  mov L(8), rdx
1:
  mov rdi, [rbx + N_C]
  mov rsi, r12
  call eval
  cmp qword ptr [rbx + N_B], TK_EQUAL
  je 2f
  mov rcx, rax
  mov r8, rdx
  mov rsi, L(7)
  mov rdx, L(8)
  mov rdi, [rbx + N_B]
  SETLINE rbx
  call apply_binary
2:
  SETLINE rbx
  mov rsi, rax
  lea rdi, LA(6)
  call lv_set
  EPI

FN ev_update, 12               // ++ / -- : lvalue at LA(6), old value L(7):L(8)
  mov rbx, rdi
  mov r12, rsi
  lea rdi, LA(6)
  mov rsi, [rbx + N_A]
  mov rdx, r12
  call lv_prepare
  SETLINE rbx
  lea rdi, LA(6)
  call lv_get
  mov L(7), rax
  mov L(8), rdx
  lea rcx, [rax - T_INT]
  cmp rcx, 1
  jbe 1f
  mov rdi, rax
  mov rsi, rdx
  call value_type_name
  mov rsi, rax
  LEAS rdi, "'++' / '--' requires a number but got "
  LEAS rdx, ""
  call fail_rt_n
1:
  mov rdi, TK_PLUS
  cmp qword ptr [rbx + N_B], 0
  jne 2f
  mov rdi, TK_MINUS
2:
  mov rsi, L(7)
  mov rdx, L(8)
  mov ecx, T_INT
  mov r8d, 1
  SETLINE rbx
  call apply_binary
  mov L(9), rax
  mov L(10), rdx
  SETLINE rbx
  lea rdi, LA(6)
  mov rsi, rax
  call lv_set
  cmp qword ptr [rbx + N_C], 0  // prefix?  new value : old value
  jne 3f
  mov rax, L(7)
  mov rdx, L(8)
  EPI
3:
  mov rax, L(9)
  mov rdx, L(10)
  EPI

// ---------------------------------------------------------- arrays & lambdas
FN ev_array, 1
  mov rbx, rdi
  mov r12, rsi
  mov r13, [rbx + N_A]
  mov rdi, [r13]
  call arr_new
  mov r14, rax
  xor r15d, r15d
1:
  cmp r15, [r13]
  jae 2f
  mov rdi, [r13 + 8 + r15*8]
  mov rsi, r12
  call eval
  mov rdi, r14
  mov rsi, rax
  call arr_push
  inc r15
  jmp 1b
2:
  mov eax, T_ARR
  mov rdx, r14
  EPI

FN fn_make, 0                  // rdi = function decl, rsi = closure env -> rax = function object
  inc G(closure_cnt)
  mov rbx, rdi
  mov r12, rsi
  mov edi, FO_SIZE
  call hx_alloc
  mov rcx, [rbx + N_A]
  mov [rax + FO_NAME], rcx
  mov rcx, [rbx + N_E]
  mov [rax + FO_MIN], rcx
  mov rcx, [rbx + N_F]
  mov [rax + FO_MAX], rcx
  mov [rax + FO_CODE], rbx
  mov [rax + FO_ENV], r12
  EPI

FN ev_lambda, 0
  mov rdi, [rdi + N_A]
  call fn_make
  mov rdx, rax
  mov eax, T_FN
  EPI

FN ev_is, 0
  mov rbx, rdi
  mov r12, rsi
  mov rdi, [rbx + N_A]
  call eval
  SETLINE rbx
  mov rdi, rax
  mov rsi, rdx
  mov rdx, [rbx + N_B]
  mov rcx, r12
  xor r8d, r8d
  call type_matches
  mov edx, eax
  mov eax, T_BOOL
  EPI

// -------------------------------------------------------- property access
FN checked_index, 3            // rdi = index tag, rsi = index payload, rdx = length -> rax = index
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  cmp rbx, T_INT
  je 1f
  mov rdi, rbx
  mov rsi, r12
  call value_type_name
  mov rsi, rax
  LEAS rdi, "Index must be an int but got "
  LEAS rdx, ""
  call fail_rt_n
1:
  mov rax, r12
  test rax, rax
  jns 2f
  add rax, r13                 // negative: count from the end
2:
  test rax, rax
  js 3f
  cmp rax, r13
  jb 4f
3:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Index "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r12
  call sb_putint
  lea rdi, LA(2)
  LEAS rsi, " is out of bounds (length "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  call sb_putint
  lea rdi, LA(2)
  mov esi, ')'
  call sb_putc
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
4:
  EPI

FN index_get, 0                // rdi = tag, rsi = payload, rdx = index tag, rcx = index payload
  mov rbx, rdi
  mov r12, rsi
  cmp rbx, T_ARR
  jne 1f
  mov rdi, rdx
  mov rsi, rcx
  mov rdx, [r12 + AR_LEN]
  call checked_index
  shl rax, 4
  add rax, [r12 + AR_DATA]
  mov rdx, [rax + 8]
  mov rax, [rax]
  EPI
1:
  cmp rbx, T_STR
  jne 2f
  mov rdi, rdx
  mov rsi, rcx
  mov rdx, [r12]
  call checked_index
  lea rdi, [r12 + 16 + rax]
  mov esi, 1
  call str_new
  mov rdx, rax
  mov eax, T_STR
  EPI
2:
  mov rdi, rbx
  mov rsi, r12
  call value_type_name
  mov rsi, rax
  LEAS rdi, "Cannot index a value of type "
  LEAS rdx, ""
  call fail_rt_n
  EPI

FN index_set, 0                // rdi = tag, rsi = payload, rdx = index tag, rcx = index payload, r8/r9 = value
  mov rbx, rdi
  mov r12, rsi
  mov r13, r8
  mov r14, r9
  cmp rbx, T_ARR
  je 1f
  mov rdi, rbx
  mov rsi, r12
  call value_type_name
  mov rsi, rax
  LEAS rdi, "Cannot assign by index to a value of type "
  LEAS rdx, ""
  call fail_rt_n
1:
  mov rdi, rdx
  mov rsi, rcx
  mov rdx, [r12 + AR_LEN]
  call checked_index
  shl rax, 4
  add rax, [r12 + AR_DATA]
  mov [rax], r13
  mov [rax + 8], r14
  mov rax, r13
  mov rdx, r14
  EPI

FN get_prop, 3                 // rdi = obj tag, rsi = obj payload, rdx = name, rcx = 1 if only used as a callee
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  cmp rbx, T_INST
  je 10f
  cmp rbx, T_CLS
  je 20f
  cmp rbx, T_MOD
  je 40f
  cmp rbx, T_ARR
  je 30f
  cmp rbx, T_STR
  je 30f
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot read property '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "' of "
  call sb_putcs
  mov rdi, rbx
  mov rsi, r12
  call value_type_name
  mov rsi, rax
  lea rdi, LA(2)
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
40:                             // module namespace: exported bindings only
  mov rdi, r12
  mov rsi, r13
  xor edx, edx
  call tbl_find
  test rax, rax
  jnz 41f
  LEAS rdi, "Module has no export named '"
  mov rsi, r13
  LEAS rdx, "'"
  call fail_rt_n
41:
  mov rdx, [rax + E_PAY]
  mov rax, [rax + E_TAG]
  EPI
10:                             // instance: field first, then method
  mov rdi, r12
  mov rsi, r13
  xor edx, edx
  call tbl_find
  test rax, rax
  jz 11f
  mov L(0), rax
  mov rdi, rax
  mov rsi, r13
  call private_check
  mov rax, L(0)
  mov rdx, [rax + E_PAY]
  mov rax, [rax + E_TAG]
  EPI
11:
  mov rdi, [r12 + TB_LINK]
  mov rsi, r13
  call class_find_method
  test rax, rax
  jz 12f
  mov L(0), rax
  mov rdi, rax
  mov rsi, r13
  call private_check_method
  mov rdi, L(0)
  mov rsi, r12
  xor edx, edx
  test r14, r14
  setz dl                      // a method used as `obj.m(...)` callee cannot escape: no closure count
  call fn_bind
  mov rdx, rax
  mov eax, T_FN
  EPI
12:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Undefined property '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "' on instance of '"
  call sb_putcs
  mov rax, [r12 + TB_LINK]
  lea rdi, LA(2)
  mov rsi, [rax + CL_NAME]
  call sb_putstr
  lea rdi, LA(2)
  mov esi, 39
  call sb_putc
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
20:                             // class: static field or static method
  mov rdi, r12
  mov rsi, r13
  call class_find_static
  test rax, rax
  jz 21f
  mov L(0), rax
  mov rdi, rax
  mov rsi, r13
  call private_check
  mov rax, L(0)
  mov rdx, [rax + E_PAY]
  mov rax, [rax + E_TAG]
  EPI
21:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Undefined static member '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "' on class '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, [r12 + CL_NAME]
  call sb_putstr
  lea rdi, LA(2)
  mov esi, 39
  call sb_putc
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
30:
  mov rdi, rbx
  mov rsi, r12
  mov rdx, r13
  call native_member
  EPI

FN set_prop, 3                 // rdi = obj tag, rsi = obj payload, rdx = name, rcx = value tag, r8 = value payload
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov r15, r8
  cmp rbx, T_INST
  je 10f
  cmp rbx, T_CLS
  je 20f
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot set property '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "' on "
  call sb_putcs
  mov rdi, rbx
  mov rsi, r12
  call value_type_name
  mov rsi, rax
  lea rdi, LA(2)
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
10:
  mov rdi, r12
  mov rsi, r13
  xor edx, edx
  call tbl_find
  test rax, rax
  jnz 11f
  mov rdi, r12                 // undeclared field: created on the fly
  mov rsi, r13
  call tbl_add
  mov [rax + E_TAG], r14
  mov [rax + E_PAY], r15
  mov rax, r14
  mov rdx, r15
  EPI
11:
  mov rbx, rax                 // field entry
  mov rdi, rbx
  mov rsi, r13
  call private_check
  test dword ptr [rbx + E_FLAGS], EF_CONST
  jz 12f
  cmp qword ptr [r12 + TB_X], 0
  jne 12f
  LEAS rdi, "Cannot assign to constant field '"
  mov rsi, r13
  LEAS rdx, "'"
  call fail_rt_n
12:
  mov rdi, r14
  mov rsi, r15
  mov rdx, [rbx + E_TYPE]
  mov rcx, [rbx + E_TENV]
  LEAS r8, "field "
  mov r9, r13
  call coerce
  mov [rbx + E_TAG], rax
  mov [rbx + E_PAY], rdx
  EPI
20:                             // static field of a class
  mov rdi, r12
  mov rsi, r13
  call class_find_static
  test rax, rax
  jz 22f
  test dword ptr [rax + E_FLAGS], EF_METHOD
  jnz 22f
  mov rbx, rax
  mov rdi, rbx
  mov rsi, r13
  call private_check
  test dword ptr [rbx + E_FLAGS], EF_CONST
  jz 21f
  LEAS rdi, "Cannot assign to constant static field '"
  mov rsi, r13
  LEAS rdx, "'"
  call fail_rt_n
21:
  mov rdi, r14
  mov rsi, r15
  mov rdx, [rbx + E_TYPE]
  mov rcx, [rbx + E_TENV]
  LEAS r8, "static field "
  mov r9, r13
  call coerce
  mov [rbx + E_TAG], rax
  mov [rbx + E_PAY], rdx
  EPI
22:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Undefined static field '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "' on class '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, [r12 + CL_NAME]
  call sb_putstr
  lea rdi, LA(2)
  mov esi, 39
  call sb_putc
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
  EPI

FN ev_get, 0
  mov rbx, rdi
  mov rdi, [rbx + N_A]
  call eval
  SETLINE rbx
  mov rdi, rax
  mov rsi, rdx
  mov rdx, [rbx + N_B]
  xor ecx, ecx
  call get_prop
  EPI

FN ev_index, 2
  mov rbx, rdi
  mov r12, rsi
  mov rdi, [rbx + N_A]
  call eval
  mov L(0), rax
  mov L(1), rdx
  mov rdi, [rbx + N_B]
  mov rsi, r12
  call eval
  mov rcx, rdx
  mov rdx, rax
  mov rdi, L(0)
  mov rsi, L(1)
  SETLINE rbx
  call index_get
  EPI

FN ev_super, 0
  mov rbx, rdi
  mov r12, rsi
  SETLINE rbx
  mov rdi, r12
  lea rcx, [rip + known_ptrs]
  mov rsi, [rcx + K_super*8]
  xor edx, edx
  call env_find
  test rax, rax
  jz 9f
  mov r13, [rax + E_PAY]        // superclass
  mov rdi, r12
  lea rcx, [rip + known_ptrs]
  mov rsi, [rcx + K_this*8]
  xor edx, edx
  call env_find
  test rax, rax
  jz 9f
  mov r14, [rax + E_PAY]        // this
  mov rdi, r13
  mov rsi, [rbx + N_A]
  call class_find_method
  test rax, rax
  jz 1f
  mov r15, rax
  mov rdi, r15
  mov rsi, [rbx + N_A]
  call private_check_method
  mov rdi, r15
  mov rsi, r14
  mov edx, 1
  call fn_bind
  mov rdx, rax
  mov eax, T_FN
  EPI
1:
  mov rax, [rbx + N_A]          // `super.init()` is harmless when the base has no constructor
  cmp qword ptr [rax + 8], K_init
  jne 2f
  lea rdi, [rip + native_nop]
  mov rsi, rax
  xor edx, edx
  xor ecx, ecx
  call native_new
  mov rdx, rax
  mov eax, T_FN
  EPI
2:
  LEAS rdi, "Undefined method '"
  mov rsi, [rbx + N_A]
  LEAS rdx, "' in the superclass"
  call fail_rt_n
9:
  LEAS rdi, "'super' can only be used inside a method of a subclass"
  call fail_rt
  EPI

.balign 16
native_nop:
  xor eax, eax
  xor edx, edx
  ret

// ------------------------------------------------------------------- calls
FN ev_call, 6                  // L(0):L(1) callee, L(2) loop counter, LA(5) = env mark
  mov rbx, rdi
  mov r12, rsi
  lea rdi, LA(5)
  call env_mark                // scopes created by this call can be reclaimed afterwards
  mov rax, [rbx + N_A]         // callee expression
  cmp dword ptr [rax], EK_GET
  jne 1f
  mov r14, rax                 // obj.method(...): look the method up without counting a closure
  mov rdi, [r14 + N_A]
  mov rsi, r12
  call eval
  mov r11d, dword ptr [r14 + 4]
  mov G(cur_line), r11
  mov rdi, rax
  mov rsi, rdx
  mov rdx, [r14 + N_B]
  mov ecx, 1
  call get_prop
  jmp 2f
1:
  mov rdi, rax
  mov rsi, r12
  call eval
2:
  mov L(0), rax                // callee
  mov L(1), rdx
  mov r13, [rbx + N_B]
  mov r14, [r13]               // argc
  mov rax, r14
  shl rax, 4
  add rax, 15
  and rax, -16
  sub rsp, rax
  mov r15, rsp                 // argument buffer (argc Values)
  xor ecx, ecx
3:
  cmp rcx, r14
  jae 4f
  mov L(2), rcx
  mov rdi, [r13 + 8 + rcx*8]
  mov rsi, r12
  call eval
  mov rcx, L(2)
  mov rsi, rcx
  shl rsi, 4
  mov [r15 + rsi], rax
  mov [r15 + rsi + 8], rdx
  inc rcx
  jmp 3b
4:
  SETLINE rbx
  mov rdi, L(0)
  mov rsi, L(1)
  mov rdx, r15
  mov rcx, r14
  call call_value
  lea rdi, LA(5)
  call env_release
  EPI
// ===================================================== CALLS, STATEMENTS, CLASSES
DATA
.balign 8
exec_table:
  .quad ex_expr, ex_var, ex_block, ex_if, ex_while, ex_for, ex_forin, ex_return
  .quad ex_break, ex_continue, ex_func, ex_class, ex_type, ex_throw, ex_try
  .quad ex_import, ex_from_import

TEXT
FN arity_check, 3              // rdi = name (or 0), rsi = min, rdx = max (-1 = variadic), rcx = argc
  cmp rcx, rsi
  jl 1f
  test rdx, rdx
  js 9f
  cmp rcx, rdx
  jle 9f
1:
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov rbx, rdi
  lea rdi, LA(2)
  call sb_init
  test rbx, rbx
  jnz 2f
  lea rdi, LA(2)
  LEAS rsi, "anonymous function"
  call sb_putcs
  jmp 3f
2:
  lea rdi, LA(2)
  mov esi, 39
  call sb_putc
  lea rdi, LA(2)
  mov rsi, rbx
  call sb_putstr
  lea rdi, LA(2)
  mov esi, 39
  call sb_putc
3:
  lea rdi, LA(2)
  LEAS rsi, " expects "
  call sb_putcs
  test r13, r13
  jns 4f
  lea rdi, LA(2)
  LEAS rsi, "at least "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r12
  call sb_putint
  jmp 7f
4:
  lea rdi, LA(2)
  mov rsi, r12
  call sb_putint
  cmp r12, r13
  je 7f
  lea rdi, LA(2)
  LEAS rsi, " to "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  call sb_putint
7:
  lea rdi, LA(2)
  LEAS rsi, " argument"
  call sb_putcs
  cmp r12, 1
  jne 8f
  cmp r13, 1
  je 6f
8:
  lea rdi, LA(2)
  mov esi, 's'
  call sb_putc
6:
  lea rdi, LA(2)
  LEAS rsi, " but got "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r14
  call sb_putint
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
9:
  EPI

FN call_value, 0               // rdi = callee tag, rsi = callee payload, rdx = args (Value[]), rcx = argc
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  cmp rbx, T_FN
  je 1f
  cmp rbx, T_CLS
  je 2f
  mov rdi, rbx
  mov rsi, r12
  call value_type_name
  mov rsi, rax
  LEAS rdi, "Value of type '"
  LEAS rdx, "' is not callable"
  call fail_rt_n
1:
  mov rdi, [r12 + FO_NAME]
  mov rsi, [r12 + FO_MIN]
  mov rdx, [r12 + FO_MAX]
  mov rcx, r14
  call arity_check
  mov rdi, r12
  mov rsi, r13
  mov rdx, r14
  cmp qword ptr [r12 + FO_KIND], 0
  je 3f
  mov rdi, r13                 // native: (args, argc, function object)
  mov rsi, r14
  mov rdx, r12
  call qword ptr [r12 + FO_CODE]
  EPI
3:
  call call_user
  EPI
2:
  mov rdi, r12
  mov rsi, r13
  mov rdx, r14
  call instantiate
  EPI

// call_value, reclaiming the scopes of the call afterwards (used when natives call back)
FN call_value_rw, 3            // LA(2) = env mark
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  lea rdi, LA(2)
  call env_mark
  mov rdi, rbx
  mov rsi, r12
  mov rdx, r13
  mov rcx, r14
  call call_value
  lea rdi, LA(2)
  call env_release
  EPI

FN call_user, 7                // rdi = function object, rsi = args, rdx = argc
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov rax, G(stack_base)       // guard against runaway recursion (instead of crashing)
  sub rax, rsp
  jns 1f
  neg rax
1:
  cmp rax, G(stack_budget)
  jbe 2f
  LEAS rdi, "Stack overflow: recursion is too deep"
  call fail_rt
2:
  mov rax, G(cur_line)
  mov L(0), rax                // line of the call
  mov rax, G(access_class)
  mov L(6), rax                // restore class access context on return
  mov rax, [rbx + 72]          // declaring class, low bit marks private method
  and rax, -2
  mov G(access_class), rax
  mov r14, [rbx + FO_CODE]     // function declaration
  mov rdi, [rbx + FO_ENV]
  call env_new
  mov r15, rax
  mov L(1), 0                  // parameter index
3:
  mov rcx, L(1)
  mov rax, [r14 + N_B]
  cmp rcx, [rax]
  jae 8f
  mov rdx, [rax + 8 + rcx*8]
  mov L(2), rdx                // parameter record {name, type, default}
  cmp rcx, r13
  jae 4f
  shl rcx, 4
  mov rax, [r12 + rcx]
  mov rdx, [r12 + rcx + 8]
  mov L(3), rax
  mov L(4), rdx
  jmp 5f
4:                              // missing argument: evaluate the default in the callee scope
  mov rax, L(2)
  mov rdi, [rax + 16]
  mov rsi, r15
  call eval
  mov L(3), rax
  mov L(4), rdx
5:
  mov rax, L(2)
  cmp qword ptr [rax + 8], 0
  je 6f
  mov rcx, L(0)
  mov G(cur_line), rcx
  mov rcx, [r14 + N_A]         // error text: "parameter 'x' of 'fname'"
  test rcx, rcx
  jnz .Lpn_ok
  mov rcx, G(str_anon)
.Lpn_ok:
  mov G(coerce_ctx), rcx
  mov rdi, L(3)
  mov rsi, L(4)
  mov rdx, [rax + 8]
  mov rcx, [rbx + FO_ENV]
  LEAS r8, "parameter "
  mov r9, [rax]
  call coerce
  mov G(coerce_ctx), 0
  mov L(3), rax
  mov L(4), rdx
6:
  mov rax, L(2)
  mov rdi, r15
  mov rsi, [rax]
  mov rdx, L(3)
  mov rcx, L(4)
  mov r8, [rax + 8]
  xor r9d, r9d
  call env_define
  inc L(1)
  jmp 3b
8:
  mov rdi, [r14 + N_D]
  mov rsi, r15
  call exec_list
  mov L(5), rax                // flow
  mov rax, L(6)
  mov G(access_class), rax
  xor ecx, ecx
  xor edx, edx
  cmp L(5), F_RET
  jne 9f
  mov rcx, G(ret_tag)
  mov rdx, G(ret_pay)
  mov G(ret_tag), 0
  mov G(ret_pay), 0
9:
  mov L(3), rcx                // result
  mov L(4), rdx
  cmp qword ptr [rbx + FO_INIT], 0
  je 10f
  mov rdi, [rbx + FO_ENV]      // constructor: the result is `this`
  lea rcx, [rip + known_ptrs]
  mov rsi, [rcx + K_this*8]
  xor edx, edx
  call tbl_find
  mov rdx, [rax + E_PAY]
  mov rax, [rax + E_TAG]
  EPI
10:
  mov rdx, [r14 + N_C]         // declared return type?
  test rdx, rdx
  jz 12f
  mov eax, dword ptr [r14 + 4]
  cmp L(5), F_RET
  jne 11f
  mov rax, G(ret_line)
11:
  mov G(cur_line), rax
  mov rdi, L(3)
  mov rsi, L(4)
  mov rcx, [rbx + FO_ENV]
  LEAS r8, "return value of "
  mov r9, [r14 + N_A]
  test r9, r9
  jnz 13f
  mov r9, G(str_anon)
13:
  call coerce
  EPI
12:
  mov rax, L(3)
  mov rdx, L(4)
  EPI

// ---------------------------------------------------------------- statements
.balign 16
exec:                          // rdi = statement, rsi = environment -> rax = flow
  mov eax, [rdi]
  mov ecx, [rdi + 4]
  mov G(cur_line), rcx
  sub eax, SK_EXPR
  lea rcx, [rip + exec_table]
  jmp qword ptr [rcx + rax*8]

FN hoist_functions, 0          // rdi = statement list, rsi = env: declare every `fn` up front
  mov rbx, rdi
  mov r12, rsi
  xor r13d, r13d
1:
  cmp r13, [rbx]
  jae 3f
  mov rax, [rbx + 8 + r13*8]
  cmp dword ptr [rax], SK_FUNC
  jne 2f
  mov r14, rax
  mov ecx, [rax + 4]
  mov G(cur_line), rcx
  mov r15, [rax + N_A]         // function decl
  mov rdi, r15
  mov rsi, r12
  call fn_make
  mov rdx, rax
  mov rdi, r12
  mov rsi, [r15 + N_A]
  mov ecx, T_FN
  xchg rdx, rcx                // rdx = tag, rcx = payload
  xor r8d, r8d
  xor r9d, r9d
  call declare
2:
  inc r13
  jmp 1b
3:
  EPI

FN exec_list, 0                // rdi = statement list, rsi = env -> flow
  mov rbx, rdi
  mov r12, rsi
  call hoist_functions
  xor r13d, r13d
1:
  cmp r13, [rbx]
  jae 2f
  mov rdi, [rbx + 8 + r13*8]
  mov rsi, r12
  call exec
  test rax, rax
  jnz 3f
  inc r13
  jmp 1b
2:
  xor eax, eax
3:
  EPI

// Load and execute a module once. Paths are interpreted relative to the
// process working directory. Cache record: {next, path String*, module env}.
FN module_load, 18             // rdi = path String* -> rax = module environment
  mov rbx, rdi
  mov r12, G(module_cache)
1:
  test r12, r12
  jz 2f
  mov rdi, [r12 + 8]
  mov rsi, rbx
  call str_eq
  test eax, eax
  jnz 9f
  mov r12, [r12]
  jmp 1b
2:
  // Open and read the source file.
  lea rdi, [rbx + 16]
  LEAS rsi, "rb"
  CALLC fopen
  test rax, rax
  jnz 3f
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot open module: "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, rbx
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
3:
  mov L(0), rax                // FILE*
  mov rdi, rax
  xor esi, esi
  mov edx, 2                   // SEEK_END
  CALLC fseek
  test eax, eax
  jne 8f
  mov rdi, L(0)
  CALLC ftell
#if defined(OS_WIN)
  movsxd rax, eax
#endif
  test rax, rax
  js 8f
  mov L(1), rax                // source length
  mov rdi, L(0)
  xor esi, esi
  xor edx, edx                 // SEEK_SET
  CALLC fseek
  test eax, eax
  jne 8f
  mov rdi, L(1)
  inc rdi
  call hx_alloc
  mov L(2), rax                // NUL-terminated source buffer
  mov rdi, L(2)
  mov esi, 1
  mov rdx, L(1)
  mov rcx, L(0)
  CALLC fread
  cmp rax, L(1)
  jne 8f
  mov rdi, L(0)
  CALLC fclose
  // Create a persistent module environment (not from the rewindable call arena).
  mov edi, 48
  call hx_alloc
  mov r13, rax
  mov rax, G(g_builtins)
  mov [r13 + TB_LINK], rax
  mov qword ptr [r13 + TB_X], MOD_MAGIC
  // Publish before execution so mutually recursive imports can see this module.
  mov edi, 24
  call hx_alloc
  mov r14, rax
  mov rax, G(module_cache)
  mov [r14], rax
  mov [r14 + 8], rbx
  mov [r14 + 16], r13
  mov G(module_cache), r14
  // Preserve the source buffer and length above the setjmp area. LA(8)..LA(0)
  // are occupied by hx_try's 72-byte jump buffer.
  mov rax, L(2)
  mov L(9), rax
  mov rax, L(1)
  mov L(10), rax
  // Protect module initialization. On failure, remove this cache entry so a
  // later import can retry instead of observing a half-initialized module.
  lea rdi, LA(8)
  call hx_try
  test eax, eax
  jnz 6f
  // Parse with the normal lexer/parser, then execute in the module's own env.
  mov rdi, L(9)
  mov rsi, L(10)
  call lex
  call parse_program
  mov rdi, rax
  mov rsi, r13
  call exec_list
  call hx_try_end
  mov rax, r13
  EPI
6:
  // Unlink the failed module record; other modules loaded during its run stay cached.
  mov r12, G(module_cache)
  xor r13d, r13d               // previous record
61:
  test r12, r12
  jz 63f
  cmp r12, r14
  je 62f
  mov r13, r12
  mov r12, [r12]
  jmp 61b
62:
  mov rax, [r12]
  test r13, r13
  jnz 64f
  mov G(module_cache), rax
  jmp 63f
64:
  mov [r13], rax
63:
  jmp hx_throw
8:
  mov rdi, L(0)
  test rdi, rdi
  jz 81f
  CALLC fclose
81:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot read module: "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, rbx
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
9:
  mov rax, [r12 + 16]
  EPI

FN ex_import, 2                // import "path" as alias
  mov rbx, rdi
  mov r12, rsi
  mov rdi, [rbx + N_A]
  call module_load
  mov r13, rax
  mov eax, [rbx + 4]
  mov G(cur_line), rax
  mov rdi, r12
  mov rsi, [rbx + N_B]
  mov edx, T_MOD
  mov rcx, r13
  xor r8d, r8d
  mov r9d, EF_CONST
  call declare
  xor eax, eax
  EPI

FN ex_from_import, 5           // from "path" import Name, other
  mov rbx, rdi
  mov r12, rsi
  mov rdi, [rbx + N_A]
  call module_load
  mov r13, rax                 // module environment
  mov eax, [rbx + 4]
  mov G(cur_line), rax
  mov L(0), 0                  // imported-name index
1:
  mov r14, [rbx + N_B]
  mov rcx, L(0)
  cmp rcx, [r14]
  jae 4f
  mov r15, [r14 + 8 + rcx*8]   // exported name
  mov rdi, r13
  mov rsi, r15
  xor edx, edx
  call tbl_find                // direct lookup: builtins are not module exports
  test rax, rax
  jnz 2f
  LEAS rdi, "Module does not export '"
  mov rsi, r15
  LEAS rdx, "'"
  call fail_rt_n
2:
  mov L(1), rax                // source entry
  mov rdi, r12
  mov rsi, r15
  mov rax, L(1)
  mov rdx, [rax + E_TAG]
  mov rcx, [rax + E_PAY]
  mov r8, [rax + E_TYPE]
  mov r9, [rax + E_FLAGS]
  call declare                // preserve the original value and metadata
  inc L(0)
  jmp 1b
4:
  xor eax, eax
  EPI

FN run_body, 0                 // rdi = loop body, rsi = scope env -> flow
  cmp dword ptr [rdi], SK_BLOCK
  jne 1f
  mov rdi, [rdi + N_A]
  call exec_list
  EPI
1:
  call exec
  EPI

FN env_clone, 0                // rdi = env -> copy (same parent, copied bindings)
  mov rbx, rdi
  mov rdi, [rbx + TB_LINK]
  call env_new
  mov r12, rax
  mov rcx, [rbx + TB_COUNT]
  test rcx, rcx
  jz 1f
  mov r13, rcx
  imul rdi, rcx, E_SIZE
  call hx_alloc
  mov [r12 + TB_ENT], rax
  mov [r12 + TB_COUNT], r13
  mov [r12 + TB_CAP], r13
  mov rdi, rax
  mov rsi, [rbx + TB_ENT]
  lea rdx, [r13 + r13*2]
  shl rdx, 4
  CALLC memcpy
1:
  mov rax, r12
  EPI

FN ex_expr, 0
  mov rdi, [rdi + N_A]
  call eval
  xor eax, eax
  EPI

FN ex_var, 6                   // L(0) = tag, L(1) = payload
  mov rbx, rdi
  mov r12, rsi
  mov L(0), 0
  mov L(1), 0
  cmp qword ptr [rbx + N_C], 0
  je 1f
  mov rdi, [rbx + N_C]
  mov rsi, r12
  call eval
  mov L(0), rax
  mov L(1), rdx
1:
  mov eax, [rbx + 4]
  mov G(cur_line), rax
  mov r13, [rbx + N_B]         // declared type
  cmp qword ptr [rbx + N_C], 0
  jne 4f
  test r13, r13
  jz 6f
  mov rdi, r13                 // `let int x`: default value of the type
  mov rsi, r12
  lea rdx, LA(1)               // out Value: tag lands in L(1), payload in L(0)
  xor ecx, ecx
  call zero_value
  test eax, eax
  jz 3f
  mov rax, L(0)                // swap into (L(0)=tag, L(1)=payload)
  mov rcx, L(1)
  mov L(0), rcx
  mov L(1), rax
  jmp 6f
3:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Variable '"
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, [rbx + N_A]
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "' of type "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  call type_str
  lea rdi, LA(2)
  LEAS rsi, " needs an initializer"
  call sb_putcs
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
4:
  test r13, r13
  jz 5f
  mov rdi, L(0)
  mov rsi, L(1)
  mov rdx, r13
  mov rcx, r12
  LEAS r8, "variable "
  mov r9, [rbx + N_A]
  call coerce
  mov L(0), rax
  mov L(1), rdx
5:                              // a lambda takes the name of its variable (nicer messages)
  mov rax, [rbx + N_C]
  cmp dword ptr [rax], EK_LAMBDA
  jne 6f
  cmp L(0), T_FN
  jne 6f
  mov rax, L(1)
  cmp qword ptr [rax + FO_NAME], 0
  jne 6f
  mov rcx, [rbx + N_A]
  mov [rax + FO_NAME], rcx
6:
  mov r9d, 0
  cmp qword ptr [rbx + N_D], 0
  je 7f
  mov r9d, EF_CONST
7:
  mov rdi, r12
  mov rsi, [rbx + N_A]
  mov rdx, L(0)
  mov rcx, L(1)
  mov r8, r13
  call declare
  xor eax, eax
  EPI

FN ex_block, 0
  cmp qword ptr [rdi + N_B], 0
  mov rbx, [rdi + N_A]
  jne 1f
  mov rdi, rbx
  call exec_list               // no declarations inside: no new scope needed
  EPI
1:
  mov rdi, rsi
  call env_new
  mov rsi, rax
  mov rdi, rbx
  call exec_list
  EPI

FN ex_if, 0
  mov rbx, rdi
  mov r12, rsi
  mov rdi, [rbx + N_A]
  call eval
  mov rdi, rax
  mov rsi, rdx
  call truthy
  mov rdi, [rbx + N_B]
  test eax, eax
  jnz 1f
  mov rdi, [rbx + N_C]
  test rdi, rdi
  jz 2f
1:
  mov rsi, r12
  call exec
  EPI
2:
  xor eax, eax
  EPI

FN ex_while, 3                 // A=cond B=body C=creates closures
  mov rbx, rdi
  mov r12, rsi
  xor r13d, r13d               // reusable body scope
  mov rax, [rbx + N_B]
  cmp dword ptr [rax], SK_BLOCK
  jne 1f
  cmp qword ptr [rax + N_B], 0
  je 1f
  cmp qword ptr [rbx + N_C], 0
  jne 1f
  mov rdi, r12
  call env_new
  mov r13, rax
1:
  mov rdi, [rbx + N_A]
  mov rsi, r12
  call eval
  mov rdi, rax
  mov rsi, rdx
  call truthy
  test eax, eax
  jz 9f
  mov rdi, [rbx + N_B]
  mov rsi, r12
  test r13, r13
  jz 2f
  mov qword ptr [r13 + TB_COUNT], 0   // fresh scope per iteration, same memory
  mov rsi, r13
  call run_body
  jmp 3f
2:
  call exec
3:
  cmp rax, F_BREAK
  je 9f
  cmp rax, F_RET
  je 8f
  jmp 1b
9:
  xor eax, eax
8:
  EPI

FN ex_for, 5                   // A=init B=cond C=incr D=body E=creates closures
  mov rbx, rdi
  mov rdi, rsi
  call env_new
  mov r12, rax                 // loop scope
  xor r13d, r13d               // init declares variables?
  mov rdi, [rbx + N_A]
  test rdi, rdi
  jz 1f
  cmp dword ptr [rdi], SK_VAR
  sete r13b
  mov rsi, r12
  call exec
1:
  xor r14d, r14d               // reusable body scope
  mov rax, [rbx + N_D]
  cmp dword ptr [rax], SK_BLOCK
  jne 2f
  cmp qword ptr [rax + N_B], 0
  je 2f
  cmp qword ptr [rbx + N_E], 0
  jne 2f
  mov rdi, r12
  call env_new
  mov r14, rax
2:
  cmp qword ptr [rbx + N_B], 0
  je 3f
  mov rdi, [rbx + N_B]
  mov rsi, r12
  call eval
  mov rdi, rax
  mov rsi, rdx
  call truthy
  test eax, eax
  jz 9f
3:
  mov rdi, [rbx + N_D]
  mov rsi, r12
  test r14, r14
  jz 4f
  mov qword ptr [r14 + TB_COUNT], 0
  mov rsi, r14
  call run_body
  jmp 5f
4:
  cmp dword ptr [rdi], SK_BLOCK
  jne 41f
  cmp qword ptr [rdi + N_B], 0
  je 41f
  mov r15, rdi                 // body declares variables and may capture: new scope each time
  mov rdi, r12
  call env_new
  mov rsi, rax
  mov rdi, r15
  call run_body
  jmp 5f
41:
  call exec
5:
  cmp rax, F_BREAK
  je 9f
  cmp rax, F_RET
  je 8f
  test r13, r13                // closures capture a per-iteration copy of the loop variables
  jz 6f
  cmp qword ptr [rbx + N_E], 0
  je 6f
  mov rdi, r12
  call env_clone
  mov r12, rax
6:
  cmp qword ptr [rbx + N_C], 0
  je 2b
  mov rdi, [rbx + N_C]
  mov rsi, r12
  call eval
  jmp 2b
9:
  xor eax, eax
8:
  EPI

FN ex_forin, 8                 // A=name B=type C=isConst D=iterable E=body F=creates closures
  mov rbx, rdi
  mov r12, rsi
  mov rdi, [rbx + N_D]
  call eval
  mov L(0), rax                // iterable
  mov L(1), rdx
  mov eax, [rbx + 4]
  mov G(cur_line), rax
  cmp L(0), T_ARR
  je 1f
  cmp L(0), T_STR
  je 1f
  mov rdi, L(0)
  mov rsi, L(1)
  call value_type_name
  mov rsi, rax
  LEAS rdi, "Value of type '"
  LEAS rdx, "' is not iterable"
  call fail_rt_n
1:
  xor r13d, r13d               // reusable scope
  cmp qword ptr [rbx + N_F], 0
  jne 2f
  mov rdi, r12
  call env_new
  mov r13, rax
2:
  xor r14d, r14d               // index
3:
  mov rax, L(1)
  cmp L(0), T_ARR
  jne 4f
  cmp r14, [rax + AR_LEN]
  jae 9f
  mov rcx, r14
  shl rcx, 4
  add rcx, [rax + AR_DATA]
  mov rdi, [rcx]
  mov rsi, [rcx + 8]
  jmp 5f
4:
  cmp r14, [rax]
  jae 9f
  lea rdi, [rax + 16 + r14]
  mov esi, 1
  call str_new
  mov rsi, rax
  mov edi, T_STR
5:
  mov L(2), rdi                // current item
  mov L(3), rsi
  mov r15, r13
  test r15, r15
  jnz 6f
  mov rdi, r12
  call env_new
  mov r15, rax
  jmp 7f
6:
  mov qword ptr [r15 + TB_COUNT], 0
7:
  mov rdi, L(2)
  mov rsi, L(3)
  mov rdx, [rbx + N_B]
  mov rcx, r12
  LEAS r8, "loop variable "
  mov r9, [rbx + N_A]
  call coerce
  mov rcx, rdx                 // payload
  mov rdx, rax                 // tag
  mov r8, [rbx + N_B]
  xor r9d, r9d
  cmp qword ptr [rbx + N_C], 0
  je 8f
  mov r9d, EF_CONST
8:
  mov rdi, r15
  mov rsi, [rbx + N_A]
  call env_define
  mov rdi, [rbx + N_E]
  mov rsi, r15
  call run_body
  cmp rax, F_BREAK
  je 9f
  cmp rax, F_RET
  je 11f
  inc r14
  jmp 3b
9:
  xor eax, eax
11:
  EPI

FN ex_return, 0
  mov rbx, rdi
  xor eax, eax
  xor edx, edx
  cmp qword ptr [rbx + N_A], 0
  je 1f
  mov rdi, [rbx + N_A]
  call eval
1:
  mov G(ret_tag), rax
  mov G(ret_pay), rdx
  mov ecx, [rbx + 4]
  mov G(ret_line), rcx
  mov eax, F_RET
  EPI

.balign 16
ex_break:
  mov eax, F_BREAK
  ret

.balign 16
ex_continue:
  mov eax, F_CONT
  ret

.balign 16
ex_func:
  xor eax, eax
  ret

FN ex_type, 0                  // type alias
  mov rbx, rdi
  mov r12, rsi
  mov rdi, r12
  mov rsi, [rbx + N_A]
  mov edx, 1
  call tbl_find
  test rax, rax
  jz 2f
  cmp G(g_repl), 0
  je 1f
  cmp r12, G(g_globals)
  je 2f
1:
  LEAS rdi, "Type '"
  mov rsi, [rbx + N_A]
  LEAS rdx, "' is already declared in this scope"
  call fail_rt_n
2:
  mov rdi, r12
  mov rsi, [rbx + N_A]
  xor edx, edx
  mov rcx, [rbx + N_B]
  xor r8d, r8d
  mov r9d, EF_ALIAS
  call env_define
  xor eax, eax
  EPI

FN ex_throw, 0
  mov rbx, rdi
  mov rdi, [rbx + N_A]
  call eval
  mov rdi, rax
  mov rsi, rdx
  mov edx, [rbx + 4]
  call raise_val
  EPI

// try { } catch (e) { } finally { }
FN try_catch, 10               // jmpbuf at LA(8)
  mov rbx, rdi
  mov r12, rsi
  mov rax, G(access_class)
  mov L(7), rax
  cmp qword ptr [rbx + N_C], 0
  jne 1f
  mov rdi, [rbx + N_A]         // no catch clause: errors just propagate
  mov rsi, r12
  call exec
  EPI
1:
  lea rdi, LA(8)
  call hx_try
  test eax, eax
  jnz 2f
  mov rdi, [rbx + N_A]
  mov rsi, r12
  call exec
  mov r13, rax
  call hx_try_end
  mov rax, r13
  EPI
2:                              // caught: restore access context, bind error and run catch
  mov rax, L(7)
  mov G(access_class), rax
  mov rdi, r12
  call env_new
  mov r13, rax
  cmp qword ptr [rbx + N_B], 0
  je 3f
  mov rdi, r13
  mov rsi, [rbx + N_B]
  mov rdx, G(exc_tag)
  mov rcx, G(exc_pay)
  xor r8d, r8d
  xor r9d, r9d
  call env_define
3:
  mov rax, [rbx + N_C]
  mov rdi, [rax + N_A]
  mov rsi, r13
  call exec_list
  EPI

FN ex_try, 16                  // jmpbuf LA(8); saved exception L(9..13); saved return value L(14), L(15)
  mov rbx, rdi
  mov r12, rsi
  mov rax, G(access_class)
  mov L(7), rax
  cmp qword ptr [rbx + N_D], 0
  jne 1f
  call try_catch
  EPI
1:
  lea rdi, LA(8)
  call hx_try
  test eax, eax
  jnz 5f
  mov rdi, rbx
  mov rsi, r12
  call try_catch
  mov r13, rax
  call hx_try_end
  mov rax, G(ret_tag)          // run `finally`, keeping a pending `return` value
  mov L(14), rax
  mov rax, G(ret_pay)
  mov L(15), rax
  mov rdi, [rbx + N_D]
  mov rsi, r12
  call exec
  test rax, rax
  jnz 9f                       // `finally` itself returned/broke: it wins
  mov rcx, L(14)
  mov G(ret_tag), rcx
  mov rcx, L(15)
  mov G(ret_pay), rcx
  mov rax, r13
  EPI
5:                              // an error is propagating: restore access, run finally, re-raise
  mov rax, L(7)
  mov G(access_class), rax
  mov rax, G(exc_kind)
  mov L(9), rax
  mov rax, G(exc_name)
  mov L(10), rax
  mov rax, G(exc_tag)
  mov L(11), rax
  mov rax, G(exc_pay)
  mov L(12), rax
  mov rax, G(exc_line)
  mov L(13), rax
  mov rdi, [rbx + N_D]
  mov rsi, r12
  call exec
  test rax, rax
  jnz 9f
  mov rax, L(9)
  mov G(exc_kind), rax
  mov rax, L(10)
  mov G(exc_name), rax
  mov rax, L(11)
  mov G(exc_tag), rax
  mov rax, L(12)
  mov G(exc_pay), rax
  mov rax, L(13)
  mov G(exc_line), rax
  jmp hx_throw
9:
  EPI

// ------------------------------------------------------------------ classes
FN ex_class, 8
  inc G(closure_cnt)
  mov rax, G(access_class)
  mov L(7), rax
  mov rbx, rdi
  mov r12, rsi
  mov r13, rbx                 // the statement node itself holds name / super / fields / methods
  xor r14d, r14d               // superclass
  mov rsi, [r13 + N_B]
  test rsi, rsi
  jz 3f
  mov rdi, r12
  xor edx, edx
  call env_find
  test rax, rax
  jnz 1f
  LEAS rdi, "Undefined superclass '"
  mov rsi, [r13 + N_B]
  LEAS rdx, "'"
  call fail_rt_n
1:
  cmp qword ptr [rax + E_TAG], T_CLS
  je 2f
  LEAS rdi, "'"
  mov rsi, [r13 + N_B]
  LEAS rdx, "' is not a class and cannot be extended"
  call fail_rt_n
2:
  mov r14, [rax + E_PAY]
3:
  mov edi, CL_SIZE
  call hx_alloc
  mov r15, rax                 // the class object
  mov [r15 + CL_SUPER], r14
  mov [r15 + CL_DECL], r13
  mov [r15 + CL_DEFENV], r12
  mov rax, [r13 + N_A]
  mov [r15 + CL_NAME], rax
  mov rax, [r13 + N_C]
  mov [r15 + CL_STRUCT], rax
  mov G(access_class), r15
  mov L(0), r12                // environment the methods close over
  test r14, r14
  jz 4f
  mov rdi, r12
  call env_new
  mov L(0), rax
  mov rdi, rax
  lea rcx, [rip + known_ptrs]
  mov rsi, [rcx + K_super*8]
  mov edx, T_CLS
  mov rcx, r14
  xor r8d, r8d
  mov r9d, EF_CONST
  call env_define
4:
  mov L(1), 0                  // methods
5:
  mov rcx, L(1)
  mov rax, [r13 + N_E]
  cmp rcx, [rax]
  jae 8f
  mov rax, [rax + 8 + rcx*8]
  mov L(2), rax                // method record {fdecl, isStatic, isPrivate}
  mov rdi, [rax]
  mov rsi, L(0)
  call fn_make
  mov L(3), rax
  mov rdx, r15
  mov rcx, L(2)
  cmp qword ptr [rcx + 16], 0
  je .Lexclass_method_owner
  or rdx, 1
.Lexclass_method_owner:
  mov [rax + 72], rdx
  mov rcx, L(2)
  mov rdx, [rcx]
  mov rsi, [rdx + N_A]         // method name
  mov r8d, EF_METHOD
  cmp qword ptr [rcx + 8], 0
  jne .Lexclass_static_method
  cmp rsi, [rip + known_ptrs + K_init*8]
  jne .Lexclass_method_priv
  mov rax, L(3)
  mov qword ptr [rax + FO_INIT], 1
  jmp .Lexclass_method_priv
.Lexclass_static_method:
  or r8d, EF_STATIC
.Lexclass_method_priv:
  cmp qword ptr [rcx + 16], 0
  je 7f
  or r8d, EF_PRIVATE
7:
  mov rdi, r15
  mov rdx, T_FN
  mov rcx, L(3)
  mov r9, r8
  xor r8d, r8d
  call env_define
  mov [rax + E_TENV], r12
  mov [rax + E_OWNER], r15
  inc L(1)
  jmp 5b
8:
  mov edi, 0                   // declare the class before its static initializers run
  mov rdi, r12
  mov rsi, [r13 + N_A]
  mov edx, T_CLS
  mov rcx, r15
  xor r8d, r8d
  mov r9d, EF_CONST
  call declare
  mov L(1), 0                  // static fields
9:
  mov rcx, L(1)
  mov rax, [r13 + N_D]
  cmp rcx, [rax]
  jae 20f
  mov rax, [rax + 8 + rcx*8]
  mov L(2), rax                // field record {name, type, init, flags, line}
  inc L(1)
  test qword ptr [rax + 24], 2
  jz 9b
  mov L(3), 0
  mov L(4), 0
  mov rcx, [rax + 32]
  mov G(cur_line), rcx
  cmp qword ptr [rax + 16], 0
  je 11f
  mov rdi, [rax + 16]
  mov rsi, r12
  call eval
  mov L(3), rax
  mov L(4), rdx
  mov rax, L(2)
  cmp qword ptr [rax + 8], 0
  je 13f
  mov rdi, L(3)
  mov rsi, L(4)
  mov rdx, [rax + 8]
  mov rcx, r12
  LEAS r8, "static field "
  mov r9, [rax]
  call coerce
  mov L(3), rax
  mov L(4), rdx
  jmp 13f
11:
  cmp qword ptr [rax + 8], 0
  je 13f
  mov rdi, [rax + 8]
  mov rsi, r12
  lea rdx, LA(4)               // tag lands in L(4), payload in L(3)
  xor ecx, ecx
  call zero_value
  test eax, eax
  jz 13f
  mov rax, L(3)
  mov rcx, L(4)
  mov L(3), rcx
  mov L(4), rax
13:
  mov rax, L(2)
  mov r9, EF_STATIC
  test qword ptr [rax + 24], 1
  jz 14f
  or r9, EF_CONST
14:
  test qword ptr [rax + 24], 4
  jz .Lexclass_static_public
  or r9, EF_PRIVATE
.Lexclass_static_public:
  mov rdi, r15
  mov rsi, [rax]
  mov rdx, L(3)
  mov rcx, L(4)
  mov r8, [rax + 8]
  call env_define
  mov rdi, r15
  mov rax, L(2)
  mov rsi, [rax]
  xor edx, edx
  call tbl_find
  mov [rax + E_TENV], r12
  mov [rax + E_OWNER], r15
  jmp 9b
20:
  mov rax, L(7)
  mov G(access_class), rax
  xor eax, eax
  EPI

// Field initialisation, base class first
FN init_fields, 8              // rdi = class, rsi = instance
  mov rbx, rdi
  mov r12, rsi
  mov rax, G(access_class)
  mov L(7), rax
  mov G(access_class), rbx
  mov rdi, [rbx + CL_SUPER]
  test rdi, rdi
  jz 1f
  mov rsi, r12
  call init_fields
1:
  mov r13, [rbx + CL_DECL]
  mov r14, [rbx + CL_DEFENV]
  mov rdi, r14
  call env_new
  mov r15, rax                 // scope where initialisers run: `this` is visible
  mov rdi, rax
  lea rcx, [rip + known_ptrs]
  mov rsi, [rcx + K_this*8]
  mov edx, T_INST
  mov rcx, r12
  xor r8d, r8d
  mov r9d, EF_CONST
  call env_define
  mov L(0), 0
2:
  mov rcx, L(0)
  mov rax, [r13 + N_D]
  cmp rcx, [rax]
  jae 9f
  mov rax, [rax + 8 + rcx*8]
  mov L(1), rax                // field record
  inc L(0)
  test qword ptr [rax + 24], 2
  jnz 2b                       // static fields live in the class
  mov L(2), 0                  // value
  mov L(3), 0
  mov L(4), 0                  // 1 = no value available (e.g. `Point origin`)
  mov rcx, [rax + 32]
  mov G(cur_line), rcx
  cmp qword ptr [rax + 16], 0
  je 3f
  mov rdi, [rax + 16]
  mov rsi, r15
  call eval
  mov L(2), rax
  mov L(3), rdx
  jmp 5f
3:
  mov rax, L(1)
  cmp qword ptr [rax + 8], 0
  je 5f
  mov rdi, [rax + 8]
  mov rsi, r14
  lea rdx, LA(3)               // tag lands in L(3), payload in L(2)
  xor ecx, ecx
  call zero_value
  test eax, eax
  jnz 4f
  mov L(4), 1
  jmp 5f
4:
  mov rax, L(2)
  mov rcx, L(3)
  mov L(2), rcx
  mov L(3), rax
5:
  mov rax, L(1)
  cmp qword ptr [rax + 8], 0
  je 6f
  cmp L(4), 0
  jne 6f
  mov rdi, L(2)
  mov rsi, L(3)
  mov rdx, [rax + 8]
  mov rcx, r14
  LEAS r8, "field "
  mov r9, [rax]
  call coerce
  mov L(2), rax
  mov L(3), rdx
6:
  mov rax, L(1)
  mov rdi, r12
  mov rsi, [rax]
  xor edx, edx
  call tbl_find
  test rax, rax
  jnz 7f
  mov rax, L(1)
  mov rdi, r12
  mov rsi, [rax]
  call tbl_add
7:
  mov rcx, L(2)
  mov [rax + E_TAG], rcx
  mov rcx, L(3)
  mov [rax + E_PAY], rcx
  mov rdx, L(1)
  mov rcx, [rdx + 8]
  mov [rax + E_TYPE], rcx
  xor ecx, ecx
  test qword ptr [rdx + 24], 1
  jz .Lfield_not_const
  mov ecx, EF_CONST
.Lfield_not_const:
  test qword ptr [rdx + 24], 4
  jz .Lfield_not_private
  or ecx, EF_PRIVATE
.Lfield_not_private:
  mov [rax + E_FLAGS], rcx
  mov [rax + E_TENV], r14
  mov [rax + E_OWNER], rbx
  jmp 2b
9:
  mov rax, L(7)
  mov G(access_class), rax
  EPI

FN instantiate, 8              // rdi = class, rsi = args, rdx = argc -> instance value
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov rax, G(cur_line)
  mov L(0), rax
  mov edi, IN_SIZE
  call hx_alloc
  mov r14, rax
  mov [r14 + TB_LINK], rbx
  mov qword ptr [r14 + TB_X], 1   // initializing: const fields may be assigned
  xor ecx, ecx                 // reserve exactly as many field slots as the class chain declares
  mov rax, rbx
4:
  test rax, rax
  jz 5f
  mov rdx, [rax + CL_DECL]
  mov rdx, [rdx + N_D]
  xor esi, esi
6:
  cmp rsi, [rdx]
  jae 7f
  mov rdi, [rdx + 8 + rsi*8]
  inc rsi
  test qword ptr [rdi + 24], 2
  jnz 6b
  inc rcx
  jmp 6b
7:
  mov rax, [rax + CL_SUPER]
  jmp 4b
5:
  test rcx, rcx
  jz 8f
  mov [r14 + TB_CAP], rcx
  imul rdi, rcx, E_SIZE
  call hx_alloc
  mov [r14 + TB_ENT], rax
8:
  mov rdi, rbx
  mov rsi, r14
  call init_fields
  mov rax, L(0)
  mov G(cur_line), rax
  mov rdi, rbx
  lea rcx, [rip + known_ptrs]
  mov rsi, [rcx + K_init*8]
  call class_find_method
  test rax, rax
  jz 2f
  mov rdi, rax
  mov rsi, r14
  xor edx, edx
  call fn_bind
  mov r15, rax
  mov rdi, [rbx + CL_NAME]
  mov rsi, [r15 + FO_MIN]
  mov rdx, [r15 + FO_MAX]
  mov rcx, r13
  call arity_check
  mov rdi, r15
  mov rsi, r12
  mov rdx, r13
  call call_user
  jmp 9f
2:
  cmp qword ptr [rbx + CL_STRUCT], 0
  je 5f
  mov r15, [rbx + CL_DECL]     // struct: positional constructor over its fields
  mov rax, [r15 + N_D]
  xor ecx, ecx                 // required (no initializer)
  xor edx, edx                 // total non-static
  xor esi, esi
3:
  cmp rsi, [rax]
  jae 4f
  mov rdi, [rax + 8 + rsi*8]
  inc rsi
  test qword ptr [rdi + 24], 2
  jnz 3b
  inc rdx
  cmp qword ptr [rdi + 16], 0
  jne 3b
  inc rcx
  jmp 3b
4:
  mov L(1), rdx
  mov rdi, [rbx + CL_NAME]
  mov rsi, rcx
  mov rcx, r13
  call arity_check
  mov L(2), 0                  // field position
  mov L(3), 0                  // argument position
6:
  mov rcx, L(3)
  cmp rcx, r13
  jae 9f
  mov rax, [r15 + N_D]
7:
  mov rdx, L(2)
  mov rdi, [rax + 8 + rdx*8]
  inc L(2)
  test qword ptr [rdi + 24], 2
  jnz 7b
  mov rdx, [rdi]               // field name
  mov rcx, L(3)
  shl rcx, 4
  mov rcx, [r12 + rcx]
  mov r8, L(3)
  shl r8, 4
  mov r8, [r12 + r8 + 8]
  mov rax, L(0)
  mov G(cur_line), rax
  mov rdi, T_INST
  mov rsi, r14
  call set_prop
  inc L(3)
  jmp 6b
5:
  test r13, r13
  jz 9f
  lea rdi, LA(4)
  call sb_init
  lea rdi, LA(4)
  LEAS rsi, "Class '"
  call sb_putcs
  lea rdi, LA(4)
  mov rsi, [rbx + CL_NAME]
  call sb_putstr
  lea rdi, LA(4)
  LEAS rsi, "' has no 'init' and takes no arguments, but got "
  call sb_putcs
  lea rdi, LA(4)
  mov rsi, r13
  call sb_putint
  lea rdi, LA(4)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
9:
  mov qword ptr [r14 + TB_X], 0
  mov eax, T_INST
  mov rdx, r14
  EPI

// -------------------------------------------------------------- entry point
FN interpret, 6                // rdi = statement list, rsi = repl mode
  mov rbx, rdi
  mov G(g_repl), rsi
  lea rax, [rbp - 40]
  mov G(stack_base), rax
  mov G(ret_tag), 0
  mov G(ret_pay), 0
  mov rdi, rbx
  mov rsi, G(g_globals)
  call hoist_functions
  xor r12d, r12d
1:
  cmp r12, [rbx]
  jae 9f
  mov r13, [rbx + 8 + r12*8]
  cmp G(g_repl), 0
  je 3f
  cmp dword ptr [r13], SK_EXPR
  jne 3f
  mov ecx, [r13 + 4]           // REPL: echo the value of expression statements
  mov G(cur_line), rcx
  mov rdi, [r13 + N_A]
  mov rsi, G(g_globals)
  call eval
  test rax, rax
  jz 4f
  mov L(3), rax
  mov L(4), rdx
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, L(3)
  mov rdx, L(4)
  xor ecx, ecx
  call repr
  lea rdi, LA(2)
  mov esi, 10
  call sb_putc
  lea rdi, LA(2)
  call sb_finish
  mov rdi, rax
  call out_putstr
  jmp 4f
3:
  mov rdi, r13
  mov rsi, G(g_globals)
  call exec
4:
  inc r12
  jmp 1b
9:
  EPI
// ================================================================== BUILT-INS
// Native function: rdi = args (Value[]), rsi = argc, rdx = function object -> rax:rdx
// r13 = args, r14 = argc, r15 = function object (receiver in FO_BPAY for methods)
.macro NATIVE name, nloc=0
FN \name, \nloc
  mov r13, rdi
  mov r14, rsi
  mov r15, rdx
.endm

.macro RET_INT reg
  mov rdx, \reg
  mov eax, T_INT
  EPI
.endm
.macro RET_NIL
  xor eax, eax
  xor edx, edx
  EPI
.endm
.macro RET_BOOL reg
  movzx edx, \reg
  mov eax, T_BOOL
  EPI
.endm

DATA
.balign 8
#if defined(OS_WIN)
rand_scale: .quad 0x40E0000000000000  // RAND_MAX + 1 for the Microsoft C runtime (32768.0)
.equ RAND_LIMIT, 32768
#else
rand_scale: .quad 0x41E0000000000000  // RAND_MAX + 1 for the POSIX C runtimes (2147483648.0)
.equ RAND_LIMIT, 2147483648
#endif
GV in_buf
GV in_pos
GV in_len

TABLE
.balign 8
lim_hi: .quad 0x43E0000000000000   // +2^63
lim_lo: .quad 0xC3E0000000000000   // -2^63
#if defined(OS_WIN)
cps: .quad 0x408F400000000000      // 1000.0  (CLOCKS_PER_SEC on Windows)
#else
cps: .quad 0x412E848000000000      // 1000000.0
#endif

TEXT
FN native_new, 0               // rdi = code, rsi = name, rdx = min, rcx = max -> function object
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov edi, FO_SIZE
  call hx_alloc
  mov qword ptr [rax + FO_KIND], 1
  mov [rax + FO_NAME], r12
  mov [rax + FO_MIN], r13
  mov [rax + FO_MAX], r14
  mov [rax + FO_CODE], rbx
  EPI

// "fname() expects <what> but got <type>"
FN fail_expect, 3              // rdi = fname, rsi = what, rdx = tag, rcx = payload
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov r15, rdi
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, r15
  call sb_putcs
  lea rdi, LA(2)
  LEAS rsi, "() expects "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r12
  call sb_putcs
  lea rdi, LA(2)
  LEAS rsi, " but got "
  call sb_putcs
  mov rdi, r13
  mov rsi, r14
  call value_type_name
  mov rsi, rax
  lea rdi, LA(2)
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
  EPI

FN need_fn, 0                  // rdi = tag, rsi = payload, rdx = fname
  cmp rdi, T_FN
  je 1f
  mov rcx, rsi
  mov rsi, rdx
  mov rdx, rdi
  mov rdi, rsi
  LEAS rsi, "a function"
  call fail_expect
1:
  EPI

FN need_int, 0                 // rdi = tag, rsi = payload, rdx = fname -> rax
  cmp rdi, T_INT
  je 1f
  mov rcx, rsi
  mov rsi, rdx
  mov rdx, rdi
  mov rdi, rsi
  LEAS rsi, "an int"
  call fail_expect
1:
  mov rax, rsi
  EPI

FN need_str, 0                 // rdi = tag, rsi = payload, rdx = fname -> String*
  cmp rdi, T_STR
  je 1f
  mov rcx, rsi
  mov rsi, rdx
  mov rdx, rdi
  mov rdi, rsi
  LEAS rsi, "a string"
  call fail_expect
1:
  mov rax, rsi
  EPI

FN need_num, 0                 // rdi = tag, rsi = payload, rdx = fname -> xmm0
  lea rax, [rdi - T_INT]
  cmp rax, 1
  jbe 1f
  mov rcx, rsi
  mov rsi, rdx
  mov rdx, rdi
  mov rdi, rsi
  LEAS rsi, "a number"
  call fail_expect
1:
  call to_double
  EPI

// f(item) or f(item, index) when f is a user function with 2+ parameters
FN call_cb, 4                  // rdi = f tag, rsi = f payload, rdx = item tag, rcx = item payload, r8 = index
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  mov L(3), r13                // args buffer: [item][index] at LA(3)
  mov L(2), r14
  mov L(1), T_INT
  mov L(0), r8
  mov r15d, 1
  cmp qword ptr [r12 + FO_KIND], 0
  jne 1f
  cmp qword ptr [r12 + FO_MAX], 2
  jl 1f
  mov r15d, 2
1:
  mov rdi, rbx
  mov rsi, r12
  lea rdx, LA(3)
  mov rcx, r15
  call call_value_rw
  EPI

// ------------------------------------------------------------ global functions
NATIVE nat_print, 4
  lea rdi, LA(2)
  call sb_init
  xor ebx, ebx
1:
  cmp rbx, r14
  jae 3f
  test rbx, rbx
  jz 2f
  lea rdi, LA(2)
  mov esi, ' '
  call sb_putc
2:
  mov rax, rbx
  shl rax, 4
  lea rdi, LA(2)
  mov rsi, [r13 + rax]
  mov rdx, [r13 + rax + 8]
  xor ecx, ecx
  call stringify
  inc rbx
  jmp 1b
3:
  lea rdi, LA(2)
  mov esi, 10
  call sb_putc
  lea rdi, LA(2)
  call sb_finish
  mov rdi, rax
  call out_putstr
  RET_NIL

// Reads one line from stdin (without the line end) -> String*, or 0 at end of input
FN read_line, 3
  lea rdi, LA(2)
  call sb_init
  xor r14d, r14d               // 1 once at least one byte was read
1:
  mov rax, G(in_pos)
  cmp rax, G(in_len)
  jb 3f
  mov rdi, G(in_buf)
  test rdi, rdi
  jnz 2f
  mov edi, 4096
  CALLC malloc
  mov G(in_buf), rax
  mov rdi, rax
2:
  mov rsi, rdi
  xor edi, edi
  mov edx, 4096
  CALLC read
  test rax, rax
  jg 4f
  test r14d, r14d              // end of input
  jnz 6f
  lea rdi, LA(2)
  call sb_finish
  xor eax, eax
  EPI
4:
  mov G(in_len), rax
  mov G(in_pos), 0
  jmp 1b
3:
  mov rcx, G(in_buf)
  movzx esi, byte ptr [rcx + rax]
  inc G(in_pos)
  mov r14d, 1
  cmp esi, 10
  je 6f
  lea rdi, LA(2)
  call sb_putc
  jmp 1b
6:
  lea rdi, LA(2)
  call sb_finish
  mov rcx, [rax]
  test rcx, rcx
  jz 7f
  cmp byte ptr [rax + 16 + rcx - 1], 13   // strip the '\r' of CRLF line ends
  jne 7f
  dec qword ptr [rax]
  mov byte ptr [rax + 16 + rcx - 1], 0
7:
  EPI

NATIVE nat_input, 4
  test r14, r14
  jz 2f
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, [r13]
  mov rdx, [r13 + 8]
  xor ecx, ecx
  call stringify
  lea rdi, LA(2)
  call sb_finish
  mov rdi, rax
  call out_putstr
  call out_flush
2:
  call read_line
  test rax, rax
  jnz 3f
  RET_NIL
3:
  mov rdx, rax
  mov eax, T_STR
  EPI

NATIVE nat_len, 0
  mov rax, [r13]
  mov rdx, [r13 + 8]
  cmp rax, T_STR
  jne 1f
  mov rdx, [rdx]
  mov eax, T_INT
  EPI
1:
  cmp rax, T_ARR
  jne 2f
  mov rdx, [rdx + AR_LEN]
  mov eax, T_INT
  EPI
2:
  LEAS rdi, "len"
  LEAS rsi, "a string or an array"
  mov rdx, [r13]
  mov rcx, [r13 + 8]
  call fail_expect
  EPI

NATIVE nat_typeof, 0
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  call value_type_name
  mov rdx, rax
  mov eax, T_STR
  EPI

NATIVE nat_string, 4
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  mov rsi, [r13]
  mov rdx, [r13 + 8]
  xor ecx, ecx
  call stringify
  lea rdi, LA(2)
  call sb_finish
  mov rdx, rax
  mov eax, T_STR
  EPI

NATIVE nat_bool, 0
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  call truthy
  mov edx, eax
  mov eax, T_BOOL
  EPI

NATIVE nat_int, 6
  mov rax, [r13]
  mov rdx, [r13 + 8]
  cmp rax, T_INT
  jne 1f
  EPI
1:
  cmp rax, T_BOOL
  jne 2f
  mov eax, T_INT
  EPI
2:
  cmp rax, T_FLOAT
  jne 5f
  movq xmm0, rdx                // truncation; NaN / out of range -> error
  movsd xmm1, qword ptr [rip + lim_hi]
  ucomisd xmm1, xmm0
  jbe 3f
  movsd xmm1, qword ptr [rip + lim_lo]
  ucomisd xmm0, xmm1
  jb 3f
  cvttsd2si rdx, xmm0
  mov eax, T_INT
  EPI
3:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot convert "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, [r13 + 8]
  movq xmm0, rsi
  call fmt_float
  lea rdi, LA(2)
  LEAS rsi, " to int"
  call sb_putcs
  jmp 9f
5:
  cmp rax, T_STR
  jne 8f
  mov rsi, rdx                  // parse optional spaces, sign, digits, optional spaces
  mov rbx, rsi
  lea r12, [rsi + 16]
  lea r14, [r12 + 0]
  add r14, [rsi]                // end
6:
  cmp r12, r14
  jae 7f
  movzx eax, byte ptr [r12]
  cmp al, ' '
  je 61f
  cmp al, 9
  je 61f
  cmp al, 10
  je 61f
  cmp al, 13
  jne 62f
61:
  inc r12
  jmp 6b
62:
  xor r15d, r15d                // sign
  cmp al, '-'
  jne 63f
  mov r15d, 1
  inc r12
  jmp 64f
63:
  cmp al, '+'
  jne 64f
  inc r12
64:
  xor ecx, ecx                  // digit count
  xor eax, eax                  // value
65:
  cmp r12, r14
  jae 66f
  movzx edx, byte ptr [r12]
  sub edx, '0'
  cmp edx, 9
  ja 66f
  imul rax, rax, 10
  jo 7f
  add rax, rdx
  jo 7f
  inc r12
  inc ecx
  jmp 65b
66:
  test ecx, ecx
  jz 7f
67:                              // trailing spaces
  cmp r12, r14
  jae 68f
  movzx edx, byte ptr [r12]
  cmp dl, ' '
  je 69f
  cmp dl, 9
  je 69f
  cmp dl, 10
  je 69f
  cmp dl, 13
  jne 7f
69:
  inc r12
  jmp 67b
68:
  test r15d, r15d
  jz 70f
  neg rax
70:
  mov rdx, rax
  mov eax, T_INT
  EPI
7:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot convert "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, rbx
  call str_quote
  lea rdi, LA(2)
  LEAS rsi, " to int"
  call sb_putcs
  jmp 9f
8:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot convert "
  call sb_putcs
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  call value_type_name
  mov rsi, rax
  lea rdi, LA(2)
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, " to int"
  call sb_putcs
9:
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
  EPI

NATIVE nat_float, 6
  mov rax, [r13]
  mov rdx, [r13 + 8]
  cmp rax, T_FLOAT
  jne 1f
  EPI
1:
  cmp rax, T_INT
  jne 2f
  cvtsi2sd xmm0, rdx
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI
2:
  cmp rax, T_BOOL
  jne 3f
  cvtsi2sd xmm0, rdx
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI
3:
  cmp rax, T_STR
  jne 8f
  mov rbx, rdx
  lea rdi, [rbx + 16]
  lea rsi, LA(0)                // char* end
  CALLC strtod
  movq r12, xmm0
  mov rax, [rbp - 48]           // end
  lea rcx, [rbx + 16]
  cmp rax, rcx
  je 7f                         // nothing parsed
  lea rdx, [rcx + 0]
  add rdx, [rbx]
4:
  cmp rax, rdx
  jae 5f
  movzx ecx, byte ptr [rax]
  cmp cl, ' '
  je 6f
  cmp cl, 9
  je 6f
  cmp cl, 10
  je 6f
  cmp cl, 13
  jne 7f
6:
  inc rax
  jmp 4b
5:
  cmp qword ptr [rbx], 0
  je 7f
  mov rdx, r12
  mov eax, T_FLOAT
  EPI
7:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot convert "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, rbx
  call str_quote
  lea rdi, LA(2)
  LEAS rsi, " to float"
  call sb_putcs
  jmp 9f
8:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot convert "
  call sb_putcs
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  call value_type_name
  mov rsi, rax
  lea rdi, LA(2)
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, " to float"
  call sb_putcs
9:
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
  EPI

NATIVE nat_range, 4            // start L(0), stop L(1), step L(2)
  mov L(0), 0
  mov L(2), 1
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "range"
  call need_int
  cmp r14, 1
  jne 1f
  mov L(1), rax                // range(stop)
  jmp 3f
1:
  mov L(0), rax
  mov rdi, [r13 + 16]
  mov rsi, [r13 + 24]
  LEAS rdx, "range"
  call need_int
  mov L(1), rax
  cmp r14, 3
  jne 3f
  mov rdi, [r13 + 32]
  mov rsi, [r13 + 40]
  LEAS rdx, "range"
  call need_int
  mov L(2), rax
3:
  cmp L(2), 0
  jne 4f
  LEAS rdi, "range() step cannot be zero"
  call fail_rt
4:
  xor edi, edi
  call arr_new
  mov rbx, rax
  mov r12, L(0)                // i
  mov r13, 0
5:
  mov rax, L(2)
  test rax, rax
  js 6f
  cmp r12, L(1)
  jge 9f
  jmp 7f
6:
  cmp r12, L(1)
  jle 9f
7:
  inc r13
  cmp r13, 50000000
  jbe 8f
  LEAS rdi, "range() is too large"
  call fail_rt
8:
  mov rdi, rbx
  mov esi, T_INT
  mov rdx, r12
  call arr_push
  add r12, L(2)
  jmp 5b
9:
  mov eax, T_ARR
  mov rdx, rbx
  EPI

NATIVE nat_abs, 0
  mov rax, [r13]
  mov rdx, [r13 + 8]
  cmp rax, T_INT
  jne 1f
  test rdx, rdx
  jns 2f
  neg rdx                      // abs(INT64_MIN) wraps, like in the C++ version
2:
  EPI
1:
  mov rdi, rax
  mov rsi, rdx
  LEAS rdx, "abs"
  call need_num
  movq rax, xmm0
  btr rax, 63
  mov rdx, rax
  mov eax, T_FLOAT
  EPI

NATIVE nat_sqrt, 0
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "sqrt"
  call need_num
  xorpd xmm1, xmm1
  ucomisd xmm1, xmm0
  jbe 1f
  LEAS rdi, "sqrt() of a negative number"
  call fail_rt
1:
  sqrtsd xmm0, xmm0
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI

NATIVE nat_pow, 0
  mov rax, [r13]
  mov rdx, [r13 + 8]
  cmp rax, T_INT
  jne 2f
  cmp qword ptr [r13 + 16], T_INT
  jne 2f
  mov rcx, [r13 + 24]          // exponent
  test rcx, rcx
  js 2f
  mov rax, 1
1:
  test rcx, rcx
  jz 3f
  test rcx, 1
  jz 4f
  imul rax, rdx
4:
  imul rdx, rdx
  shr rcx, 1
  jmp 1b
3:
  mov rdx, rax
  mov eax, T_INT
  EPI
2:
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "pow"
  call need_num
  movq rbx, xmm0
  mov rdi, [r13 + 16]
  mov rsi, [r13 + 24]
  LEAS rdx, "pow"
  call need_num
  movaps xmm1, xmm0
  movq xmm0, rbx
  CALLC pow
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI

.macro ROUNDER name, fname, cfunc
NATIVE \name, 0
  mov rax, [r13]
  mov rdx, [r13 + 8]
  cmp rax, T_INT
  jne 1f
  EPI
1:
  mov rdi, rax
  mov rsi, rdx
  LEAS rdx, "\fname"
  call need_num
  CALLC \cfunc
  movsd xmm1, qword ptr [rip + lim_hi]
  ucomisd xmm1, xmm0
  jbe 2f
  movsd xmm1, qword ptr [rip + lim_lo]
  ucomisd xmm0, xmm1
  jb 2f
  cvttsd2si rdx, xmm0
  mov eax, T_INT
  EPI
2:
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI
.endm
ROUNDER nat_floor, floor, floor
ROUNDER nat_ceil, ceil, ceil
ROUNDER nat_round, round, round

// The runtime delegates the standard transcendental functions to libm.
.macro UNARY_LIBM name, fname, cfunc
NATIVE \name, 0
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "\fname"
  call need_num
  CALLC \cfunc
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI
.endm
UNARY_LIBM nat_sin, sin, sin
UNARY_LIBM nat_cos, cos, cos
UNARY_LIBM nat_tan, tan, tan
UNARY_LIBM nat_asin, asin, asin
UNARY_LIBM nat_acos, acos, acos
UNARY_LIBM nat_atan, atan, atan
UNARY_LIBM nat_sinh, sinh, sinh
UNARY_LIBM nat_cosh, cosh, cosh
UNARY_LIBM nat_tanh, tanh, tanh
UNARY_LIBM nat_log, log, log
UNARY_LIBM nat_log10, log10, log10
UNARY_LIBM nat_exp, exp, exp

.macro BINARY_LIBM name, fname, cfunc
NATIVE \name, 0
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "\fname"
  call need_num
  movq rbx, xmm0
  mov rdi, [r13 + 16]
  mov rsi, [r13 + 24]
  LEAS rdx, "\fname"
  call need_num
  movapd xmm1, xmm0
  movq xmm0, rbx
  CALLC \cfunc
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI
.endm
BINARY_LIBM nat_atan2, atan2, atan2
BINARY_LIBM nat_fmod, fmod, fmod
BINARY_LIBM nat_hypot, hypot, hypot

// Basic cross-platform operating-system and text-file helpers.
NATIVE nat_os_env_get, 1
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "envGet"
  call need_str
  lea rdi, [rax + 16]
  CALLC getenv
  test rax, rax
  jz .Los_env_missing
  mov rbx, rax
  mov rdi, rax
  CALLC strlen
  mov rsi, rax
  mov rdi, rbx
  call str_new
  mov rdx, rax
  mov eax, T_STR
  EPI
.Los_env_missing:
  RET_NIL

NATIVE nat_os_file_exists, 1
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "fileExists"
  call need_str
  lea rdi, [rax + 16]
  LEAS rsi, "rb"
  CALLC fopen
  test rax, rax
  jz 1f
  mov rdi, rax
  CALLC fclose
  mov ecx, 1
  RET_BOOL cx
1:
  xor ecx, ecx
  RET_BOOL cx

NATIVE nat_os_read_text, 2
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "readText"
  call need_str
  lea rdi, [rax + 16]
  LEAS rsi, "rb"
  CALLC fopen
  test rax, rax
  jz .Los_read_open_error
  mov rbx, rax
  mov rdi, rbx
  xor esi, esi                  // offset = 0
  mov edx, 2                    // SEEK_END
  CALLC fseek
  test eax, eax
  jnz .Los_read_io_error
  mov rdi, rbx
  CALLC ftell
  test rax, rax
  js .Los_read_io_error
  mov r12, rax                 // file length
  cmp r12, 67108864            // 64 MiB safety limit for text reads
  ja .Los_read_io_error
  mov rdi, rbx
  xor esi, esi                 // SEEK_SET
  xor edx, edx
  CALLC fseek
  test eax, eax
  jnz .Los_read_io_error
  lea rdi, [r12 + 1]
  call hx_alloc
  mov r13, rax                 // buffer
  test r12, r12
  jz .Los_read_done
  mov rdi, r13
  mov esi, 1
  mov rdx, r12
  mov rcx, rbx
  CALLC fread
  cmp rax, r12
  jne .Los_read_io_error
.Los_read_done:
  mov rdi, rbx
  CALLC fclose
  mov rdi, r13
  mov rsi, r12
  call str_new
  mov rdx, rax
  mov eax, T_STR
  EPI
.Los_read_open_error:
  LEAS rdi, "readText: cannot open file"
  call fail_rt
.Los_read_io_error:
  mov rdi, rbx
  CALLC fclose
  LEAS rdi, "readText: I/O error while reading file"
  call fail_rt

.macro OS_WRITE_NATIVE name, fname, mode
NATIVE \name, 2
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "\fname"
  call need_str
  mov r12, rax                 // path String*
  mov rdi, [r13 + 16]
  mov rsi, [r13 + 24]
  LEAS rdx, "\fname"
  call need_str
  mov r14, rax                 // content String*
  lea rdi, [r12 + 16]
  LEAS rsi, "\mode"
  CALLC fopen
  test rax, rax
  jz .Los_write_open_error\@
  mov rbx, rax
  lea rdi, [r14 + 16]
  mov esi, 1
  mov rdx, [r14]
  mov rcx, rbx
  CALLC fwrite
  mov r13, rax                 // bytes written
  mov rdi, rbx
  CALLC fclose
  test eax, eax
  jnz .Los_write_io_error\@
  cmp r13, [r14]
  jne .Los_write_io_error\@
  RET_INT r13
.Los_write_open_error\@:
  LEAS rdi, "\fname: cannot open file for writing"
  call fail_rt
.Los_write_io_error\@:
  LEAS rdi, "\fname: I/O error while writing file"
  call fail_rt
.endm
OS_WRITE_NATIVE nat_os_write_text, writeText, wb
OS_WRITE_NATIVE nat_os_append_text, appendText, ab

NATIVE nat_os_remove_file, 0
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "removeFile"
  call need_str
  lea rdi, [rax + 16]
  CALLC remove
  test eax, eax
  jnz 1f
  mov ecx, 1
  RET_BOOL cx
1:
  xor ecx, ecx
  RET_BOOL cx

NATIVE nat_os_rename_file, 2
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "renameFile"
  call need_str
  mov rbx, rax
  mov rdi, [r13 + 16]
  mov rsi, [r13 + 24]
  LEAS rdx, "renameFile"
  call need_str
  lea rdi, [rbx + 16]
  lea rsi, [rax + 16]
  CALLC rename
  test eax, eax
  jnz 1f
  mov ecx, 1
  RET_BOOL cx
1:
  xor ecx, ecx
  RET_BOOL cx

NATIVE nat_os_current_directory, 1
  mov edi, 4096
  call hx_alloc
  mov rbx, rax
  mov rdi, rbx
  mov esi, 4096
#if defined(OS_WIN)
  CALLC _getcwd
#else
  CALLC getcwd
#endif
  test rax, rax
  jz 1f
  mov rdi, rax
  CALLC strlen
  mov rsi, rax
  mov rdi, rbx
  call str_new
  mov rdx, rax
  mov eax, T_STR
  EPI
1:
  LEAS rdi, "currentDirectory: cannot determine working directory"
  call fail_rt

.macro MINMAX name, fname, setcc
NATIVE \name, 4
  mov rax, [r13]
  mov rdx, [r13 + 8]
  mov L(0), rax                // best so far
  mov L(1), rdx
  mov rdi, rax
  mov rsi, rdx
  LEAS rdx, "\fname"
  call need_num
  movq rbx, xmm0
  mov r12d, 1
1:
  cmp r12, r14
  jae 2f
  mov rax, r12
  shl rax, 4
  mov rdi, [r13 + rax]
  mov rsi, [r13 + rax + 8]
  mov L(2), rdi
  mov L(3), rsi
  LEAS rdx, "\fname"
  call need_num
  movq xmm1, rbx
  ucomisd xmm0, xmm1
  \setcc 3f
  jmp 4f
3:
  movq rbx, xmm0
  mov rax, L(2)
  mov L(0), rax
  mov rax, L(3)
  mov L(1), rax
4:
  inc r12
  jmp 1b
2:
  mov rax, L(0)
  mov rdx, L(1)
  EPI
.endm
MINMAX nat_min, min, jb
MINMAX nat_max, max, ja

NATIVE nat_clock, 0
  CALLC clock
#if defined(OS_WIN)
  movsxd rax, eax              // clock_t is a 32-bit long on Windows
#endif
  cvtsi2sd xmm0, rax
  divsd xmm0, qword ptr [rip + cps]
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI

NATIVE nat_assert, 4
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  call truthy
  test eax, eax
  jz 1f
  RET_NIL
1:
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Assertion failed"
  call sb_putcs
  cmp r14, 2
  jb 2f
  lea rdi, LA(2)
  LEAS rsi, ": "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, [r13 + 16]
  mov rdx, [r13 + 24]
  xor ecx, ecx
  call stringify
2:
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
  EPI

// Random number utilities. `random()` returns [0, 1), `randomInt(a,b)` is inclusive.
NATIVE nat_random, 0
  CALLC rand
  movsxd rax, eax
  cvtsi2sd xmm0, rax
  divsd xmm0, qword ptr [rip + rand_scale]
  movq rdx, xmm0
  mov eax, T_FLOAT
  EPI

NATIVE nat_random_int, 4
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "randomInt"
  call need_int
  mov L(0), rax                // minimum
  mov rdi, [r13 + 16]
  mov rsi, [r13 + 24]
  LEAS rdx, "randomInt"
  call need_int
  mov L(1), rax                // maximum
  cmp rax, L(0)
  jl .Lrandom_range_error
  sub rax, L(0)
  jo .Lrandom_range_error
  add rax, 1
  jo .Lrandom_range_error
  test rax, rax
  jle .Lrandom_range_error
  mov rcx, RAND_LIMIT
  cmp rax, rcx
  ja .Lrandom_range_error
  mov L(2), rax                // span
  CALLC rand
  movsxd rax, eax
  xor edx, edx
  div L(2)
  add rdx, L(0)
  RET_INT rdx
.Lrandom_range_error:
  LEAS rdi, "randomInt() requires min <= max and a range no larger than RAND_MAX + 1"
  call fail_rt
  EPI

NATIVE nat_seed_random, 0
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "seedRandom"
  call need_int
  mov edi, eax
  CALLC srand
  RET_NIL

NATIVE nat_random_choice, 0
  cmp qword ptr [r13], T_ARR
  jne .Lrandom_choice_type
  mov r12, [r13 + 8]
  mov rcx, [r12 + AR_LEN]
  test rcx, rcx
  jz .Lrandom_choice_empty
  CALLC rand
  movsxd rax, eax
  xor edx, edx
  div qword ptr [r12 + AR_LEN]
  shl rdx, 4
  add rdx, [r12 + AR_DATA]
  mov rax, [rdx]
  mov rdx, [rdx + 8]
  EPI
.Lrandom_choice_type:
  LEAS rdi, "randomChoice() expects an array"
  call fail_rt
  EPI
.Lrandom_choice_empty:
  LEAS rdi, "randomChoice() cannot choose from an empty array"
  call fail_rt
  EPI

NATIVE nat_exit, 0
  xor ebx, ebx
  test r14, r14
  jz 1f
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "exit"
  call need_int
  mov rbx, rax
1:
  call out_flush
  mov rdi, rbx
  CALLC exit
  EPI

// ------------------------------------------------------------- array methods
NATIVE nat_push, 0
  mov r12, [r15 + FO_BPAY]
  xor ebx, ebx
1:
  cmp rbx, r14
  jae 2f
  mov rax, rbx
  shl rax, 4
  mov rdi, r12
  mov rsi, [r13 + rax]
  mov rdx, [r13 + rax + 8]
  call arr_push
  inc rbx
  jmp 1b
2:
  mov rdx, [r12 + AR_LEN]
  mov eax, T_INT
  EPI

NATIVE nat_pop, 0
  mov r12, [r15 + FO_BPAY]
  mov rcx, [r12 + AR_LEN]
  test rcx, rcx
  jnz 1f
  RET_NIL
1:
  dec rcx
  mov [r12 + AR_LEN], rcx
  shl rcx, 4
  add rcx, [r12 + AR_DATA]
  mov rax, [rcx]
  mov rdx, [rcx + 8]
  EPI

// item i of the receiver -> rdi = tag, rsi = payload (the array may be mutated by callbacks)
.macro LOAD_ITEM arr, idx
  mov rcx, \idx
  shl rcx, 4
  add rcx, [\arr + AR_DATA]
  mov rdi, [rcx]
  mov rsi, [rcx + 8]
.endm

NATIVE nat_map, 4
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "map"
  call need_fn
  mov rdi, [r12 + AR_LEN]
  call arr_new
  mov rbx, rax
  mov L(0), 0
1:
  mov rcx, L(0)
  cmp rcx, [r12 + AR_LEN]
  jae 2f
  LOAD_ITEM r12, rcx
  mov rdx, rdi
  mov rcx, rsi
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  mov r8, L(0)
  call call_cb
  mov rdi, rbx
  mov rsi, rax
  call arr_push
  inc L(0)
  jmp 1b
2:
  mov eax, T_ARR
  mov rdx, rbx
  EPI

NATIVE nat_filter, 4
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "filter"
  call need_fn
  xor edi, edi
  call arr_new
  mov rbx, rax
  mov L(0), 0
1:
  mov rcx, L(0)
  cmp rcx, [r12 + AR_LEN]
  jae 2f
  LOAD_ITEM r12, rcx
  mov L(1), rdi
  mov L(2), rsi
  mov rdx, rdi
  mov rcx, rsi
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  mov r8, L(0)
  call call_cb
  mov rdi, rax
  mov rsi, rdx
  call truthy
  test eax, eax
  jz 3f
  mov rdi, rbx
  mov rsi, L(1)
  mov rdx, L(2)
  call arr_push
3:
  inc L(0)
  jmp 1b
2:
  mov eax, T_ARR
  mov rdx, rbx
  EPI

NATIVE nat_foreach, 4
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "forEach"
  call need_fn
  mov L(0), 0
1:
  mov rcx, L(0)
  cmp rcx, [r12 + AR_LEN]
  jae 2f
  LOAD_ITEM r12, rcx
  mov rdx, rdi
  mov rcx, rsi
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  mov r8, L(0)
  call call_cb
  inc L(0)
  jmp 1b
2:
  RET_NIL

NATIVE nat_find, 4
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "find"
  call need_fn
  mov L(0), 0
1:
  mov rcx, L(0)
  cmp rcx, [r12 + AR_LEN]
  jae 2f
  LOAD_ITEM r12, rcx
  mov L(1), rdi
  mov L(2), rsi
  mov rdx, rdi
  mov rcx, rsi
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  mov r8, L(0)
  call call_cb
  mov rdi, rax
  mov rsi, rdx
  call truthy
  test eax, eax
  jnz 3f
  inc L(0)
  jmp 1b
3:
  mov rax, L(1)
  mov rdx, L(2)
  EPI
2:
  RET_NIL

NATIVE nat_reduce, 8           // acc L(1):L(2), index L(0), call buffer LA(7)
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "reduce"
  call need_fn
  mov L(0), 0
  cmp r14, 2
  jb 1f
  mov rax, [r13 + 16]
  mov rdx, [r13 + 24]
  mov L(1), rax
  mov L(2), rdx
  jmp 3f
1:
  cmp qword ptr [r12 + AR_LEN], 0
  jne 2f
  LEAS rdi, "reduce() of an empty array needs an initial value"
  call fail_rt
2:
  LOAD_ITEM r12, 0
  mov L(1), rdi
  mov L(2), rsi
  mov L(0), 1
3:
  mov rcx, L(0)
  cmp rcx, [r12 + AR_LEN]
  jae 4f
  LOAD_ITEM r12, rcx
  mov L(5), rdi                // buffer: [acc][item]
  mov L(4), rsi
  mov rax, L(1)
  mov L(7), rax
  mov rax, L(2)
  mov L(6), rax
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  lea rdx, LA(7)
  mov ecx, 2
  call call_value_rw
  mov L(1), rax
  mov L(2), rdx
  inc L(0)
  jmp 3b
4:
  mov rax, L(1)
  mov rdx, L(2)
  EPI

NATIVE nat_join, 4
  mov r12, [r15 + FO_BPAY]
  lea rdi, LA(2)
  call sb_init
  xor ebx, ebx
1:
  cmp rbx, [r12 + AR_LEN]
  jae 3f
  test rbx, rbx
  jz 2f
  test r14, r14
  jz 21f
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "join"
  call need_str
  mov rsi, rax
  lea rdi, LA(2)
  call sb_putstr
  jmp 2f
21:
  lea rdi, LA(2)
  mov esi, ','
  call sb_putc
2:
  LOAD_ITEM r12, rbx
  mov rdx, rsi
  mov rsi, rdi
  lea rdi, LA(2)
  xor ecx, ecx
  call stringify
  inc rbx
  jmp 1b
3:
  lea rdi, LA(2)
  call sb_finish
  mov rdx, rax
  mov eax, T_STR
  EPI

NATIVE nat_contains, 0
  mov r12, [r15 + FO_BPAY]
  xor ebx, ebx
1:
  cmp rbx, [r12 + AR_LEN]
  jae 2f
  LOAD_ITEM r12, rbx
  mov rdx, [r13]
  mov rcx, [r13 + 8]
  call values_equal
  test eax, eax
  jnz 3f
  inc rbx
  jmp 1b
2:
  xor eax, eax
3:
  mov edx, eax
  mov eax, T_BOOL
  EPI

NATIVE nat_indexof, 0
  mov r12, [r15 + FO_BPAY]
  xor ebx, ebx
1:
  cmp rbx, [r12 + AR_LEN]
  jae 2f
  LOAD_ITEM r12, rbx
  mov rdx, [r13]
  mov rcx, [r13 + 8]
  call values_equal
  test eax, eax
  jnz 3f
  inc rbx
  jmp 1b
2:
  mov rdx, -1
  mov eax, T_INT
  EPI
3:
  mov rdx, rbx
  mov eax, T_INT
  EPI

// clamp an index like slice()/substring(): rdi = value, rsi = length, edx = 1 if negatives count from the end
.balign 16
clamp_index:
  test rdi, rdi
  jns 2f
  test edx, edx
  jz 1f
  add rdi, rsi
  jns 2f
1:
  xor edi, edi
2:
  cmp rdi, rsi
  jle 3f
  mov rdi, rsi
3:
  mov rax, rdi
  ret

NATIVE nat_slice, 4
  mov r12, [r15 + FO_BPAY]
  mov rbx, [r12 + AR_LEN]
  xor eax, eax
  mov L(0), rax                // start
  mov L(1), rbx                // end
  test r14, r14
  jz 1f
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "slice"
  call need_int
  mov rdi, rax
  mov rsi, rbx
  mov edx, 1
  call clamp_index
  mov L(0), rax
  cmp r14, 2
  jb 1f
  mov rdi, [r13 + 16]
  mov rsi, [r13 + 24]
  LEAS rdx, "slice"
  call need_int
  mov rdi, rax
  mov rsi, rbx
  mov edx, 1
  call clamp_index
  mov L(1), rax
1:
  xor edi, edi
  call arr_new
  mov rbx, rax
  mov r14, L(0)
2:
  cmp r14, L(1)
  jge 3f
  LOAD_ITEM r12, r14
  mov rdx, rsi
  mov rsi, rdi
  mov rdi, rbx
  call arr_push
  inc r14
  jmp 2b
3:
  mov eax, T_ARR
  mov rdx, rbx
  EPI

NATIVE nat_reverse, 0
  mov r12, [r15 + FO_BPAY]
  xor ecx, ecx
  mov rdx, [r12 + AR_LEN]
  dec rdx
1:
  cmp rcx, rdx
  jge 2f
  mov rsi, [r12 + AR_DATA]
  mov rax, rcx
  shl rax, 4
  mov r8, rdx
  shl r8, 4
  movups xmm0, [rsi + rax]
  movups xmm1, [rsi + r8]
  movups [rsi + rax], xmm1
  movups [rsi + r8], xmm0
  inc rcx
  dec rdx
  jmp 1b
2:
  mov eax, T_ARR
  mov rdx, r12
  EPI

// stable insertion sort on a copy, then written back (an error leaves the array intact)
NATIVE nat_sort, 8
  mov r12, [r15 + FO_BPAY]
  test r14, r14
  jz 1f
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "sort"
  call need_fn
1:
  mov rbx, [r12 + AR_LEN]
  mov rdi, rbx
  shl rdi, 4
  add rdi, 16
  CALLC malloc
  test rax, rax
  jz hx_oom
  mov L(5), rax                // temp copy
  mov rdi, rax
  mov rsi, [r12 + AR_DATA]
  mov rdx, rbx
  shl rdx, 4
  test rdx, rdx
  jz 2f
  CALLC memcpy
2:
  mov L(0), 1                  // i: binary insertion (stable, O(n log n) comparisons)
3:
  mov rcx, L(0)
  cmp rcx, rbx
  jae 9f
  mov rax, L(5)
  shl rcx, 4
  mov rdx, [rax + rcx]
  mov L(1), rdx                // key
  mov rdx, [rax + rcx + 8]
  mov L(2), rdx
  mov L(3), 0                  // lo
  mov rax, L(0)
  mov L(4), rax                // hi
4:
  mov rax, L(3)
  cmp rax, L(4)
  jae 6f
  add rax, L(4)
  shr rax, 1
  mov L(6), rax                // mid
  shl rax, 4
  add rax, L(5)
  mov rdi, L(1)                // is key < a[mid] ?
  mov rsi, L(2)
  mov rdx, [rax]
  mov rcx, [rax + 8]
  call sort_less
  test eax, eax
  jz 5f
  mov rax, L(6)
  mov L(4), rax                // hi = mid
  jmp 4b
5:
  mov rax, L(6)
  inc rax
  mov L(3), rax                // lo = mid + 1
  jmp 4b
6:
  mov rcx, L(0)                // shift a[lo..i) up by one slot, drop the key at lo
  sub rcx, L(3)
  jz 7f
  mov rax, L(3)
  shl rax, 4
  add rax, L(5)
  lea rdi, [rax + 16]
  mov rsi, rax
  mov rdx, rcx
  shl rdx, 4
  CALLC memmove
7:
  mov rax, L(3)
  shl rax, 4
  add rax, L(5)
  mov rcx, L(1)
  mov [rax], rcx
  mov rcx, L(2)
  mov [rax + 8], rcx
  inc L(0)
  jmp 3b
9:
  mov rdi, [r12 + AR_DATA]     // write back
  mov rsi, L(5)
  mov rdx, rbx
  shl rdx, 4
  test rdx, rdx
  jz 10f
  CALLC memcpy
10:
  mov rdi, L(5)
  CALLC free
  mov eax, T_ARR
  mov rdx, r12
  EPI

FN sort_less, 4                // (rdi, rsi) < (rdx, rcx); the comparator is in the caller's r13 (args) / r14 (argc)
  mov L(3), rdi                // call buffer at LA(3): [a][b]
  mov L(2), rsi
  mov L(1), rdx
  mov L(0), rcx
  mov rbx, [rbp - 24]          // our prologue saved the caller's r13 and r14 here
  mov r12, [rbp - 32]
  test r12, r12
  jnz 1f
  mov rdi, L(3)
  mov rsi, L(2)
  mov rdx, L(1)
  mov rcx, L(0)
  call default_less
  EPI
1:
  mov rdi, [rbx]
  mov rsi, [rbx + 8]
  lea rdx, LA(3)
  mov ecx, 2
  call call_value_rw
  cmp rax, T_INT
  jne 2f
  xor eax, eax
  test rdx, rdx
  sets al
  EPI
2:
  cmp rax, T_FLOAT
  jne 3f
  movq xmm0, rdx
  xorpd xmm1, xmm1
  xor eax, eax
  ucomisd xmm1, xmm0
  seta al
  EPI
3:
  LEAS rdi, "sort() comparator must return a number"
  call fail_rt
  EPI

FN default_less, 3             // (rdi, rsi) < (rdx, rcx) for numbers or strings
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, rcx
  cmp rbx, T_INT
  jne 1f
  cmp r13, T_INT
  jne 1f
  xor eax, eax
  cmp r12, r14
  setl al
  EPI
1:
  lea rax, [rbx - T_INT]
  cmp rax, 1
  ja 2f
  lea rax, [r13 - T_INT]
  cmp rax, 1
  ja 4f
  mov rdi, rbx
  mov rsi, r12
  call to_double
  movq r15, xmm0
  mov rdi, r13
  mov rsi, r14
  call to_double
  movaps xmm1, xmm0
  movq xmm0, r15
  xor eax, eax
  ucomisd xmm1, xmm0
  seta al
  EPI
2:
  cmp rbx, T_STR
  jne 4f
  cmp r13, T_STR
  jne 4f
  mov rdi, r12
  mov rsi, r14
  call str_compare
  xor ecx, ecx
  test rax, rax
  sets cl
  mov eax, ecx
  EPI
4:
  mov rdi, rbx
  mov rsi, r12
  call value_type_name
  mov r15, rax
  mov rdi, r13
  mov rsi, r14
  call value_type_name
  mov r14, rax
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot compare "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r15
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, " with "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r14
  call sb_putstr
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  mov rdx, G(cur_line)
  call fail_sb
  EPI

// ------------------------------------------------------------ string methods
FN str_find, 0                 // rdi = haystack, rsi = needle, rdx = start -> rax = index or -1
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  mov r14, [r12]               // needle length
  mov r15, [rbx]
  sub r15, r14                 // last possible start
  js 8f
1:
  cmp r13, r15
  jg 8f
  lea rdi, [rbx + 16 + r13]
  lea rsi, [r12 + 16]
  mov rdx, r14
  test rdx, rdx
  jz 9f
  CALLC memcmp
  test eax, eax
  jz 9f
  inc r13
  jmp 1b
8:
  mov rax, -1
  EPI
9:
  mov rax, r13
  EPI

NATIVE nat_upper, 0
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r12]
  call str_alloc
  mov rbx, rax
  xor ecx, ecx
1:
  cmp rcx, [r12]
  jae 3f
  movzx eax, byte ptr [r12 + 16 + rcx]
  lea edx, [rax - 'a']
  cmp edx, 25
  ja 2f
  sub eax, 32
2:
  mov [rbx + 16 + rcx], al
  inc rcx
  jmp 1b
3:
  mov eax, T_STR
  mov rdx, rbx
  EPI

NATIVE nat_lower, 0
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r12]
  call str_alloc
  mov rbx, rax
  xor ecx, ecx
1:
  cmp rcx, [r12]
  jae 3f
  movzx eax, byte ptr [r12 + 16 + rcx]
  lea edx, [rax - 'A']
  cmp edx, 25
  ja 2f
  add eax, 32
2:
  mov [rbx + 16 + rcx], al
  inc rcx
  jmp 1b
3:
  mov eax, T_STR
  mov rdx, rbx
  EPI

NATIVE nat_trim, 0
  mov r12, [r15 + FO_BPAY]
  xor ebx, ebx
  mov r14, [r12]
1:
  cmp rbx, r14
  jae 2f
  movzx eax, byte ptr [r12 + 16 + rbx]
  cmp al, ' '
  je 11f
  sub eax, 9
  cmp eax, 4
  ja 2f
11:
  inc rbx
  jmp 1b
2:
  cmp r14, rbx
  jbe 3f
  movzx eax, byte ptr [r12 + 16 + r14 - 1]
  cmp al, ' '
  je 21f
  sub eax, 9
  cmp eax, 4
  ja 3f
21:
  dec r14
  jmp 2b
3:
  lea rdi, [r12 + 16 + rbx]
  mov rsi, r14
  sub rsi, rbx
  call str_new
  mov rdx, rax
  mov eax, T_STR
  EPI

NATIVE nat_scontains, 0
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "contains"
  call need_str
  mov rdi, r12
  mov rsi, rax
  xor edx, edx
  call str_find
  xor edx, edx
  test rax, rax
  setns dl
  mov eax, T_BOOL
  EPI

NATIVE nat_sindexof, 0
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "indexOf"
  call need_str
  mov rdi, r12
  mov rsi, rax
  xor edx, edx
  call str_find
  mov rdx, rax
  mov eax, T_INT
  EPI

NATIVE nat_startswith, 0
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "startsWith"
  call need_str
  mov rbx, rax
  xor edx, edx
  mov rcx, [rbx]
  cmp rcx, [r12]
  ja 1f
  lea rdi, [r12 + 16]
  lea rsi, [rbx + 16]
  mov rdx, rcx
  CALLC memcmp
  xor edx, edx
  test eax, eax
  sete dl
1:
  mov eax, T_BOOL
  EPI

NATIVE nat_endswith, 0
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "endsWith"
  call need_str
  mov rbx, rax
  xor edx, edx
  mov rcx, [rbx]
  cmp rcx, [r12]
  ja 1f
  mov rax, [r12]
  sub rax, rcx
  lea rdi, [r12 + 16 + rax]
  lea rsi, [rbx + 16]
  mov rdx, rcx
  CALLC memcmp
  xor edx, edx
  test eax, eax
  sete dl
1:
  mov eax, T_BOOL
  EPI

NATIVE nat_substring, 4
  mov r12, [r15 + FO_BPAY]
  mov rbx, [r12]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "substring"
  call need_int
  mov rdi, rax
  mov rsi, rbx
  xor edx, edx
  call clamp_index
  mov L(0), rax                // start
  mov L(1), rbx                // end
  cmp r14, 2
  jb 1f
  mov rdi, [r13 + 16]
  mov rsi, [r13 + 24]
  LEAS rdx, "substring"
  call need_int
  mov rdi, rax
  mov rsi, rbx
  xor edx, edx
  call clamp_index
  mov L(1), rax
1:
  mov rax, L(0)
  mov rcx, L(1)
  cmp rax, rcx
  jle 2f
  mov rax, rcx
2:
  lea rdi, [r12 + 16 + rax]
  mov rsi, rcx
  sub rsi, rax
  call str_new
  mov rdx, rax
  mov eax, T_STR
  EPI

NATIVE nat_split, 4
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "split"
  call need_str
  mov rbx, rax                 // separator
  xor edi, edi
  call arr_new
  mov L(0), rax                // result array
  xor r14d, r14d               // start
  cmp qword ptr [rbx], 0
  jne 2f
1:                              // empty separator: one string per byte
  cmp r14, [r12]
  jae 9f
  lea rdi, [r12 + 16 + r14]
  mov esi, 1
  call str_new
  mov rdx, rax
  mov rdi, L(0)
  mov esi, T_STR
  call arr_push
  inc r14
  jmp 1b
2:
  mov rdi, r12
  mov rsi, rbx
  mov rdx, r14
  call str_find
  test rax, rax
  js 4f
  mov r15, rax
  lea rdi, [r12 + 16 + r14]
  mov rsi, r15
  sub rsi, r14
  call str_new
  mov rdx, rax
  mov rdi, L(0)
  mov esi, T_STR
  call arr_push
  lea r14, [r15 + 0]
  add r14, [rbx]
  jmp 2b
4:
  lea rdi, [r12 + 16 + r14]
  mov rsi, [r12]
  sub rsi, r14
  call str_new
  mov rdx, rax
  mov rdi, L(0)
  mov esi, T_STR
  call arr_push
9:
  mov eax, T_ARR
  mov rdx, L(0)
  EPI

NATIVE nat_replace, 4
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "replace"
  call need_str
  mov rbx, rax                 // from
  mov rdi, [r13 + 16]
  mov rsi, [r13 + 24]
  LEAS rdx, "replace"
  call need_str
  mov L(3), rax                // to
  cmp qword ptr [rbx], 0
  jne 1f
  mov eax, T_STR
  mov rdx, r12
  EPI
1:
  lea rdi, LA(2)
  call sb_init
  xor r14d, r14d
2:
  mov rdi, r12
  mov rsi, rbx
  mov rdx, r14
  call str_find
  test rax, rax
  js 3f
  mov r15, rax
  lea rdi, LA(2)
  lea rsi, [r12 + 16 + r14]
  mov rdx, r15
  sub rdx, r14
  call sb_put
  lea rdi, LA(2)
  mov rsi, L(3)
  call sb_putstr
  lea r14, [r15 + 0]
  add r14, [rbx]
  jmp 2b
3:
  lea rdi, LA(2)
  lea rsi, [r12 + 16 + r14]
  mov rdx, [r12]
  sub rdx, r14
  call sb_put
  lea rdi, LA(2)
  call sb_finish
  mov rdx, rax
  mov eax, T_STR
  EPI

NATIVE nat_repeat, 4
  mov r12, [r15 + FO_BPAY]
  mov rdi, [r13]
  mov rsi, [r13 + 8]
  LEAS rdx, "repeat"
  call need_int
  mov rbx, rax
  test rbx, rbx
  jns 1f
  LEAS rdi, "repeat() count cannot be negative"
  call fail_rt
1:
  mov rcx, [r12]
  test rcx, rcx
  jz 2f
  mov rax, 100000000
  xor edx, edx
  div rcx
  cmp rbx, rax
  jbe 2f
  LEAS rdi, "repeat() result is too large"
  call fail_rt
2:
  lea rdi, LA(2)
  call sb_init
  xor r14d, r14d
3:
  cmp r14, rbx
  jae 4f
  lea rdi, LA(2)
  mov rsi, r12
  call sb_putstr
  inc r14
  jmp 3b
4:
  lea rdi, LA(2)
  call sb_finish
  mov rdx, rax
  mov eax, T_STR
  EPI

// ----------------------------------------------------- members of arrays / strings
DATA
.balign 8
arr_methods:                   // id, code, min, max
  .quad K_push, nat_push, 0, -1
  .quad K_pop, nat_pop, 0, 0
  .quad K_map, nat_map, 1, 1
  .quad K_filter, nat_filter, 1, 1
  .quad K_forEach, nat_foreach, 1, 1
  .quad K_reduce, nat_reduce, 1, 2
  .quad K_find, nat_find, 1, 1
  .quad K_join, nat_join, 0, 1
  .quad K_contains, nat_contains, 1, 1
  .quad K_indexOf, nat_indexof, 1, 1
  .quad K_slice, nat_slice, 0, 2
  .quad K_reverse, nat_reverse, 0, 0
  .quad K_sort, nat_sort, 0, 1
  .quad 0, 0, 0, 0
str_methods:
  .quad K_upper, nat_upper, 0, 0
  .quad K_lower, nat_lower, 0, 0
  .quad K_trim, nat_trim, 0, 0
  .quad K_contains, nat_scontains, 1, 1
  .quad K_startsWith, nat_startswith, 1, 1
  .quad K_endsWith, nat_endswith, 1, 1
  .quad K_indexOf, nat_sindexof, 1, 1
  .quad K_substring, nat_substring, 1, 2
  .quad K_split, nat_split, 1, 1
  .quad K_replace, nat_replace, 2, 2
  .quad K_repeat, nat_repeat, 1, 1
  .quad 0, 0, 0, 0
globals_table:                 // global functions: id, code, min, max
  .quad K_print, nat_print, 0, -1
  .quad K_input, nat_input, 0, 1
  .quad K_len, nat_len, 1, 1
  .quad K_typeof, nat_typeof, 1, 1
  .quad K_int, nat_int, 1, 1
  .quad K_float, nat_float, 1, 1
  .quad K_string, nat_string, 1, 1
  .quad K_bool, nat_bool, 1, 1
  .quad K_range, nat_range, 1, 3
  .quad K_abs, nat_abs, 1, 1
  .quad K_sqrt, nat_sqrt, 1, 1
  .quad K_pow, nat_pow, 2, 2
  .quad K_floor, nat_floor, 1, 1
  .quad K_ceil, nat_ceil, 1, 1
  .quad K_round, nat_round, 1, 1
  .quad K_min, nat_min, 1, -1
  .quad K_max, nat_max, 1, -1
  .quad K_sin, nat_sin, 1, 1
  .quad K_cos, nat_cos, 1, 1
  .quad K_tan, nat_tan, 1, 1
  .quad K_asin, nat_asin, 1, 1
  .quad K_acos, nat_acos, 1, 1
  .quad K_atan, nat_atan, 1, 1
  .quad K_atan2, nat_atan2, 2, 2
  .quad K_sinh, nat_sinh, 1, 1
  .quad K_cosh, nat_cosh, 1, 1
  .quad K_tanh, nat_tanh, 1, 1
  .quad K_log, nat_log, 1, 1
  .quad K_log10, nat_log10, 1, 1
  .quad K_exp, nat_exp, 1, 1
  .quad K_fmod, nat_fmod, 2, 2
  .quad K_hypot, nat_hypot, 2, 2
  .quad K_envGet, nat_os_env_get, 1, 1
  .quad K_fileExists, nat_os_file_exists, 1, 1
  .quad K_readText, nat_os_read_text, 1, 1
  .quad K_writeText, nat_os_write_text, 2, 2
  .quad K_appendText, nat_os_append_text, 2, 2
  .quad K_removeFile, nat_os_remove_file, 1, 1
  .quad K_renameFile, nat_os_rename_file, 2, 2
  .quad K_currentDirectory, nat_os_current_directory, 0, 0
  .quad K_clock, nat_clock, 0, 0
  .quad K_assert, nat_assert, 1, 2
  .quad K_random, nat_random, 0, 0
  .quad K_randomInt, nat_random_int, 2, 2
  .quad K_seedRandom, nat_seed_random, 1, 1
  .quad K_randomChoice, nat_random_choice, 1, 1
  .quad K_exit, nat_exit, 0, 1
  // JSON
  .quad K_jsonParse, SYM(nat_json_parse), 1, 1
  .quad K_jsonStringify, SYM(nat_json_stringify), 1, 1
  .quad K_jsonObject, SYM(nat_json_object), 0, 0
  .quad K_jsonArray, SYM(nat_json_array), 0, 0
  .quad K_jsonGet, SYM(nat_json_get), 2, 3
  .quad K_jsonSet, SYM(nat_json_set), 3, 3
  .quad K_jsonHas, SYM(nat_json_has), 2, 2
  .quad K_jsonKeys, SYM(nat_json_keys), 1, 1
  .quad K_jsonIsObject, SYM(nat_json_is_object), 1, 1
  .quad K_jsonRemove, SYM(nat_json_remove), 2, 2
  // CSV / tabular
  .quad K_csvParse, SYM(nat_csv_parse), 1, 1
  .quad K_csvStringify, SYM(nat_csv_stringify), 1, 1
  .quad K_tabularFromRows, SYM(nat_tabular_from_rows), 1, 2
  .quad K_tabularReadCSV, SYM(nat_tabular_read_csv), 1, 2
  .quad K_tabularToCSV, SYM(nat_tabular_to_csv), 1, 1
  .quad K_tabularWriteCSV, SYM(nat_tabular_write_csv), 2, 2
  .quad K_tabularColumns, SYM(nat_tabular_columns), 1, 1
  .quad K_tabularRows, SYM(nat_tabular_rows), 1, 1
  .quad K_tabularShape, SYM(nat_tabular_shape), 1, 1
  .quad K_tabularHead, SYM(nat_tabular_head), 1, 2
  .quad K_tabularColumn, SYM(nat_tabular_column), 2, 2
  .quad K_tabularSelect, SYM(nat_tabular_select), 2, 2
  .quad K_tabularSortBy, SYM(nat_tabular_sort_by), 2, 3
  .quad K_tabularFilterEquals, SYM(nat_tabular_filter_equals), 3, 3
  .quad K_tabularInferTypes, SYM(nat_tabular_infer_types), 1, 1
  // SQLite
  .quad K_sqliteOpen, SYM(nat_sqlite_open), 1, 1
  .quad K_sqliteClose, SYM(nat_sqlite_close), 1, 1
  .quad K_sqliteExec, SYM(nat_sqlite_exec), 2, 2
  .quad K_sqliteQuery, SYM(nat_sqlite_query), 2, 2
  .quad K_sqlitePrepare, SYM(nat_sqlite_prepare), 2, 2
  .quad K_sqliteBindInt, SYM(nat_sqlite_bind_int), 3, 3
  .quad K_sqliteBindFloat, SYM(nat_sqlite_bind_float), 3, 3
  .quad K_sqliteBindText, SYM(nat_sqlite_bind_text), 3, 3
  .quad K_sqliteBindNull, SYM(nat_sqlite_bind_null), 2, 2
  .quad K_sqliteStep, SYM(nat_sqlite_step), 1, 1
  .quad K_sqliteColumnCount, SYM(nat_sqlite_column_count), 1, 1
  .quad K_sqliteColumnName, SYM(nat_sqlite_column_name), 2, 2
  .quad K_sqliteColumn, SYM(nat_sqlite_column_value), 2, 2
  .quad K_sqliteColumnType, SYM(nat_sqlite_column_type), 2, 2
  .quad K_sqliteReset, SYM(nat_sqlite_reset), 1, 1
  .quad K_sqliteFinalize, SYM(nat_sqlite_finalize), 1, 1
  .quad K_sqliteChanges, SYM(nat_sqlite_changes), 1, 1
  .quad K_sqliteLastInsertId, SYM(nat_sqlite_last_insert_id), 1, 1
  // MySQL / MariaDB
  .quad K_mysqlOpen, SYM(nat_mysql_open), 4, 5
  .quad K_mysqlClose, SYM(nat_mysql_close), 1, 1
  .quad K_mysqlExec, SYM(nat_mysql_exec), 2, 2
  .quad K_mysqlQuery, SYM(nat_mysql_query), 2, 2
  .quad K_mysqlError, SYM(nat_mysql_error), 1, 1
  .quad K_mysqlPrepare, SYM(nat_mysql_prepare), 2, 2
  .quad K_mysqlStmtBindInt, SYM(nat_mysql_stmt_bind_int), 3, 3
  .quad K_mysqlStmtBindFloat, SYM(nat_mysql_stmt_bind_float), 3, 3
  .quad K_mysqlStmtBindText, SYM(nat_mysql_stmt_bind_text), 3, 3
  .quad K_mysqlStmtBindNull, SYM(nat_mysql_stmt_bind_null), 2, 2
  .quad K_mysqlStmtExecute, SYM(nat_mysql_stmt_execute), 1, 1
  .quad K_mysqlStmtQuery, SYM(nat_mysql_stmt_query), 1, 1
  .quad K_mysqlStmtClose, SYM(nat_mysql_stmt_close), 1, 1
  // HTTP / HTML
  .quad K_webServe, SYM(nat_web_serve), 2, 3
  .quad K_htmlEscape, SYM(nat_web_html_escape), 1, 1
  .quad K_webResponse, SYM(nat_web_response), 1, 4
  .quad K_webUrlEncode, SYM(nat_web_url_encode), 1, 1
  .quad K_webUrlDecode, SYM(nat_web_url_decode), 1, 1
  // SDL game backend
  .quad K_gameInit, SYM(nat_game_init), 3, 4
  .quad K_gameQuit, SYM(nat_game_quit), 0, 0
  .quad K_gamePollEvent, SYM(nat_game_poll_event), 0, 0
  .quad K_gameShouldClose, SYM(nat_game_should_close), 0, 0
  .quad K_gameSetTitle, SYM(nat_game_set_title), 1, 1
  .quad K_gameClear, SYM(nat_game_clear), 1, 2
  .quad K_gamePresent, SYM(nat_game_present), 0, 0
  .quad K_gameDrawLine, SYM(nat_game_draw_line), 5, 6
  .quad K_gameDrawRect, SYM(nat_game_draw_rect), 5, 6
  .quad K_gameDrawCircle, SYM(nat_game_draw_circle), 4, 5
  .quad K_gameKeyDown, SYM(nat_game_key_down), 1, 1
  .quad K_gameMouse, SYM(nat_game_mouse), 0, 0
  .quad K_gameTicks, SYM(nat_game_ticks), 0, 0
  .quad K_gameDelay, SYM(nat_game_delay), 1, 1
  .quad K_gameWindowSize, SYM(nat_game_window_size), 0, 0
  .quad K_gameBackend, SYM(nat_game_backend), 0, 0
  // Raylib 2D and 3D facades
  .quad K_simpleInit, SYM(nat_simple_init), 3, 3
  .quad K_simpleClose, SYM(nat_simple_close), 0, 0
  .quad K_simpleShouldClose, SYM(nat_simple_should_close), 0, 0
  .quad K_simpleBegin, SYM(nat_simple_begin), 0, 0
  .quad K_simpleEnd, SYM(nat_simple_end), 0, 0
  .quad K_simpleClear, SYM(nat_simple_clear), 1, 1
  .quad K_simpleRect, SYM(nat_simple_rect), 5, 6
  .quad K_simpleLine, SYM(nat_simple_line), 5, 5
  .quad K_simpleCircle, SYM(nat_simple_circle), 4, 5
  .quad K_simpleText, SYM(nat_simple_text), 5, 5
  .quad K_simpleKeyDown, SYM(nat_simple_key_down), 1, 1
  .quad K_simpleKeyPressed, SYM(nat_simple_key_pressed), 1, 1
  .quad K_simpleMouse, SYM(nat_simple_mouse), 0, 0
  .quad K_simpleFrameTime, SYM(nat_simple_frame_time), 0, 0
  .quad K_simpleFps, SYM(nat_simple_fps), 0, 0
  .quad K_simpleTargetFps, SYM(nat_simple_target_fps), 1, 1
  .quad K_simpleTextureLoad, SYM(nat_simple_texture_load), 1, 1
  .quad K_simpleTextureDraw, SYM(nat_simple_texture_draw), 3, 4
  .quad K_simpleTextureUnload, SYM(nat_simple_texture_unload), 1, 1
  .quad K_simpleSetTitle, SYM(nat_simple_set_window_title), 1, 1
  .quad K_simpleFullscreen, SYM(nat_simple_set_fullscreen), 0, 0
  .quad K_simpleBackend, SYM(nat_simple_backend), 0, 0
  .quad K_3dBegin, SYM(nat_3d_begin), 10, 10
  .quad K_3dEnd, SYM(nat_3d_end), 0, 0
  .quad K_3dCube, SYM(nat_3d_cube), 7, 7
  .quad K_3dSphere, SYM(nat_3d_sphere), 5, 5
  .quad K_3dGrid, SYM(nat_3d_grid), 1, 2
  .quad 0, 0, 0, 0

TEXT
FN native_member, 0            // rdi = tag (array / string), rsi = payload, rdx = name -> rax:rdx
  mov rbx, rdi
  mov r12, rsi
  mov r13, rdx
  cmp qword ptr [r13 + 8], K_length
  jne 1f
  mov eax, T_INT
  cmp rbx, T_ARR
  jne 11f
  mov rdx, [r12 + AR_LEN]
  EPI
11:
  mov rdx, [r12]
  EPI
1:
  lea r14, [rip + arr_methods]
  cmp rbx, T_ARR
  je 2f
  lea r14, [rip + str_methods]
2:
  mov rax, [r14]
  test rax, rax
  jz 4f
  cmp rax, [r13 + 8]
  je 3f
  add r14, 32
  jmp 2b
3:
  mov rdi, [r14 + 8]
  mov rsi, r13
  mov rdx, [r14 + 16]
  mov rcx, [r14 + 24]
  call native_new
  mov [rax + FO_BTAG], rbx
  mov [rax + FO_BPAY], r12
  mov rdx, rax
  mov eax, T_FN
  EPI
4:
  cmp rbx, T_ARR
  jne 5f
  LEAS rdi, "Arrays have no property '"
  jmp 6f
5:
  LEAS rdi, "Strings have no property '"
6:
  mov rsi, r13
  LEAS rdx, "'"
  call fail_rt_n
  EPI

// C extensions call back into the running Hexo VM using the native value ABI.
.balign 16
hx_raise_error:
  push rbx
  mov rbx, rdi
  call cstr_new
  mov rsi, rax
  LEAS rdi, "Runtime error"
  mov rdx, G(cur_line)
  call raise_err
  ud2
.balign 16
hx_call_callback:
  jmp call_value

// -------------------------------------------------------------- interpreter setup
FN interp_init, 6
  call rt_init
  mov G(access_class), 0
  mov G(module_cache), 0
  mov edi, 16                  // create the first environment chunk
  call env_alloc
  LEAS rdi, "<anonymous>"
  call cstr_new
  mov G(str_anon), rax
  xor edi, edi
  call env_new
  mov G(g_builtins), rax
  mov rdi, rax
  call env_new
  mov G(g_globals), rax
  // stack budget: ~70% of what the OS gave us (so runaway recursion is an error, not a crash)
  mov rax, 1048576
#if defined(OS_WIN)
  mov rax, 2097152
#else
  lea rsi, LA(1)
  mov edi, 3                   // RLIMIT_STACK
  CALLC getrlimit
  test eax, eax
  jnz 3f
  mov rax, L(1)                // rlim_cur
  mov rcx, 268435456
  cmp rax, rcx
  jbe 4f
  mov rax, rcx
4:
  jmp 5f
3:
  mov rax, 1048576
5:
#endif
  xor edx, edx
  mov rcx, 10
  div rcx
  imul rax, rax, 7
  mov G(stack_budget), rax
  // global functions
  lea r12, [rip + globals_table]
6:
  mov rax, [r12]
  test rax, rax
  jz 7f
  lea rcx, [rip + known_ptrs]
  mov rsi, [rcx + rax*8]
  mov rdi, [r12 + 8]
  mov rdx, [r12 + 16]
  mov rcx, [r12 + 24]
  call native_new
  mov rdx, rax
  mov ecx, T_FN
  xchg rdx, rcx
  mov rdi, G(g_builtins)
  lea rax, [rip + known_ptrs]
  mov r8, [r12]
  mov rsi, [rax + r8*8]
  xor r8d, r8d
  mov r9d, EF_CONST
  call env_define
  add r12, 32
  jmp 6b
7:
  mov rdi, G(g_builtins)
  lea rax, [rip + known_ptrs]
  mov rsi, [rax + K_PI*8]
  mov edx, T_FLOAT
  mov rcx, 0x400921FB54442D18
  xor r8d, r8d
  mov r9d, EF_CONST
  call env_define
  mov rdi, G(g_builtins)
  lea rax, [rip + known_ptrs]
  mov rsi, [rax + K_E*8]
  mov edx, T_FLOAT
  mov rcx, 0x4005BF0A8B145769
  xor r8d, r8d
  mov r9d, EF_CONST
  call env_define
  EPI
// ============================================================== FILE / REPL / MAIN
FN print_exception, 4          // prints the pending exception (exc_*) on stderr
  lea rdi, LA(2)
  call sb_init
  cmp G(exc_kind), 0
  jne 1f
  lea rdi, LA(2)
  mov rsi, G(exc_name)
  call sb_putcs
  jmp 2f
1:
  lea rdi, LA(2)
  LEAS rsi, "Runtime error"
  call sb_putcs
2:
  cmp G(exc_line), 0
  jle 3f
  lea rdi, LA(2)
  LEAS rsi, " at line "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, G(exc_line)
  call sb_putint
3:
  lea rdi, LA(2)
  LEAS rsi, ": "
  call sb_putcs
  cmp G(exc_kind), 0
  jne 4f
  lea rdi, LA(2)
  mov rsi, G(exc_pay)
  call sb_putstr
  jmp 5f
4:
  lea rdi, LA(2)
  LEAS rsi, "Uncaught exception: "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, G(exc_tag)
  mov rdx, G(exc_pay)
  xor ecx, ecx
  call repr
5:
  lea rdi, LA(2)
  mov esi, 10
  call sb_putc
  lea rdi, LA(2)
  call sb_finish
  lea rdi, [rax + 16]
  mov rsi, [rax]
  call err_write
  EPI

// lex + parse + run; returns 0 on success, 1 after printing an error
FN run_source, 10              // rdi = source (NUL-terminated), rsi = length, rdx = REPL mode; jmpbuf LA(8)
  mov r12, rdi
  mov r13, rsi
  mov r14, rdx
  lea rdi, LA(8)
  call hx_try
  test eax, eax
  jnz 9f
  mov rdi, r12
  mov rsi, r13
  call lex
  call parse_program
  mov rdi, rax
  mov rsi, r14
  call interpret
  call hx_try_end
  xor eax, eax
  EPI
9:
  mov G(access_class), 0
  call print_exception
  mov eax, 1
  EPI

// true while brackets (or a block comment) are still open: the REPL keeps reading
FN needs_more, 0               // rdi = text, rsi = length -> eax
  mov rbx, rdi
  mov r12, rsi
  xor r13d, r13d               // index
  xor r14d, r14d               // depth
  xor r15d, r15d               // inside /* */
1:
  cmp r13, r12
  jae 9f
  movzx eax, byte ptr [rbx + r13]
  xor ecx, ecx
  lea rdx, [r13 + 1]
  cmp rdx, r12
  jae 2f
  movzx ecx, byte ptr [rbx + rdx]
2:
  test r15d, r15d
  jz 3f
  cmp al, '*'
  jne 31f
  cmp cl, '/'
  jne 31f
  xor r15d, r15d
  inc r13
31:
  inc r13
  jmp 1b
3:
  cmp al, '/'
  jne 5f
  cmp cl, '/'
  jne 4f
41:                             // line comment: skip to the newline
  cmp r13, r12
  jae 9f
  cmp byte ptr [rbx + r13], 10
  je 1b
  inc r13
  jmp 41b
4:
  cmp cl, '*'
  jne 8f
  mov r15d, 1
  add r13, 2
  jmp 1b
5:
  cmp al, '"'
  je 6f
  cmp al, 39
  jne 7f
6:
  mov edx, eax                 // string: skip to the closing quote (or end of line)
  inc r13
61:
  cmp r13, r12
  jae 9f
  movzx eax, byte ptr [rbx + r13]
  cmp eax, edx
  je 8f
  cmp al, 10
  je 8f
  cmp al, '\\'
  jne 62f
  inc r13
62:
  inc r13
  jmp 61b
7:
  cmp al, '{'
  je 71f
  cmp al, '('
  je 71f
  cmp al, '['
  jne 72f
71:
  inc r14
  jmp 8f
72:
  cmp al, '}'
  je 73f
  cmp al, ')'
  je 73f
  cmp al, ']'
  jne 8f
73:
  dec r14
8:
  inc r13
  jmp 1b
9:
  xor eax, eax
  test r15d, r15d
  jnz 10f
  test r14, r14
  jle 11f
10:
  mov eax, 1
11:
  EPI

FN repl, 4                     // line buffer = string builder at LA(2)
  LEAS rdi, "Hexo 0.5.0 (assembly)\nType 'exit' to quit.\n\n"
  call out_puts
  lea rdi, LA(2)
  call sb_init
1:
  LEAS rdi, "hexo> "
  mov esi, 6
  cmp qword ptr LA(2), 0
  je 2f
  LEAS rdi, "  ... "
2:
  call out_put
  call out_flush
  call read_line
  test rax, rax
  jnz 3f
  mov edi, 10
  call out_putc
  jmp 9f
3:
  mov rbx, rax
  cmp qword ptr LA(2), 0
  jne 5f
  lea rdi, [rbx + 16]          // "exit" / "quit" at the start of an entry
  LEAS rsi, "exit"
  CALLC strcmp
  test eax, eax
  jz 9f
  lea rdi, [rbx + 16]
  LEAS rsi, "quit"
  CALLC strcmp
  test eax, eax
  jz 9f
5:
  lea rdi, LA(2)
  mov rsi, rbx
  call sb_putstr
  lea rdi, LA(2)
  mov esi, 10
  call sb_putc
  mov rax, L(0)                // buffer pointer (sb +16); NUL-terminate for the lexer
  add rax, L(2)
  mov byte ptr [rax], 0
  mov rdi, L(0)
  mov rsi, L(2)
  call needs_more
  test eax, eax
  jnz 1b
  mov rdi, L(0)
  mov rsi, L(2)
  mov edx, 1
  call run_source
  mov L(2), 0                  // entry consumed
  jmp 1b
9:
  EPI

FN usage, 0
  LEAS rdi, "Usage: hexo [options] [file.hexo]\n  (no arguments)   start the REPL\n  -h, --help       show this help\n  -v, --version    show the version\n"
  call out_puts
  EPI

// Entry point called by the C runtime. On Windows the arguments arrive in rcx/rdx and
// rdi/rsi are callee-saved there, so a small adapter converts to our convention.
.globl SYM(main)
.balign 16
SYM(main):
#if defined(OS_WIN)
  push rdi
  push rsi
  sub rsp, 8
  mov rdi, rcx
  mov rsi, rdx
  call hexo_main
  add rsp, 8
  pop rsi
  pop rdi
  ret
#else
  jmp hexo_main
#endif

FN hexo_main, 8                // int main(int argc, char** argv)
  mov rbx, rdi
  mov r12, rsi
  call interp_init
  cmp rbx, 1
  jne 1f
  call repl
  call out_flush
  xor eax, eax
  EPI
1:
  mov r13, [r12 + 8]
  mov rdi, r13
  LEAS rsi, "-h"
  CALLC strcmp
  test eax, eax
  jz 2f
  mov rdi, r13
  LEAS rsi, "--help"
  CALLC strcmp
  test eax, eax
  jnz 3f
2:
  call usage
  call out_flush
  xor eax, eax
  EPI
3:
  mov rdi, r13
  LEAS rsi, "-v"
  CALLC strcmp
  test eax, eax
  jz 4f
  mov rdi, r13
  LEAS rsi, "--version"
  CALLC strcmp
  test eax, eax
  jnz 5f
4:
  LEAS rdi, "Hexo 0.5.0 (assembly)\n"
  call out_puts
  call out_flush
  xor eax, eax
  EPI
5:
  cmp rbx, 2
  je 6f
  call usage
  call out_flush
  mov eax, 1
  EPI
6:
  mov rdi, r13                 // read the whole file
  LEAS rsi, "rb"
  CALLC fopen
  test rax, rax
  jnz 7f
  lea rdi, LA(2)
  call sb_init
  lea rdi, LA(2)
  LEAS rsi, "Cannot open file: "
  call sb_putcs
  lea rdi, LA(2)
  mov rsi, r13
  call sb_putcs
  lea rdi, LA(2)
  mov esi, 10
  call sb_putc
  lea rdi, LA(2)
  call sb_finish
  lea rdi, [rax + 16]
  mov rsi, [rax]
  call err_write
  mov eax, 1
  EPI
7:
  mov r14, rax                 // FILE*
  mov rdi, r14
  xor esi, esi
  mov edx, 2                   // SEEK_END
  CALLC fseek
  mov rdi, r14
  CALLC ftell
#if defined(OS_WIN)
  movsxd rax, eax
#endif
  mov r15, rax                 // size
  mov rdi, r14
  xor esi, esi
  xor edx, edx                 // SEEK_SET
  CALLC fseek
  lea rdi, [r15 + 1]
  call hx_alloc
  mov L(0), rax
  mov rdi, rax
  mov esi, 1
  mov rdx, r15
  mov rcx, r14
  CALLC fread
  mov rdi, r14
  CALLC fclose
  mov rdi, L(0)
  mov rsi, r15
  xor edx, edx
  call run_source
  mov r12, rax
  call out_flush
  mov rax, r12
  EPI

#if defined(OS_LINUX)
.section .note.GNU-stack,"",@progbits
#endif
