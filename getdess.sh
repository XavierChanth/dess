#!/bin/bash

# Enable job control
set -m

# Dess installation

# Dependencies
# openssl, qrencode, curl
# docker, docker-compose, snapd
# certbot (via snap)

# Container Dependencies
# fuse squashfuse

# SCRIPT GLOBALS

# Supported distros by type
debian_releases='ubuntu debian'
redhat_releases='centos fedora amazon'

# Required base packages
lxc_packages="fuse squashfuse"
packages="curl openssl qrencode"

# Docker compose link
compose_url="https://github.com/docker/compose/releases/download/1.29.2/docker-compose"

# Atsign user info
user_info="atsign, secondaries account, atsign.com"

# Atsign directories
atsign_dirs="/home/atsign/dess /home/atsign/base /home/atsign/atsign/var /home/atsign/atsign/etc /home/atsign/atsign/logs"

# Repository files
repo_url="https://raw.githubusercontent.com/xavierchanth/dess/curl-testing"
atsign_files="base/.env base/docker-swarm.yaml base/setup.sh base/shepherd.yaml base/restart.sh"
dess_scripts="create reshowqr"

# Original user
original_user=$USER

command_exists () {
  command -v "$@" > /dev/null 2>&1
}

# Helper function to check if user's release matches the list
# $1 = list of valid releases
# $2 = release to check
is_release () { [[ $1 =~ (^|[[:space:]])$2($|[[:space:]]) ]]; }

pre_install () {
  # Get the user's release
  os_release=$(awk -F= '/^NAME/{print $2}' /etc/os-release | sed 's/\"//g' | awk '{print tolower($1)}')
  if [ -z "$os_release" ]
  then
      echo 'Error: Could not detect your distribution.'
      exit 1
  fi
  echo "Detected distribution: $os_release";

  # get package manager
  if is_release "$debian_releases" "$os_release"; then
    pkg_man='apt-get'
  elif is_release "$redhat_releases" "$os_release"; then
    #Use dnf if available, fallback to yum on older distros
    if [[ -n $(command -v 'dnf') ]]; then
      pkg_man='dnf'
    else
      pkg_man='yum'
    fi
  else
    echo 'Your distribution is not supported by this script.'
    exit 0
  fi
  echo "Detected package manager: $pkg_man"
}

# Functions below are run as root via do_install

install_dependencies () {
  $pkg_man -y update
  for pkg in $packages; do
    $pkg_man -y install "$pkg"
  done
  # Container support
  if [[ $(systemd-detect-virt) != 'none' ]]; then
    for lxc_pkg in $lxc_packages; do
      $pkg_man -y install "$lxc_pkg"
    done
  fi
}

install_certbot () {
  # install snapd
  if [[ "$os_release" == centos ]]; then
    $pkg_man -y install epel-release
  elif [[ "$os_release" == fedora ]]; then
    $pkg_man -y install kernel-modules
  fi
  $pkg_man -y install snapd
  ln -s /var/lib/snapd/snap /snap
  # enable and start snapd
  systemctl enable --now snapd.service
  systemctl start snapd.service
  # wait for snapd to startup
  STATUS=1
  while [[ $STATUS -ne 0 ]]; do
    systemctl is-active --quiet snapd.service
    STATUS=$?
  done
  echo Starting snapd service
  sleep 2
  # install snap core
  snap install core
  snap refresh core
  # install certbot
  snap install --classic certbot
}

install_docker () {
  # docker
  if ! command_exists docker; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
  fi

  # docker-compose
  curl -fsSL "$compose_url-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
  systemctl enable --now docker.service
}

mkdir_atsign () {
  mkdir -p "$1"
  echo "making $1"
  chown atsign "$1"
}

curl_atsign_file () {
  curl -fsSL "$repo_url/$1" -o "/home/atsign/$1"
  echo "curling $1"
  chown atsign "/home/atsign/$1"
}

setup_atsign_user () {
  # add atsign user
  if [[ $pkg_man == apt-get ]]; then
    adduser -uid 1024 --disabled-password --disabled-login --gecos "$user_info" atsign
  else
    adduser --uid 1024 --comment "$user_info" atsign
  fi

  # link lets-encrypt folder
  if [[ ! -d /home/atsign/atsign/etc ]]; then
    tput setaf 2
    echo "setting up certbot"
    rm /etc/letsencrypt/*
    rmdir /etc/letsencrypt/
    ln -s /home/atsign/atsign/etc /etc/letsencrypt
    tput setaf 9
  else
    tput setaf 1
    echo 'saved you from destroying letsencrypt by running the script again :-)'
    tput setaf 9
  fi

  # make ~atsign directories
  tput setaf 2
  echo "Creating some base directories for atsign"
  tput setaf 9
  for directory in $atsign_dirs; do
    mkdir_atsign "$directory"
  done

  # curl the base files for atsign
  for file in $atsign_files; do
    curl_atsign_file "$file"
  done

  chown atsign:atsign /home/atsign
}

setup_docker () {
  # wait for docker to startup
  STATUS=1
  while [[ $STATUS -ne 0 ]]; do
    systemctl is-active --quiet docker.service
    STATUS=$?
  done

  # give atsign user docker permissions
  usermod -aG docker atsign

  # give user docker permissions
  usermod -aG docker "$original_user"

  # setup and deploy the swarm as atsign
  docker swarm init
  docker network create -d overlay secondaries
  docker stack deploy -c /home/atsign/base/shepherd.yaml secondaries
}

test_atsign_user () {
  # check if docker works for atsign user
  runuser -l atsign -c '/usr/bin/docker run hello-world'
  RESULT=$?
  if [[ $RESULT -eq 0 ]]; then
    echo "Docker setup correctly for atsign user"
  else
    echo "Please check docker install, something went wrong"
  fi
}

get_dess_scripts () {
  # curl create and reshowqr from repo
  # to /usr/local/bin
  for script in $dess_scripts; do
    curl -fsSL "$repo_url"/"$script".sh -o /usr/local/bin/dess-"$script"
    chmod +x /usr/local/bin/dess-"$script"
    ln -s /usr/local/bin/dess-"$script" /usr/bin/dess-"$script"
  done
}

functions="
  command_exists
  pre_install
  install_dependencies
  install_certbot
  install_docker
  mkdir_atsign
  curl_atsign_file
  setup_atsign_user
  setup_docker
  test_atsign_user
  get_dess_scripts
  "

export_functions () {
  for func in $functions; do
    export -f "${func?}"
  done
}

unset_functions () {
  for func in $functions; do
    unset "$func"
  done
}

do_install () {
  pre_install
  export_functions

  if [[ $EUID -ne 0 ]]; then
    echo 'Error: unable to perform root operations';
    echo 'Please run this script as root to complete installation.';
    exit 1
  fi

  install_dependencies
  install_certbot
  install_docker
  setup_atsign_user
  setup_docker
  test_atsign_user
  get_dess_scripts

  unset_functions
}

do_install
