# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
import binascii
import os
import time
from collections import defaultdict
from datetime import datetime
from fabric.api import env, run, cd, put, get, abort, hide, local, lcd, prefix, hosts, sudo
from fabric.contrib.files import exists


env.diode="/opt/diode"

# Install on Ubuntu 18.04
def install():
  #with lcd("~"):
    #put(".inputrc", "~")

  # Elixir + Base System
  if not exists("~/.asdf/asdf.sh"):
    run("apt update")
    run("apt upgrade -y")
    run("apt install -y libncurses-dev screen git snap g++ make unzip autoconf libtool libgmp-dev daemontools libboost-system-dev libsqlite3-dev")
    run("apt autoremove")

    run("git clone https://github.com/asdf-vm/asdf.git ~/.asdf")
    run("echo '. ~/.asdf/asdf.sh' >> ~/.bashrc")
    run(". ~/.asdf/asdf.sh && asdf plugin add erlang")
    run(". ~/.asdf/asdf.sh && asdf plugin add elixir")

  # Application
  run("mkdir -p {}".format(env.diode))
  with cd(env.diode):
    run("git init")
    run("git config receive.denyCurrentBranch ignore")
    local("git push -f ssh://{user}@{host}{path} master".format(user=env.user, host=env.host, path=env.diode))
    run("git checkout master")
    #run("echo 'elixir 1.14' > .tool-versions")
    #run("echo 'erlang 24.0.4' >> .tool-versions")
    #run("export KERL_CONFIGURE_OPTIONS=--without-wx && . ~/.asdf/asdf.sh && asdf install")
    run("cp githooks/post-receive .git/hooks/")
    run("cp deployment/diode.service /etc/systemd/system/diode.service")
    run("HOME=`pwd` mix local.hex --force")
    run("HOME=`pwd` mix local.rebar --force")
    run("systemctl daemon-reload")
    run("systemctl enable diode")

    # Cleaning
    run("systemctl stop diode")
    if exists("./states"):
      run("find ./states -maxdepth 1 -type f -delete")
    if exists("./data"):
      run("find ./data -maxdepth 1 -type f -delete")

    # Starting
    run("systemctl start diode")

def setkey(key):
  if key.startswith('0x'):
    key = key[2:]
  key = bytearray.fromhex(key)
  if len(key) != 32:
    print("Key too short")
    return 1

  key = '0x' + binascii.hexlify(key)

  with cd(env.diode):
    run("cp deployment/diode.service /etc/systemd/system/diode.service")
    run("sed -ie 's/PRIVATE=0/PRIVATE={}/g' /etc/systemd/system/diode.service".format(key))
    run("systemctl daemon-reload")
    run("systemctl stop diode")
    run("systemctl start diode")
