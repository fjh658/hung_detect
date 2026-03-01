// hung_bench.c — AOP profiling dylib for hung_detect
// Usage: DYLD_INSERT_LIBRARIES=bench/libhung_bench.dylib ./hung_detect --all --json
//
// Hooks C and Swift functions used by hung_detect and prints per-call
// and aggregate timing to stderr. Hook targets are read from a config file
// (bench/bench.conf by default, override with HUNG_BENCH_CONF env var).
//
// Config format (one entry per line, # for comments):
//   sysctl                      — C symbol (resolved via dlsym)
//   sleepPreventingPIDs         — Swift function (matched by demangled name)
//
// C symbols are resolved via dlsym(RTLD_DEFAULT, ...).
// Swift symbols are found by scanning the binary's symbol table, demangling
// each entry, and matching against the config name.
// Typed C hooks use signature-matched wrappers; Swift hooks use generic
// assembly trampolines that preserve all registers.
//
// NOTE: the target binary must NOT be stripped (local symbols required).
// Build with: make build  (SwiftPM release preserves local symbols)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <libproc.h>
#include <sys/sysctl.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <Security/Security.h>
#include "tinyhook.h"

// ---------- timing helpers ----------

static mach_timebase_info_data_t g_tb;
static uint64_t g_wall_start;

#define LAYER_C     0
#define LAYER_SWIFT 1

typedef struct {
    const char *name;
    _Atomic uint64_t total_ns;
    _Atomic uint32_t count;
    int layer;
} hook_stat_t;

#define MAX_HOOKS 32
static hook_stat_t g_stats[MAX_HOOKS];
static int g_nstats = 0;  // only modified during init (single-threaded)

// Pre-register a stat entry during init (single-threaded)
static hook_stat_t *register_stat(const char *name, int layer) {
    if (g_nstats >= MAX_HOOKS) return NULL;
    hook_stat_t *s = &g_stats[g_nstats++];
    s->name = name;
    atomic_store(&s->total_ns, 0);
    atomic_store(&s->count, 0);
    s->layer = layer;
    return s;
}

// Lookup stat by name (thread-safe: read-only after init)
static hook_stat_t *find_stat(const char *name) {
    for (int i = 0; i < g_nstats; i++) {
        if (strcmp(g_stats[i].name, name) == 0) return &g_stats[i];
    }
    return NULL;
}

static inline uint64_t ticks_to_ns(uint64_t ticks) {
    // Use __uint128_t to avoid overflow on large tick values
    __uint128_t wide = (__uint128_t)ticks * g_tb.numer;
    return (uint64_t)(wide / g_tb.denom);
}

static void record(const char *name, uint64_t start, uint64_t end) {
    hook_stat_t *s = find_stat(name);
    if (!s) return;
    uint64_t delta = ticks_to_ns(end - start);
    atomic_fetch_add(&s->total_ns, delta);
    atomic_fetch_add(&s->count, 1);
}

// ---------- generic trampoline support ----------
// Assembly trampolines (trampoline.S) call these C functions and
// read originals from generic_hook_originals[].

#define MAX_GENERIC_HOOKS 16

// Original function pointers, written by tiny_hook(), read by assembly
void *generic_hook_originals[MAX_GENERIC_HOOKS];

// Stats for generic hooks (pointers into g_stats[], set during init)
static hook_stat_t *g_generic_stat_ptrs[MAX_GENERIC_HOOKS];
static int g_ngeneric = 0;

// Called from assembly: record start time
uint64_t generic_hook_enter(int slot) {
    (void)slot;
    return mach_absolute_time();
}

// Called from assembly: record elapsed time
void generic_hook_exit(int slot, uint64_t start_time) {
    if (slot < 0 || slot >= g_ngeneric) return;
    uint64_t end = mach_absolute_time();
    hook_stat_t *s = g_generic_stat_ptrs[slot];
    if (!s) return;
    uint64_t delta = ticks_to_ns(end - start_time);
    atomic_fetch_add(&s->total_ns, delta);
    atomic_fetch_add(&s->count, 1);
}

