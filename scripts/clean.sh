#!/bin/bash
# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
find ./clones/* ./data_*/blockchain.sq3* ./data_*/cache.sq3 -maxdepth 1 -type f -delete
make clean
