import os
import time
from collections import defaultdict
from datetime import datetime
from fabric.api import env, run, cd, put, get, abort, hide, local, lcd, prefix, hosts, sudo
from fabric.contrib.files import exists


env.diode="/opt/diode"

# Install on Ubuntu 18.04
def install():
  put(".inputrc", "~")

  # Elixir + Base System
  if not exists("/usr/bin/elixir"):
    run("wget https://packages.erlang-solutions.com/erlang-solutions_1.0_all.deb")
    run("dpkg -i erlang-solutions_1.0_all.deb")
    run("apt update")
    run("apt upgrade -y")
    run("apt install -y screen git snap g++ make autoconf esl-erlang elixir libtool libgmp-dev daemontools cpulimit")
    run("apt autoremove")

  # Application
  run("mkdir -p {}".format(env.diode))
  with cd(env.diode):
    run("git init")
    run("git config receive.denyCurrentBranch ignore")
    local("git push -f ssh://{user}@{host}{path}".format(user=env.user, host=env.host, path=env.diode))
    run("git checkout master")
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
