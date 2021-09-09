#!/bin/bash

source /etc/os-release
dnf -qy module disable postgresql
dnf install -y http://download.postgresql.org/pub/repos/yum/reporpms/F-$VERSION_ID-x86_64/pgdg-fedora-repo-latest.noarch.rpm
