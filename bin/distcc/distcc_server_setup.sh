#!/bin/bash

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

# This script automates setup of distcc servers on Ubuntu and CentOS. It has been tested
# on Ubuntu 14.04, 16.04 and 18.04 and CentOS 6 and 7. See bin/distcc/README.md for manual
# setup instructions and background.
#
# Usage:
# ------
# This script assumes that the Impala repository is checked out and that the
# toolchain has been bootstrapped in the toolchain subdirectory of the impala
# repository.
#
# The script expects to be run as root and requires that the user specify a range of
# IPs that it should accept connections from. E.g. To configure a distcc server that
# accepts connections from the 172.* private IP address block. The IP address argument
# is forwarded to the --allow flag of distccd.
#
#   sudo ./bin/distcc/distcc_server_setup.sh 172.16.0.0/12
#
# Multiple networks can be allowed by providing a space-separated list:
#
#   sudo ./bin/distcc/distcc_server_setup.sh "172.16.0.0/12 10.16.0.0/8"
#
# Environment overrides:
# ---------------------
# CCACHE_DIR: directory to use for distccd's ccache.
# CCACHE_SIZE: size of ccache, passed to ccache's -M option
set -eu -o pipefail

# Find the absolute path to repo root.
export IMPALA_HOME=$(cd "$(dirname "$0")/../.."; pwd)

. $IMPALA_HOME/bin/report_build_error.sh
setup_report_build_error

if [[ $# != 1 ]]; then
  echo "Usage: $0 <allowed IP address range>"
  exit 1
fi
set -x
ALLOWED_NETS=$1

OS_ID=$(source /etc/os-release && echo "$ID")
OS_VERSION=$(source /etc/os-release && echo "$VERSION_ID")
if [[ "$OS_ID" == ubuntu ]]; then
  if ! [[ $OS_VERSION == 14.04 || $OS_VERSION == 16.04 || $OS_VERSION == 18.04 || \
      $OS_VERSION == 20.04 ]]; then
    echo "This script only supports Ubuntu 14.04, 16.04, 18.04, and 20.04" >&2
    exit 1
  fi
  LINUX_FLAVOUR=ubuntu
  DISTCCD_USER=distccd
  DISTCCD_SERVICE=distcc
elif [[ "$OS_ID" == centos ]]; then
  if ! [[ $OS_VERSION == 6.* || $OS_VERSION = 7.* ]]; then
    echo "This script only supports CentOS 6 and 7" >&2
    exit 1
  fi
  LINUX_FLAVOUR=redhat
  DISTCCD_USER=nobody
  DISTCCD_SERVICE=distccd
else
  echo "This script only supports Ubuntu and CentOS" >&2
  exit 1
fi

echo "Installing required packages"
if [[ $LINUX_FLAVOUR = ubuntu ]]; then
  apt-get install --yes distcc ccache
else
  yum install -y distcc-server ccache
fi

echo "Configuring ccache for distccd user"
export CCACHE_DIR=${CCACHE_DIR-/opt/ccache}
CCACHE_SIZE=${CCACHE_SIZE:-25G}
mkdir -p "${CCACHE_DIR}"
chown ${DISTCCD_USER} "${CCACHE_DIR}"
HOME=${CCACHE_DIR} sudo -E -u ${DISTCCD_USER} ccache -M "${CCACHE_SIZE}"

echo "Configuring distcc"
if [[ $LINUX_FLAVOUR = ubuntu ]]; then
  cat << EOF >> /etc/default/distcc
# BEGIN: Settings automatically generated by distcc_server_setup.sh
STARTDISTCC="true"
ALLOWEDNETS="${ALLOWED_NETS}"
LISTENER="0.0.0.0"
JOBS=$(nproc)
# CCACHE_DIR is picked up by ccache from environment.
export CCACHE_DIR=${CCACHE_DIR}
# END: Settings automatically generated by distcc_server_setup.sh
EOF
else
  ALLOWED_NETS_ARGS=
  for allowed_net in $ALLOWED_NETS; do
    ALLOWED_NETS_ARGS+=" --allow ${allowed_net}"
  done
  cat << EOF >> /etc/sysconfig/distccd
# BEGIN: Settings automatically generated by distcc_server_setup.sh
OPTIONS="--jobs $(($(nproc) * 2)) ${ALLOWED_NETS_ARGS} --log-level=warn --nice=-15"
# CCACHE_DIR is picked up by ccache from environment. CentOS 6 requires CCACHE_DIR to
# be exported while CentOS 7 seems to ignore the "export VAR=val" syntax.
CCACHE_DIR=${CCACHE_DIR}
export CCACHE_DIR
# END: Settings automatically generated by distcc_server_setup.sh
EOF
fi
service ${DISTCCD_SERVICE} restart

echo "Symlinking /opt/Impala-Toolchain to default toolchain location"
ln -f -s -T "${IMPALA_HOME}/toolchain" /opt/Impala-Toolchain

# To resolve CVE-2004-2687, newer distcc versions only allow programs to be executed
# if they have a symlink under '/usr/lib/distcc'.
# https://github.com/distcc/distcc/commit/dfb45b528746bf89c030fccac307ebcf7c988512
echo "Creating symlink for ccache:"
ln -s $(which ccache) /usr/lib/distcc/ccache