// Trampoline stubs defined in trampoline.S
extern void generic_trampoline_0(void);
extern void generic_trampoline_1(void);
extern void generic_trampoline_2(void);
extern void generic_trampoline_3(void);
extern void generic_trampoline_4(void);
extern void generic_trampoline_5(void);
extern void generic_trampoline_6(void);
extern void generic_trampoline_7(void);
extern void generic_trampoline_8(void);
extern void generic_trampoline_9(void);
extern void generic_trampoline_10(void);
extern void generic_trampoline_11(void);
extern void generic_trampoline_12(void);
extern void generic_trampoline_13(void);
extern void generic_trampoline_14(void);
extern void generic_trampoline_15(void);

typedef void (*trampoline_fn)(void);
static const trampoline_fn g_trampolines[MAX_GENERIC_HOOKS] = {
    generic_trampoline_0,  generic_trampoline_1,
    generic_trampoline_2,  generic_trampoline_3,
    generic_trampoline_4,  generic_trampoline_5,
    generic_trampoline_6,  generic_trampoline_7,
    generic_trampoline_8,  generic_trampoline_9,
    generic_trampoline_10, generic_trampoline_11,
    generic_trampoline_12, generic_trampoline_13,
    generic_trampoline_14, generic_trampoline_15,
};

// ---------- typed C hook implementations ----------

static IOReturn (*orig_IOPMCopyAssertionsByProcess)(CFDictionaryRef *);
static CFArrayRef (*orig_CGWindowListCopyWindowInfo)(uint32_t, uint32_t);
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*orig_proc_pidpath)(int, void *, uint32_t);
static OSStatus (*orig_SecStaticCodeCreateWithPath)(CFURLRef, uint32_t, SecStaticCodeRef *);
static OSStatus (*orig_SecCodeCopySigningInformation)(SecStaticCodeRef, uint32_t, CFDictionaryRef *);
static CFStringRef (*orig_SecCertificateCopySubjectSummary)(SecCertificateRef);
static int (*orig_sandbox_check)(pid_t, const char *, int);

static IOReturn hook_IOPMCopyAssertionsByProcess(CFDictionaryRef *dict) {
    uint64_t t0 = mach_absolute_time();
    IOReturn r = orig_IOPMCopyAssertionsByProcess(dict);
    record("IOPMCopyAssertionsByProcess", t0, mach_absolute_time());
    return r;
}

static CFArrayRef hook_CGWindowListCopyWindowInfo(uint32_t opt, uint32_t wid) {
    uint64_t t0 = mach_absolute_time();
    CFArrayRef r = orig_CGWindowListCopyWindowInfo(opt, wid);
    record("CGWindowListCopyWindowInfo", t0, mach_absolute_time());
    return r;
}

static int hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    uint64_t t0 = mach_absolute_time();
    int r = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    record("sysctl", t0, mach_absolute_time());
    return r;
}

static int hook_proc_pidpath(int pid, void *buf, uint32_t bufsize) {
    uint64_t t0 = mach_absolute_time();
    int r = orig_proc_pidpath(pid, buf, bufsize);
    record("proc_pidpath", t0, mach_absolute_time());
    return r;
}

static OSStatus hook_SecStaticCodeCreateWithPath(CFURLRef path, uint32_t flags, SecStaticCodeRef *code) {
    uint64_t t0 = mach_absolute_time();
    OSStatus r = orig_SecStaticCodeCreateWithPath(path, flags, code);
    record("SecStaticCodeCreateWithPath", t0, mach_absolute_time());
    return r;
}

static OSStatus hook_SecCodeCopySigningInformation(SecStaticCodeRef code, uint32_t flags, CFDictionaryRef *info) {
    uint64_t t0 = mach_absolute_time();
    OSStatus r = orig_SecCodeCopySigningInformation(code, flags, info);
    record("SecCodeCopySigningInformation", t0, mach_absolute_time());
    return r;
}

