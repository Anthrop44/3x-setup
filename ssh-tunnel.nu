#!/usr/bin/env nu
const FILE = path self
use remote/lib/core.nu ensure
use modules/ssh.nu [ssh-options ssh-target]

def main [--startup-timeout-seconds: int = 10] {
	ensure ($startup_timeout_seconds in 1..3600) 'Startup timeout must be between 1 and 3600 seconds'
	let project = ($FILE | path dirname)
	let config = (open ($project | path join remote config.json))
	let constants = (open ($project | path join remote constants.json))
	let url = $"http://127.0.0.1:($constants.localSshPort)/($constants.'3xpanelUriPath')/"
	# Keep ssh in the foreground so PIN/passphrase prompts and Ctrl+C work
	# A job observes the tunnel and opens the browser only after an HTTP response
	let parent = $nu.pid
	let watcher = (job spawn {
		let deadline = ((date now) + ($startup_timeout_seconds * 1sec))
		mut ready = false
		while (date now) < $deadline {
			$ready = (try { http get --max-time 500ms $url | ignore; true } catch { false })
			if $ready { break }
			sleep 250ms
		}
		if $ready {
			print $"Panel: ($url)\nUsername: ($constants.'3xusername')\nPassword: ($constants.'3xpassword')\nPress Ctrl+C to disconnect"
			try { start $url } catch { print 'Open the panel URL in your browser' }
		} else {
			print --stderr 'Tunnel startup timed out; retry with a longer timeout'
			for child in (ps --long | where {|p| $p.ppid == $parent and $p.name in [ssh ssh.exe] }) { try { kill $child.pid } catch { } }
		}
	})
	^ssh ...(ssh-options $project $config) -o ExitOnForwardFailure=yes -o BatchMode=no -N -L $"127.0.0.1:($constants.localSshPort):127.0.0.1:($constants.'3xpanelPort')" (ssh-target $config)
	let code = $env.LAST_EXIT_CODE
	try { job kill $watcher } catch { }
	ensure ($code == 0) $"SSH tunnel exited with code ($code)"
}
