# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
import binascii
from fabric.api import env, run, prefix, cd, local, parallel
from fabric.contrib.files import exists, append

env.gateway="root@eu1.prenet.diode.io"
env.diode="/opt/diode"
if env.hosts == []:
  env.hosts = [
    "root@eu1.prenet.diode.io", "root@eu2.prenet.diode.io",
    "root@us1.prenet.diode.io", "root@us2.prenet.diode.io",
    "root@as1.prenet.diode.io", "root@as2.prenet.diode.io",
  ]

# Install on Ubuntu 18.04
# @parallel
def install_system_base():
  update()
  with prefix("export DEBIAN_FRONTEND=noninteractive"):
    run("apt install -y libncurses-dev screen git snap g++ make unzip autoconf libtool libgmp-dev daemontools libboost-system-dev libsqlite3-dev libssl-dev unattended-upgrades debconf-utils")
    run("echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections -v")
    run("dpkg-reconfigure --priority=low unattended-upgrades")  
    run("apt autoremove -y")

@parallel
def install_base():
  install_system_base()
  install_erlang()

@parallel
def update():
  with prefix("export DEBIAN_FRONTEND=noninteractive"):
    run("apt update")
    run("apt upgrade -y")

@parallel
def install_erlang():
  if not exists("~/.asdf/asdf.sh"):
    run("git clone https://github.com/asdf-vm/asdf.git ~/.asdf")
    run("echo '. ~/.asdf/asdf.sh' >> ~/.bashrc")
    run(". ~/.asdf/asdf.sh && asdf plugin add erlang")
    run(". ~/.asdf/asdf.sh && asdf plugin add elixir")

  run(". ~/.asdf/asdf.sh && asdf install elixir 1.15.7")
  run(". ~/.asdf/asdf.sh && asdf install erlang 26.2.5.3")

def install():
  if not exists("~/.asdf/asdf.sh"):
    install_base()

  # Application
  run("mkdir -p {}".format(env.diode))
  with cd(env.diode):
    run("git init")
    run("git config receive.denyCurrentBranch ignore")
    local("git push -f ssh://{user}@{host}{path} master".format(user=env.user, host=env.host, path=env.diode))
    run("git checkout master")
    #run("echo 'elixir 1.14' > .tool-versions")
    #run("echo 'erlang 24.0.4' >> .tool-versions")
    #run("export KERL_CONFIGURE_OPTIONS=--without-wx CFLAGS=\"-O3 -march=native\" && . ~/.asdf/asdf.sh && asdf install")
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

def optimize():
  if not exists("/etc/sysctl.d/99-diode.conf"):
    # https://access.redhat.com/solutions/30453
    settings =[
      "net.core.default_qdisc=fq", 
      "net.ipv4.tcp_congestion_control=bbr",
      "net.core.somaxconn=16384",
      "net.ipv4.tcp_max_syn_backlog=512"
      ]
    
    for setting in settings:
      run("echo {} >> /etc/sysctl.d/99-diode.conf".format(setting))
  
    run("sysctl --system")

  if not exists("/etc/modules-load.d/zswap_modules.conf"):
    run("echo z3fold >> /etc/modules-load.d/zswap_modules.conf")
    run("echo lz4 >> /etc/modules-load.d/zswap_modules.conf")
    run("echo lz4_compress >> /etc/modules-load.d/zswap_modules.conf")
    run("echo z3fold >> /etc/initramfs-tools/modules")
    run("echo lz4 >> /etc/initramfs-tools/modules")
    run("echo lz4_compress >> /etc/initramfs-tools/modules")
    run("update-initramfs -u -k all")
    append("/etc/default/grub", "GRUB_CMDLINE_LINUX=\"nomodeset zswap.enabled=1 zswap.compressor=lz4 zswap.max_pool_percent=25 zswap.zpool=z3fold\"")
    run("update-grub")