static CFStringRef hook_SecCertificateCopySubjectSummary(SecCertificateRef cert) {
    uint64_t t0 = mach_absolute_time();
    CFStringRef r = orig_SecCertificateCopySubjectSummary(cert);
    record("SecCertificateCopySubjectSummary", t0, mach_absolute_time());
    return r;
}

static int hook_sandbox_check(pid_t pid, const char *op, int type) {
    uint64_t t0 = mach_absolute_time();
    int r = orig_sandbox_check(pid, op, type);
    record("sandbox_check", t0, mach_absolute_time());
    return r;
}

// ---------- typed hook registry ----------

typedef struct {
    const char *symbol;
    void *hook;
    void **orig;
} hook_entry_t;

static const hook_entry_t g_registry[] = {
    {"IOPMCopyAssertionsByProcess",     (void *)hook_IOPMCopyAssertionsByProcess,     (void **)&orig_IOPMCopyAssertionsByProcess},
    {"CGWindowListCopyWindowInfo",      (void *)hook_CGWindowListCopyWindowInfo,      (void **)&orig_CGWindowListCopyWindowInfo},
    {"sysctl",                          (void *)hook_sysctl,                          (void **)&orig_sysctl},
    {"proc_pidpath",                    (void *)hook_proc_pidpath,                    (void **)&orig_proc_pidpath},
    {"SecStaticCodeCreateWithPath",     (void *)hook_SecStaticCodeCreateWithPath,     (void **)&orig_SecStaticCodeCreateWithPath},
    {"SecCodeCopySigningInformation",   (void *)hook_SecCodeCopySigningInformation,   (void **)&orig_SecCodeCopySigningInformation},
    {"SecCertificateCopySubjectSummary",(void *)hook_SecCertificateCopySubjectSummary,(void **)&orig_SecCertificateCopySubjectSummary},
    {"sandbox_check",                   (void *)hook_sandbox_check,                   (void **)&orig_sandbox_check},
    {NULL, NULL, NULL}
};

// ---------- Swift demangling ----------

typedef char *(*swift_demangle_fn)(const char *, size_t, char *, size_t *, uint32_t);
static swift_demangle_fn g_swift_demangle;

static void init_demangler(void) {
    g_swift_demangle = (swift_demangle_fn)dlsym(RTLD_DEFAULT, "swift_demangle");
}

// Returns malloc'd string, caller must free. NULL if not a Swift symbol.
static char *demangle_swift(const char *mangled) {
    if (!g_swift_demangle) return NULL;
    return g_swift_demangle(mangled, strlen(mangled), NULL, NULL, 0);
}

// Extract "ClassName.methodName" from a full demangled Swift name.
// Input:  "function signature specialization <...> of static hung_detect.
//          (ProcessInspector in _E4A961...).sleepPreventingPIDs() -> ..."
// Output: "ProcessInspector.sleepPreventingPIDs"
static char *short_demangled_name(const char *demangled, const char *func_name) {
    size_t flen = strlen(func_name);
    char needle[256];
    snprintf(needle, sizeof(needle), ".%s(", func_name);
    const char *fn_pos = strstr(demangled, needle);
    if (!fn_pos) {
        snprintf(needle, sizeof(needle), ".%s ", func_name);
        fn_pos = strstr(demangled, needle);
    }
    if (!fn_pos) return strdup(func_name);

    // Look backward from the dot for "(ClassName in "
    const char *paren = NULL;
    for (const char *p = fn_pos - 1; p >= demangled; p--) {
        if (*p == '(') { paren = p; break; }
    }
    if (paren) {
        const char *class_start = paren + 1;
        const char *in_pos = strstr(class_start, " in ");
        if (in_pos && in_pos < fn_pos) {
            size_t class_len = (size_t)(in_pos - class_start);
            char *result = malloc(class_len + 1 + flen + 1);
            if (!result) return strdup(func_name);
            memcpy(result, class_start, class_len);
            result[class_len] = '.';
            memcpy(result + class_len + 1, func_name, flen);
            result[class_len + 1 + flen] = '\0';
            return result;
        }
    }
    return strdup(func_name);
}

