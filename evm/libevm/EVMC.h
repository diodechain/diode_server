// Aleth: Ethereum C++ client, tools and libraries.
// Copyright 2014-2019 Aleth Authors.
// Licensed under the GNU General Public License, Version 3.

#pragma once

#include <libevm/VMFace.h>

namespace dev
{
namespace eth
{
/// The wrapper implementing the VMFace interface with a EVMC VM as a backend.
class EVMC : public evmc::VM, public VMFace
{
public:
    explicit EVMC(evmc_vm* _vm) noexcept;

    owning_bytes_ref exec(u256& io_gas, ExtVMFace& _ext, OnOpFunc const& _onOp) final;
};
}  // namespace eth
}  // namespace dev
