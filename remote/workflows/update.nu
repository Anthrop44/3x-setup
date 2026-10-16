use ../lib/core.nu [checked capture]

# 更新APT软件和3X-UI，并触发已安装的代理客户端更新任务
export def execute [] {
	checked -- apt-get update
	checked -- apt-get -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade -y
	checked -- x-ui update
	if (capture -- systemctl list-unit-files 3x-fetch-apps.service --no-legend | str trim | is-not-empty) {
		checked -- systemctl start 3x-fetch-apps.service
	} else { print 'Proxy client updater was not installed (--noAPP); skipping' }
}