// ---------- symbol table scanning ----------

// Find image index for the main executable. Returns -1 on failure.
static int32_t find_main_image(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const char *slash = strrchr(name, '/');
        const char *base = slash ? slash + 1 : name;
        if (strcmp(base, "hung_detect") == 0) return (int32_t)i;
    }
    return -1;
}

// Check if demangled name matches func_name (word boundary match)
static int is_func_match(const char *demangled, const char *func_name) {
    if (strstr(demangled, "partial apply forwarder"))  return 0;
    if (strstr(demangled, "protocol witness"))         return 0;

    char pattern[256];

    snprintf(pattern, sizeof(pattern), ".%s(", func_name);
    if (strstr(demangled, pattern)) return 1;

    snprintf(pattern, sizeof(pattern), ".%s<", func_name);
    if (strstr(demangled, pattern)) return 1;

    return 0;
}

typedef struct {
    void *addr;
    char *demangled;
    char *display;
} swift_match_t;

// Scan symbol table of image, find Swift function matching func_name.
// Prefers non-closure matches over closure matches.
static swift_match_t find_swift_symbol(uint32_t image_idx, const char *func_name) {
    swift_match_t result = {NULL, NULL, NULL};

    const struct mach_header_64 *header =
        (const struct mach_header_64 *)_dyld_get_image_header(image_idx);
    if (!header || header->magic != MH_MAGIC_64) return result;

    intptr_t slide = _dyld_get_image_vmaddr_slide(image_idx);

    const struct symtab_command *symtab_cmd = NULL;
    uintptr_t linkedit_base = 0;

    const uint8_t *lc = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *cmd = (const struct load_command *)lc;
        if (cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)lc;
        } else if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkedit_base = (uintptr_t)(slide + seg->vmaddr - seg->fileoff);
            }
        }
        lc += cmd->cmdsize;
    }

    if (!symtab_cmd || !linkedit_base) return result;

    const struct nlist_64 *syms =
        (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);

    swift_match_t best_non_closure = {NULL, NULL, NULL};
    swift_match_t best_closure = {NULL, NULL, NULL};

    for (uint32_t i = 0; i < symtab_cmd->nsyms; i++) {
        if ((syms[i].n_type & N_TYPE) != N_SECT) continue;

        const char *sym_name = strtab + syms[i].n_un.n_strx;
        if (strncmp(sym_name, "_$s", 3) != 0) continue;

        char *demangled = demangle_swift(sym_name + 1);
        if (!demangled) continue;

        if (!is_func_match(demangled, func_name)) {
            free(demangled);
            continue;
        }

        void *addr = (void *)((uintptr_t)syms[i].n_value + slide);
        int is_closure = (strstr(demangled, "closure #") != NULL);

        if (!is_closure && !best_non_closure.addr) {
            best_non_closure.addr = addr;
            best_non_closure.demangled = demangled;
            best_non_closure.display = short_demangled_name(demangled, func_name);
        } else if (is_closure && !best_closure.addr) {
            best_closure.addr = addr;
            best_closure.demangled = demangled;
            best_closure.display = short_demangled_name(demangled, func_name);
        } else {
            free(demangled);
        }

        if (best_non_closure.addr) break;
    }

    if (best_non_closure.addr) {
        free(best_closure.demangled);
        free(best_closure.display);
        return best_non_closure;
    }
    return best_closure;
}

// ---------- config parsing ----------

#define MAX_CONFIG 32

