/* Same CF plist graph as PolicyCorpus.swift; no native API calls. */
#include "scope-registry-shim.h"
/* Admission-only corpus: report I/O is forbidden, including the sync API. */
static IOReturn policy_set_report(IOHIDDeviceRef d, IOHIDReportType t, CFIndex id,
                                 const uint8_t *data, CFIndex len)
{ g_assert_not_reached(); }
static IOReturn policy_get_report(IOHIDDeviceRef d, IOHIDReportType t, CFIndex id,
                                 uint8_t *data, CFIndex *len)
{ g_assert_not_reached(); }
#define IOHIDDeviceSetReport policy_set_report
#define IOHIDDeviceGetReport policy_get_report
static CFDictionaryRef policy_case;
static CFArrayRef policy_nodes;
static CFTypeRef field(CFDictionaryRef d, const char *key)
{
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = CFDictionaryGetValue(d, k);
    CFRelease(k);
    return v;
}
static int integer(CFTypeRef v)
{
    int n = 0;
    g_assert_true(CFNumberGetValue(v, kCFNumberIntType, &n));
    return n;
}
static char *text(CFTypeRef v)
{
    char b[1024];
    g_assert_true(CFStringGetCString(v, b, sizeof(b), kCFStringEncodingUTF8));
    return g_strdup(b);
}
static void policy_load(void)
{
    gchar *bytes = NULL; gsize size;
    g_assert_true(g_file_get_contents(getenv("POLICY_CORPUS"), &bytes, &size, NULL));
    CFDataRef data = CFDataCreate(NULL, (uint8_t *)bytes, size);
    CFArrayRef corpus = CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data); g_free(bytes); g_assert_nonnull(corpus);
    for (CFIndex i = 0; i < CFArrayGetCount(corpus); i++) {
        CFDictionaryRef c = CFArrayGetValueAtIndex(corpus, i);
        g_autofree char *name = text(field(c, "name"));
        if (!strcmp(name, getenv("REVIEW_CASE"))) { policy_case = c; break; }
    }
    g_assert_nonnull(policy_case);
    policy_nodes = field(policy_case, "nodes");
    scope_count = CFArrayGetCount(policy_nodes);
    g_assert_cmpuint(scope_count, <, 80);
    for (unsigned i = 1; i <= scope_count; i++) {
        CFDictionaryRef n = CFArrayGetValueAtIndex(policy_nodes, i - 1);
        scope_nodes[i].cls = text(field(n, "cls"));
        scope_nodes[i].parent = integer(field(n, "parent"));
        scope_nodes[i].props = CFDictionaryCreateMutableCopy(NULL, 0, field(n, "props"));
    }
}
static boolean_t policy_conforms(io_object_t e, const io_name_t name)
{
    if (!strcmp(scope_nodes[e].cls, name)) { return true; }
    CFArrayRef a = field(CFArrayGetValueAtIndex(policy_nodes, e - 1), "conforms");
    for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
        g_autofree char *s = text(CFArrayGetValueAtIndex(a, i));
        if (!strcmp(s, name)) { return true; }
    }
    return false;
}
static CFTypeRef policy_prop(io_registry_entry_t e, CFStringRef key, CFAllocatorRef a, IOOptionBits o)
{
    scope_reads++;
    CFTypeRef v = CFDictionaryGetValue(scope_nodes[e].props, key);
    return v ? CFRetain(v) : NULL;
}
static kern_return_t policy_props(io_registry_entry_t e, CFMutableDictionaryRef *p, CFAllocatorRef a, IOOptionBits o)
{
    scope_reads++;
    *p = CFDictionaryCreateMutableCopy(NULL, 0, scope_nodes[e].props);
    return KERN_SUCCESS;
}
static void overlay(const void *key, const void *v, void *d) { CFDictionarySetValue(d, key, v); }
static IOHIDDeviceRef policy_create(CFAllocatorRef a, io_service_t e)
{
    scope_created++; scope_create_reads = scope_reads;
    CFMutableDictionaryRef d = CFDictionaryCreateMutableCopy(NULL, 0, scope_nodes[e].props);
    CFDictionaryRef changes = field(policy_case, "final");
    if (changes) { CFDictionaryApplyFunction(changes, overlay, d); }
    return (IOHIDDeviceRef)d;
}
#undef IOObjectConformsTo
#undef IORegistryEntryCreateCFProperty
#undef IORegistryEntryCreateCFProperties
#undef IOHIDDeviceCreate
#define IOObjectConformsTo policy_conforms
#define IORegistryEntryCreateCFProperty policy_prop
#define IORegistryEntryCreateCFProperties policy_props
#define IOHIDDeviceCreate policy_create
