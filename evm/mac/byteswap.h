// EVMC Wrapper
// Copyright 2021-2024 Diode
// Licensed under the GNU General Public License, Version 3.
#ifndef MAC_BYTESWAP_H_
#define MAC_BYTESWAP_H_

#ifdef __APPLE__
#include <libkern/OSByteOrder.h>

#define __bswap_16 OSSwapInt16
#define __bswap_32 OSSwapInt32
#define __bswap_64 OSSwapInt64

#endif
#endif