static int parse_config(const char *path, char names[][128], int max) {
    int n = 0;
    FILE *f = fopen(path, "r");
    if (!f) return 0;

    char line[256];
    while (fgets(line, sizeof(line), f) && n < max) {
        char *nl = strchr(line, '\n');
        if (!nl && !feof(f)) {
            // Line too long — skip remainder
            int ch;
            while ((ch = fgetc(f)) != EOF && ch != '\n') {}
        }
        if (nl) *nl = '\0';
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '#') continue;
        char *end = p + strlen(p) - 1;
        while (end > p && (*end == ' ' || *end == '\t')) *end-- = '\0';
        strncpy(names[n], p, 127);
        names[n][127] = '\0';
        n++;
    }
    fclose(f);
    return n;
}

// ---------- output ----------

static void print_layer_header(const char *title) {
    fprintf(stderr, "\n[hung_bench] ── %s ", title);
    // pad with ─ to fill width
    int used = (int)strlen(title) + 4;
    for (int i = used; i < 60; i++) fprintf(stderr, "─");
    fprintf(stderr, "\n");
    fprintf(stderr, "[hung_bench] %-40s %8s %10s %10s\n",
            "function", "calls", "total(ms)", "avg(us)");
}

static void print_layer_stats(int layer) {
    for (int i = 0; i < g_nstats; i++) {
        hook_stat_t *s = &g_stats[i];
        if (s->layer != layer) continue;
        uint32_t cnt = atomic_load(&s->count);
        if (cnt == 0) continue;
        uint64_t ns = atomic_load(&s->total_ns);
        double total_ms = ns / 1e6;
        double avg_us = (ns / 1e3) / cnt;
        fprintf(stderr, "[hung_bench] %-40s %8u %10.1f %10.1f\n",
                s->name, cnt, total_ms, avg_us);
    }
}

// ---------- lifecycle ----------

