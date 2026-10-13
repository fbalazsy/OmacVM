/*
 * Copyright (c) 2005-2021 Apple Inc. All rights reserved.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. The rights granted to you under the License
 * may not be used to create, or enable the creation or redistribution of,
 * unlawful or unlicensed copies of an Apple operating system, or to
 * circumvent, violate, or enable the circumvention or violation of, any
 * terms of an Apple operating system software license agreement.
 *
 * Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_OSREFERENCE_LICENSE_HEADER_END@
 */
/* Modified 2026-10-13: extracted ABI declaration and flavor; compact layout,
 * local include guard and size assertion. Covered portions remain APSL-2.0. */
#pragma once
/* Darwin SPI missing from public SDK. Layout/flavor copied as a declaration
   from Apple's xnu-12377.1.9/bsd/sys/proc_info_private.h (APSL 2.0).
   https://github.com/apple-oss-distributions/xnu/blob/xnu-12377.1.9/bsd/sys/proc_info_private.h
   No fallback: proc_pidinfo must return exactly 56 bytes. Test on own PID only.
   SPI compatibility is an explicit deployment gate on future macOS versions. */
#include <stdint.h>
#define PROC_PIDUNIQIDENTIFIERINFO 17
struct proc_uniqidentifierinfo {
 uint8_t p_uuid[16];uint64_t p_uniqueid,p_puniqueid;
 int32_t p_idversion,p_orig_ppidversion;uint64_t p_reserve2,p_reserve3;
};
_Static_assert(sizeof(struct proc_uniqidentifierinfo)==56,"Darwin unique identifier ABI");
