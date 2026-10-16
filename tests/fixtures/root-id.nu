# 模拟id -u返回root用户ID，拒绝其他参数
def --wrapped main [...args: string] {
	if $args != [-u] { error make {msg: 'Unexpected id arguments in test'} }
	print 0
}
