#	yum remove -y \
#		<package list> \
#		&& \
	yum autoremove -y && \
	yum clean all && \
	rm -rf \
		/var/cache/yum \
		/var/log/yum.log \
		/tmp/* \
		/var/tmp/*
