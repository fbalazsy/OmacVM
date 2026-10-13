/* Directly exercise the production Darwin ACL predicate on an owned fixture. */
#include "../security.c"
#include <assert.h>
#include <membership.h>
#include <stdlib.h>
#include <stdio.h>
int main(void){char path[1024];snprintf(path,sizeof(path),"%s/acl-XXXXXX",getenv("TMPDIR"));int fd=mkstemp(path);assert(fd>=0);assert(acl_safe(fd));
 acl_t acl=acl_init(1);acl_entry_t entry;assert(acl && !acl_create_entry(&acl,&entry));assert(!acl_set_tag_type(entry,ACL_EXTENDED_ALLOW));uuid_t uuid;assert(!mbr_uid_to_uuid(getuid(),uuid));assert(!acl_set_qualifier(entry,uuid));acl_permset_t perms;assert(!acl_get_permset(entry,&perms));assert(!acl_add_perm(perms,ACL_WRITE_DATA));assert(!acl_set_permset(entry,perms));assert(!acl_set_fd_np(fd,acl,ACL_TYPE_EXTENDED));
 int accepted=acl_safe(fd);acl_free(acl);close(fd);assert(!unlink(path));assert(!accepted);puts("ACL PASS: actual Darwin extended allow ACL is refused");return 0;}