__attribute__((constructor))
static void hung_bench_init(void) {
    mach_timebase_info(&g_tb);
    init_demangler();

    const char *conf = getenv("HUNG_BENCH_CONF");
    if (!conf) conf = "bench/bench.conf";

    char config[MAX_CONFIG][128];
    int nconfig = parse_config(conf, config, MAX_CONFIG);

    if (nconfig == 0) {
        fprintf(stderr, "[hung_bench] WARNING: no hooks configured (conf: %s)\n", conf);
        return;
    }

    // Preload frameworks so C symbols are available via dlsym
    static const char *frameworks[] = {
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
        "/System/Library/Frameworks/Security.framework/Security",
        "/usr/lib/system/libsystem_sandbox.dylib",
        "/usr/lib/system/libsystem_c.dylib",
        NULL
    };
    for (const char **fw = frameworks; *fw; fw++) {
        dlopen(*fw, RTLD_NOW | RTLD_GLOBAL);
    }

    int32_t main_image = find_main_image();
    if (main_image < 0) {
        fprintf(stderr, "[hung_bench] WARNING: could not locate hung_detect image — Swift hooks disabled\n");
    }

    int installed = 0;
    int not_found = 0;

    for (int ci = 0; ci < nconfig; ci++) {
        const char *name = config[ci];

        // 1. Try typed hook registry (C symbols via dlsym)
        int used_typed = 0;
        for (const hook_entry_t *e = g_registry; e->symbol; e++) {
            if (strcmp(e->symbol, name) == 0) {
                void *addr = dlsym(RTLD_DEFAULT, name);
                if (addr && tiny_hook(addr, e->hook, e->orig) == 0) {
                    if (!register_stat(e->symbol, LAYER_C)) {
                        fprintf(stderr, "[hung_bench] WARNING: stat slots full, skip: %s\n", name);
                    } else {
                        installed++;
                    }
                } else {
                    fprintf(stderr, "[hung_bench] hook failed: %s\n", name);
                }
                used_typed = 1;
                break;
            }
        }
        if (used_typed) continue;

        // 2. Try dlsym for non-registry C symbols → generic trampoline
        void *addr = dlsym(RTLD_DEFAULT, name);
        if (addr) {
            if (g_ngeneric >= MAX_GENERIC_HOOKS) {
                fprintf(stderr, "[hung_bench] WARNING: generic slots full, skip: %s\n", name);
                continue;
            }
            int slot = g_ngeneric;
            if (tiny_hook(addr, (void *)g_trampolines[slot], &generic_hook_originals[slot]) == 0) {
                char *dup = strdup(name);
                hook_stat_t *st = dup ? register_stat(dup, LAYER_C) : NULL;
                if (!st) {
                    free(dup);
                    fprintf(stderr, "[hung_bench] WARNING: stat slots full, skip: %s\n", name);
                } else {
                    g_generic_stat_ptrs[slot] = st;
                    g_ngeneric++;
                    installed++;
                }
            } else {
                fprintf(stderr, "[hung_bench] hook failed: %s\n", name);
            }
            continue;
        }

        // 3. Scan symbol table for Swift function match
        swift_match_t m = (main_image >= 0) ? find_swift_symbol((uint32_t)main_image, name)
                                            : (swift_match_t){NULL, NULL, NULL};
        if (m.addr) {
            if (g_ngeneric >= MAX_GENERIC_HOOKS) {
                fprintf(stderr, "[hung_bench] WARNING: generic slots full, skip: %s\n", name);
                free(m.demangled); free(m.display);
                continue;
            }
            int slot = g_ngeneric;
            if (tiny_hook(m.addr, (void *)g_trampolines[slot], &generic_hook_originals[slot]) == 0) {
                hook_stat_t *st = register_stat(m.display, LAYER_SWIFT);
                if (!st) {
                    fprintf(stderr, "[hung_bench] WARNING: stat slots full, skip: %s\n", m.display);
                    free(m.display);
                } else {
                    g_generic_stat_ptrs[slot] = st;
                    g_ngeneric++;
                    installed++;
                    fprintf(stderr, "[hung_bench] swift hook: %s\n", m.display);
                    fprintf(stderr, "[hung_bench]   %s\n", m.demangled);
                }
            } else {
                fprintf(stderr, "[hung_bench] hook failed: %s\n", m.display);
                free(m.display);
            }
            free(m.demangled);
            continue;
        }

        // 4. Not found
        fprintf(stderr, "[hung_bench] WARNING: not found: %s\n", name);
        not_found++;
    }

    fprintf(stderr, "[hung_bench] %d hooks installed (conf: %s)\n", installed, conf);
    if (not_found > 0) {
        fprintf(stderr, "[hung_bench] WARNING: %d symbols not found — is the binary stripped?\n", not_found);
        fprintf(stderr, "[hung_bench]   hint: ensure 'nm hung_detect | grep <name>' shows matches\n");
    }

    g_wall_start = mach_absolute_time();
}

__attribute__((destructor))
static void hung_bench_fini(void) {
    uint64_t wall_ns = ticks_to_ns(mach_absolute_time() - g_wall_start);

    if (g_nstats == 0) return;

    // Check which layers have data
    int has_c = 0, has_swift = 0;
    for (int i = 0; i < g_nstats; i++) {
        if (atomic_load(&g_stats[i].count) == 0) continue;
        if (g_stats[i].layer == LAYER_C)     has_c = 1;
        if (g_stats[i].layer == LAYER_SWIFT) has_swift = 1;
    }

    if (has_swift && has_c) {
        // Two-layer output: separate Swift and C to show nesting
        print_layer_header("Swift (application)");
        print_layer_stats(LAYER_SWIFT);
        print_layer_header("C (system, nested in Swift)");
        print_layer_stats(LAYER_C);
    } else {
        // Single layer: flat output
        fprintf(stderr, "\n[hung_bench] %-40s %8s %10s %10s\n",
                "function", "calls", "total(ms)", "avg(us)");
        fprintf(stderr, "[hung_bench] %-40s %8s %10s %10s\n",
                "---", "---", "---", "---");
        print_layer_stats(has_swift ? LAYER_SWIFT : LAYER_C);
    }

    fprintf(stderr, "\n[hung_bench] wall clock: %.1f ms\n", wall_ns / 1e6);
}
