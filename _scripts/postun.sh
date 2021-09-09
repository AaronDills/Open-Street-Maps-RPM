#!/bin/bash
dnf -qy module enable postgresql
dnf -y remove pgdg-fedora-repo-latest.noarch.rpm 
