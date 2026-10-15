#!/usr/bin/env nu
use common.nu *

def main [] {
	root-required
	$env.DEBIAN_FRONTEND = 'noninteractive'
	checked -- apt-get update
	checked -- apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y
	checked -- x-ui update
	if (capture -- systemctl list-unit-files 3x-fetch-apps.service --no-legend | str trim | is-not-empty) {
		checked -- systemctl start 3x-fetch-apps.service
	} else { print 'Proxy client updater was not installed (--noAPP); skipping' }
}
