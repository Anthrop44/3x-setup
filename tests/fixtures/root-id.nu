def --wrapped main [...args: string] {
	if $args != [-u] { error make {msg: 'Unexpected id arguments in test'} }
	print 0
}
